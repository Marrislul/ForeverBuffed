local _, ns = ...

local FB = LibStub("AceAddon-3.0"):NewAddon("ForeverBuffed", "AceConsole-3.0")
ns.FB = FB

local GetTime, pairs, ipairs, type, tonumber = GetTime, pairs, ipairs, type, tonumber
local format, ceil, strlower, wipe = string.format, math.ceil, string.lower, wipe

-- WoW Forever runs the "secret values" system: in combat the game hands buff
-- data to addons as secret values. Those must not be compared or even tested
-- for truth ("x and y or z"), that is a Lua error. Everything read from the
-- aura API goes through IsSecret/Plain first.
local IsSecret = issecretvalue

local function Plain(v)
    if IsSecret(v) then return nil end
    return v
end

local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"
local INV_SLOT = { MainHand = 16, OffHand = 17 }
local UPDATE_INTERVAL = 0.1
local RED_TEXT_BELOW = 5

local defaults = {
    profile = {
        locked = true,
        -- the bar's anchor (see LayoutIcons) relative to the screen center
        x = 0,
        y = -150,
        iconSize = 40,
        spacing = 4,
        grow = "RIGHT",
        threshold = 30,
        showTimer = true,
        fontSize = 14,
        glow = "missing", -- "off", "missing" or "both" (missing or running out)
        unusable = "desaturate",
        showWhen = "always",
        hideResting = false,
        hideMounted = false,
        trackers = { ["*"] = { threshold = 0 } },
        custom = {},
        nextCustomID = 1,
    },
    char = {
        durations = {}, -- lowercase buff name -> full duration seen out of combat
    },
}

local trackers = {}    -- enabled trackers, in display order
local states = {}      -- tracker key -> { present, expires, duration, lastName, instanceID }
local auraDirty = true -- buffs changed since the last successful scan
local sentSelf = {}    -- castGUID -> true while a cast aimed at the player is in flight
local sentCount = 0
local scan = {}        -- reused scan records
local icons = {}
local shownCount = -1  -- number of shown icons the layout is for; -1 = outdated
local container, mover, playerName

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local SpellName = C_Spell.GetSpellName

local function AddName(set, name)
    if name and name ~= "" then set[strlower(name)] = true end
end

-- "1459, 23028, Well Fed" -> { 1459, 23028 }, { "Well Fed" }
function ns.ParseSpellList(text)
    local ids, names = {}, {}
    for token in string.gmatch(text or "", "[^,;]+") do
        token = strtrim(token)
        if token ~= "" then
            local id = tonumber(token)
            if id then ids[#ids + 1] = id else names[#names + 1] = token end
        end
    end
    return ids, names
end

local function FormatTime(seconds)
    if seconds >= 3600 then return format("%dh", ceil(seconds / 3600)) end
    if seconds >= 60 then return format("%dm", ceil(seconds / 60)) end
    return format("%d", ceil(seconds))
end

-- Spell ID (current rank) if the player knows the spell, else nil. Takes an ID or a name.
local function KnownSpell(spell)
    local name = type(spell) == "number" and SpellName(spell) or spell
    -- a lookup by name returns the current override, i.e. the highest rank
    local info = name and C_Spell.GetSpellInfo(name)
    if info and C_SpellBook.IsSpellKnown(info.spellID) then return info.spellID end
    if type(spell) == "number" and C_SpellBook.IsSpellKnown(spell) then return spell end
end

-- True while the game hides buff data from addons (combat).
local function AurasRestricted()
    return C_Secrets.ShouldAurasBeSecret()
end

-- Temporary enchant on a weapon slot: hasEnchant, secondsLeft. Not secret in combat.
local function ReadWeaponEnchant(slot)
    for _, e in pairs(C_Item.GetWeaponEnchantInfo(Enum.WeaponSlot[slot])) do
        if e.hasEnchant and e.enchantType ~= Enum.ItemEnchantType.Permanent then
            return true, e.timeLeft / 1000
        end
    end
    return false, 0
end

-- Off-hand counts only for weapons, not shields or held-in-off-hand items.
local function SlotHasWeapon(slot)
    local itemID = GetInventoryItemID("player", INV_SLOT[slot])
    if not itemID then return false end
    if slot == "MainHand" then return true end
    return select(6, C_Item.GetItemInfoInstant(itemID)) == Enum.ItemClass.Weapon
end

-------------------------------------------------------------------------------
-- Trackers
-------------------------------------------------------------------------------

local function GetState(key)
    local st = states[key]
    if not st then
        st = { present = false, expires = 0 }
        states[key] = st
    end
    return st
end

local function IsSelfCast(selfCast, id)
    if selfCast == true then return true end
    for _, v in ipairs(selfCast or {}) do
        if v == id then return true end
    end
    return false
end

local function NewTracker(key, kind)
    return {
        key = key,
        kind = kind or "aura",
        buffIDs = {},      -- set of buff spell IDs
        buffNames = {},    -- set of lowercase buff names
        seenIDs = {},      -- buff IDs actually seen on the player (all ranks)
        castIDs = {},
        castNames = {},    -- lowercase names of spells that apply the buff
        selfNames = {},    -- subset of castNames that always land on the player
        knownCasts = {},   -- lowercase name -> known spell ID
        state = GetState(key),
    }
end

-- The groups of buffs that don't stack (ns.EXCLUSIVE_GROUPS) that a reminder for these
-- buffs belongs to. Class buffs match by name (every rank), the others by ID, or by a
-- name typed into a custom reminder.
function ns.ExclusiveGroups(ids, names)
    local idSet, nameSet, typed = {}, {}, {}
    for _, id in ipairs(ids) do
        idSet[id] = true
        AddName(nameSet, SpellName(id))
    end
    for _, n in ipairs(names or {}) do
        AddName(nameSet, n)
        AddName(typed, n)
    end
    local function hits(list, set)
        for _, id in ipairs(list) do
            local n = SpellName(id)
            if idSet[id] or (n and set[strlower(n)]) then return true end
        end
        return false
    end
    local found = {}
    for _, g in ipairs(ns.EXCLUSIVE_GROUPS) do
        if hits(g.byName, nameSet) or hits(g.byID, typed) then found[#found + 1] = g end
    end
    return found
end

-- The other buffs of these groups count as well.
local function AddExclusive(t, groups)
    for _, g in ipairs(groups) do
        for _, id in ipairs(g.byName) do AddName(t.buffNames, SpellName(id)) end
        for _, id in ipairs(g.byID) do
            if not t.buffIDs[id] then
                t.buffIDs[id] = true
                t.exclusive = t.exclusive or {}
                t.exclusive[#t.exclusive + 1] = id
            end
        end
    end
end

-- Display name of a built-in tracker.
function ns.TrackerLabel(def)
    if def.label then return def.label end
    local names, seen = {}, {}
    for _, id in ipairs(def.buffs or def.cast or {}) do
        local n = SpellName(id)
        if n and not seen[n] then
            seen[n] = true
            names[#names + 1] = n
        end
    end
    return names[1] and table.concat(names, " / ") or def.key
end

function FB:RebuildTrackers()
    wipe(trackers)
    local p = self.db.profile
    local _, class = UnitClass("player")

    local function addBuiltin(def)
        local cfg = p.trackers[def.key]
        local enabled = cfg.enabled
        if enabled == nil then enabled = def.default end
        if not enabled then return end

        local t = NewTracker(def.key, def.kind)
        t.slot = def.slot
        t.glow = cfg.glow
        t.threshold = cfg.threshold > 0 and cfg.threshold or def.threshold or 0
        if cfg.combatOnly == nil then
            t.combatOnly = def.combatOnly
        else
            t.combatOnly = cfg.combatOnly
        end
        t.defaultDuration = def.duration
        t.needsSpell = def.needsSpell ~= false
        t.noUsable = def.noUsable
        t.castIDs = def.cast or {}
        for _, id in ipairs(def.buffs or {}) do
            t.buffIDs[id] = true
            t.firstID = t.firstID or id
            AddName(t.buffNames, SpellName(id))
        end
        if cfg.exclusive ~= false then AddExclusive(t, ns.ExclusiveGroups(def.buffs or {})) end
        for _, id in ipairs(t.castIDs) do
            local n = SpellName(id)
            AddName(t.castNames, n)
            if IsSelfCast(def.selfCast, id) then AddName(t.selfNames, n) end
        end
        trackers[#trackers + 1] = t
    end

    for _, def in ipairs(ns.CLASS_TRACKERS[class] or {}) do addBuiltin(def) end
    for _, def in ipairs(ns.GENERAL_TRACKERS) do addBuiltin(def) end

    for _, c in ipairs(p.custom) do
        local ids, names = ns.ParseSpellList(c.spells)
        if c.enabled and (#ids > 0 or #names > 0) then
            local t = NewTracker("custom" .. c.uid, "aura")
            t.threshold = c.threshold or 0
            t.glow = c.glow
            t.combatOnly = c.combatOnly
            t.needsSpell = c.needsSpell
            t.castIDs = ids
            t.literalNames = names
            for _, id in ipairs(ids) do
                t.buffIDs[id] = true
                t.firstID = t.firstID or id
                AddName(t.buffNames, SpellName(id))
                AddName(t.castNames, SpellName(id))
            end
            for _, n in ipairs(names) do
                AddName(t.buffNames, n)
                AddName(t.castNames, n)
            end
            if c.exclusive ~= false then AddExclusive(t, ns.ExclusiveGroups(ids, names)) end
            trackers[#trackers + 1] = t
        end
    end

    self:RefreshSpells()
    auraDirty = true
end

-- Which cast spells (and ranks) the player knows. Runs on SPELLS_CHANGED.
function FB:RefreshSpells()
    for _, t in ipairs(trackers) do
        t.castSpell = nil
        wipe(t.knownCasts)
        local function check(spell)
            local known = KnownSpell(spell)
            if known then
                t.castSpell = t.castSpell or known
                local n = type(spell) == "number" and SpellName(spell) or spell
                t.knownCasts[strlower(n)] = known
            end
        end
        for _, id in ipairs(t.castIDs) do check(id) end
        for _, n in ipairs(t.literalNames or {}) do check(n) end
    end
    self:RefreshTracking()
end

-- Minimap tracking (Find Herbs, Sense Undead, Track Beasts, ...) is no buff; the game
-- reports it separately. Only one can be on at a time, so any of them counts. The
-- minimap menu lists the tracking spells you know, which also decides the icon.
function FB:RefreshTracking()
    for _, t in ipairs(trackers) do
        if t.kind == "tracking" then
            local st = t.state
            st.present = false
            st.expires = 0
            for i = 1, C_Minimap.GetNumTrackingTypes() do
                local info = C_Minimap.GetTrackingInfo(i)
                -- spells only, not the town filters (mailbox, flight master, ...)
                local id = info and Plain(info.spellID)
                local name = id and SpellName(id) or (info and Plain(info.type) == "spell" and Plain(info.name))
                if name then
                    local spell = id or name
                    name = strlower(name)
                    t.castSpell = t.castSpell or spell
                    t.knownCasts[name] = spell
                    if Plain(info.active) then
                        st.present = true
                        st.lastName = name -- icon while it is off
                    end
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Buff state
-------------------------------------------------------------------------------

-- Whether no buff of a tracker can be hidden by the game, so "not found" means "not there".
local function TrackerReadable(t)
    if not t.firstID or (t.literalNames and t.literalNames[1]) then return false end
    for _, set in ipairs({ t.buffIDs, t.seenIDs }) do
        for id in pairs(set) do
            if C_Secrets.ShouldSpellAuraBeSecret(id) then return false end
        end
    end
    return true
end

-- Copies a buff into a scan record. False if part of it is secret (a single buff
-- flagged "always secret").
local function ReadAura(aura, rec)
    local name, id, expires, duration = aura.name, aura.spellId, aura.expirationTime, aura.duration
    if IsSecret(name) or IsSecret(id) or IsSecret(expires) or IsSecret(duration) then return false end
    rec.name = strlower(name)
    rec.id = id
    rec.expires = expires
    rec.duration = duration
    rec.instance = Plain(aura.auraInstanceID)
    return true
end

-- The camp buffs that block a class buff are hidden auras, missing from the buff
-- list; ask for them by spell ID.
local hiddenRec = {}
local function FindHiddenAura(ids)
    for _, id in ipairs(ids) do
        local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, id)
        if ok and not IsSecret(aura) and aura and ReadAura(aura, hiddenRec) then return hiddenRec end
    end
end

-- Reads all player buffs and updates every aura tracker. Only possible while
-- buff data is not secret; returns false (state untouched) otherwise.
local function ScanAuras()
    if AurasRestricted() then return false end
    local n, hidden = 0, 0
    for i = 1, 255 do
        local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
        if not ok then return false end
        if IsSecret(aura) then
            hidden = hidden + 1
        elseif not aura then
            break
        else
            local rec = scan[n + 1] or {}
            scan[n + 1] = rec
            if ReadAura(aura, rec) then
                n = n + 1
            else
                hidden = hidden + 1
            end
        end
    end

    local durations = FB.db.char.durations
    for _, t in ipairs(trackers) do
        if t.kind == "aura" then
            local best
            for i = 1, n do
                local rec = scan[i]
                if t.buffIDs[rec.id] or t.buffNames[rec.name] then
                    -- prefer a buff without expiry, then the one lasting longest
                    if not best or (best.expires ~= 0 and (rec.expires == 0 or rec.expires > best.expires)) then
                        best = rec
                    end
                end
            end
            if not best and t.exclusive then best = FindHiddenAura(t.exclusive) end
            local st = t.state
            if best then
                st.present = true
                st.expires = best.expires
                st.duration = best.duration
                st.lastName = best.name
                st.instanceID = best.instance
                t.seenIDs[best.id] = true
                if best.duration > 0 then durations[best.name] = best.duration end
            elseif hidden == 0 or TrackerReadable(t) then
                st.present = false
                st.expires = 0
                st.instanceID = nil
            end
            -- else: it may be one of the hidden buffs, keep the last known state
        end
    end
    return true
end

local function OnCastSent(_, target, castGUID)
    if IsSecret(castGUID) or IsSecret(target) or not castGUID then return end
    if target == "" or target == playerName then
        if sentCount > 50 then
            wipe(sentSelf)
            sentCount = 0
        end
        sentSelf[castGUID] = true
        sentCount = sentCount + 1
    end
end

-- The player's own casts stay readable in combat. A buff cast on yourself
-- (e.g. Battle Shout mid-fight) counts as freshly applied, with the duration
-- learned out of combat.
local function OnCastSucceeded(_, castGUID, spellID)
    if IsSecret(spellID) then return end
    local name = SpellName(spellID)
    if not name then return end
    name = strlower(name)

    local onSelf = false
    castGUID = Plain(castGUID)
    if castGUID then
        onSelf = sentSelf[castGUID] or false
        sentSelf[castGUID] = nil
    end

    local now = GetTime()
    local durations = FB.db.char.durations
    for _, t in ipairs(trackers) do
        local st = t.state
        if t.kind == "aura" and t.castNames[name] and (t.selfNames[name] or onSelf) then
            local duration = durations[name] or st.duration or t.defaultDuration
            st.present = true
            st.expires = (duration and duration > 0) and (now + duration) or 0
            st.lastName = name
            st.instanceID = nil -- the new instance ID can't be read in combat
        end
    end
    auraDirty = true
end

local function MarkCancelled(t)
    t.state.present = false
    t.state.expires = 0
    t.state.instanceID = nil
end

-- Right-click on Blizzard's buff bar. The buff's instance ID is readable out of
-- combat, and in combat until the buff bar first refreshes; after that the
-- game hides which buff was clicked (then use /cancelaura).
local function OnBuffButtonClick(_, button, mouseButton)
    if mouseButton ~= "RightButton" or type(button) ~= "table" or button.auraType ~= "Buff" then return end
    auraDirty = true
    local info = button.buttonInfo
    local instance = type(info) == "table" and Plain(info.auraInstanceID) or nil
    if not instance then return end
    for _, t in ipairs(trackers) do
        if t.kind == "aura" and t.state.present and t.state.instanceID == instance then
            MarkCancelled(t)
            return
        end
    end
end

-- "/cancelaura Battle Shout", "Battle Shout(Rank 3)" or a spell ID: always readable.
local function OnCancelName(name)
    if IsSecret(name) or type(name) ~= "string" then return end
    name = strlower((name:gsub("%s*%(.-%)%s*$", "")))
    for _, t in ipairs(trackers) do
        if t.kind == "aura" and t.buffNames[name] then MarkCancelled(t) end
    end
    auraDirty = true
end

function FB:HookCancels()
    EventRegistry:RegisterCallback("BuffButton.OnClick", OnBuffButtonClick, self)
    hooksecurefunc("CancelSpellByName", OnCancelName)
    hooksecurefunc(C_Spell, "CancelSpellByID", function(spellID)
        if not IsSecret(spellID) then OnCancelName(SpellName(spellID)) end
    end)
end

-------------------------------------------------------------------------------
-- Display
-------------------------------------------------------------------------------

local BACKDROP = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true,
    tileSize = 16,
    edgeSize = 12,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
}

-- Direction the icons line up in. The centered layouts spread them evenly around the anchor.
local GROW = {
    RIGHT = { 1, 0 }, LEFT = { -1, 0 }, UP = { 0, 1 }, DOWN = { 0, -1 },
    HCENTER = { 1, 0, centered = true }, VCENTER = { 0, -1, centered = true },
}
local MOVER_PADDING = 4
local GLOW_COLOR = { missing = { 1, 0.15, 0.1 }, expiring = { 1, 0.75, 0.1 } }

-- The container is an icon-sized anchor at the saved position: the first icon sits on it,
-- or the middle of the bar for centered layouts. Everything is placed around its center,
-- so a bigger icon size grows the bar evenly in all directions.
local function LayoutIcons(n, p)
    local dir = GROW[p.grow] or GROW.RIGHT
    local size, step = p.iconSize, p.iconSize + p.spacing
    local count = math.max(n, 1)
    local shift = dir.centered and (count - 1) / 2 or 0
    for i, f in ipairs(icons) do
        local offset = (i - 1 - shift) * step
        f:SetSize(size, size)
        f:ClearAllPoints()
        f:SetPoint("CENTER", container, "CENTER", dir[1] * offset, dir[2] * offset)
    end

    -- the drag area while unlocked covers the shown icons
    local long = count * step - p.spacing + 2 * MOVER_PADDING
    local short = size + 2 * MOVER_PADDING
    local middle = ((count - 1) / 2 - shift) * step
    if dir[1] ~= 0 then
        mover:SetSize(long, short)
    else
        mover:SetSize(short, long)
    end
    mover:ClearAllPoints()
    mover:SetPoint("CENTER", container, "CENTER", dir[1] * middle, dir[2] * middle)
    shownCount = n
end

local ANCHOR_OFFSET = {
    CENTER = { 0, 0 }, TOP = { 0, 1 }, BOTTOM = { 0, -1 }, LEFT = { -1, 0 }, RIGHT = { 1, 0 },
    TOPLEFT = { -1, 1 }, TOPRIGHT = { 1, 1 }, BOTTOMLEFT = { -1, -1 }, BOTTOMRIGHT = { 1, -1 },
}

-- Settings saved by 0.0.1.
local function MigrateProfile(p)
    -- whichever anchor the client picked after dragging (e.g. TOPLEFT of the first
    -- icon) becomes the first icon's center relative to the screen center
    if p.point then
        local own, rel = ANCHOR_OFFSET[p.point], ANCHOR_OFFSET[p.relativePoint or p.point]
        if own and rel then
            local half = p.iconSize / 2
            p.x = Round(rel[1] * UIParent:GetWidth() / 2 + p.x - own[1] * half)
            p.y = Round(rel[2] * UIParent:GetHeight() / 2 + p.y - own[2] * half)
        end
        p.point, p.relativePoint = nil, nil
    end
    if p.glowMissing == false then p.glow = "off" end
    p.glowMissing = nil
end

-- While unlocked, every icon and the area around them drag the whole bar.
local function StartDrag()
    if not FB.db.profile.locked then container:StartMoving() end
end

local function StopDrag()
    container:StopMovingOrSizing()
    local cx, cy = container:GetCenter()
    local ux, uy = UIParent:GetCenter()
    local p = FB.db.profile
    p.x, p.y = Round(cx - ux), Round(cy - uy)
    FB:ApplyLayout()
    LibStub("AceConfigRegistry-3.0"):NotifyChange("ForeverBuffed")
end

local function CreateIcon(i)
    local p = FB.db.profile
    local f = CreateFrame("Frame", nil, container)
    f:EnableMouse(not p.locked) -- locked icons must not swallow clicks
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", StartDrag)
    f:SetScript("OnDragStop", StopDrag)

    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetColorTexture(0, 0, 0, 1)
    f.bg:SetPoint("TOPLEFT", -1, 1)
    f.bg:SetPoint("BOTTOMRIGHT", 1, -1)

    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetAllPoints()
    f.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    -- pulsing border: red while the buff is missing, orange while it runs out
    local glow = CreateFrame("Frame", nil, f)
    glow:SetPoint("TOPLEFT", -3, 3)
    glow:SetPoint("BOTTOMRIGHT", 3, -3)
    glow:SetFrameLevel(f:GetFrameLevel() + 2)
    local edges = {}
    for j = 1, 4 do
        edges[j] = glow:CreateTexture(nil, "OVERLAY")
    end
    glow.edges = edges
    edges[1]:SetPoint("TOPLEFT"); edges[1]:SetPoint("TOPRIGHT"); edges[1]:SetHeight(2)
    edges[2]:SetPoint("BOTTOMLEFT"); edges[2]:SetPoint("BOTTOMRIGHT"); edges[2]:SetHeight(2)
    edges[3]:SetPoint("TOPLEFT"); edges[3]:SetPoint("BOTTOMLEFT"); edges[3]:SetWidth(2)
    edges[4]:SetPoint("TOPRIGHT"); edges[4]:SetPoint("BOTTOMRIGHT"); edges[4]:SetWidth(2)
    local anim = glow:CreateAnimationGroup()
    anim:SetLooping("BOUNCE")
    local fade = anim:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0.2)
    fade:SetDuration(0.5)
    glow.anim = anim
    glow:Hide()
    f.glow = glow

    -- text sits above the glow border
    local textLayer = CreateFrame("Frame", nil, f)
    textLayer:SetAllPoints()
    textLayer:SetFrameLevel(f:GetFrameLevel() + 3)
    f.text = textLayer:CreateFontString(nil, "OVERLAY")
    f.text:SetFont(STANDARD_TEXT_FONT, p.fontSize, "OUTLINE")
    f.text:SetPoint("CENTER", 0, 0)

    icons[i] = f
    shownCount = -1 -- place the new icon
    return f
end

-- Icon texture and the spell to cast for a tracker (the variant you used last, if known).
local function TrackerIcon(t)
    local spell = (t.state.lastName and t.knownCasts[t.state.lastName]) or t.castSpell
    local texture = spell and C_Spell.GetSpellTexture(spell)
    if texture then return texture, spell end
    if t.kind == "weapon" then
        return GetInventoryItemTexture("player", INV_SLOT[t.slot]) or QUESTION_MARK
    end
    local first = t.firstID or (t.literalNames and t.literalNames[1])
    return first and C_Spell.GetSpellTexture(first) or QUESTION_MARK
end

local function IsCastable(t, spell)
    if t.noUsable or not spell then return true end
    return C_Spell.IsSpellUsable(spell)
end

local function ShowIcon(i, t, status, remaining, p)
    local f = icons[i] or CreateIcon(i)
    local texture, spell = TrackerIcon(t)
    if f.texture ~= texture then
        f.tex:SetTexture(texture)
        f.texture = texture
    end

    local desaturate = p.unusable == "desaturate" and not IsCastable(t, spell)
    f.tex:SetDesaturated(desaturate)
    local shade = desaturate and 0.6 or 1
    f.tex:SetVertexColor(shade, shade, shade)

    if p.showTimer and status == "expiring" then
        f.text:SetText(FormatTime(remaining))
        if remaining < RED_TEXT_BELOW then
            f.text:SetTextColor(1, 0.15, 0.15)
        else
            f.text:SetTextColor(1, 1, 1)
        end
    else
        f.text:SetText("")
    end

    -- glow mode: "off", "missing" or "both" (missing or running out)
    local mode = t.glow or p.glow
    local glow = (mode == "both" or (mode == "missing" and status == "missing")) and status or nil
    if glow ~= f.glowOn then
        f.glowOn = glow
        if glow then
            local c = GLOW_COLOR[glow]
            for _, edge in ipairs(f.glow.edges) do edge:SetColorTexture(c[1], c[2], c[3], 1) end
            f.glow:Show()
            if not f.glow.anim:IsPlaying() then f.glow.anim:Play() end
        else
            f.glow.anim:Stop()
            f.glow:Hide()
        end
    end
    f:Show()
end

-------------------------------------------------------------------------------
-- Update loop
-------------------------------------------------------------------------------

local function GloballyHidden(p, inCombat)
    if UnitIsDeadOrGhost("player") or UnitOnTaxi("player") then return true end
    if p.showWhen == "combat" and not inCombat then return true end
    if p.showWhen == "nocombat" and inCombat then return true end
    if p.hideResting and not inCombat and IsResting() then return true end
    if p.hideMounted and IsMounted() then return true end
    return false
end

-- Status of one tracker: nil (all good), "missing" or "expiring" (+ seconds left).
local function Evaluate(t, now, p)
    if t.needsSpell and not t.castSpell then return nil end
    local st = t.state

    if t.kind == "weapon" then
        if not SlotHasWeapon(t.slot) then return nil end
        local has, left = ReadWeaponEnchant(t.slot)
        st.present = has
        st.expires = (has and left > 0) and (now + left) or 0
    end

    local remaining
    if st.present and st.expires > 0 then
        remaining = st.expires - now
        if remaining <= 0 then
            st.present = false
            st.expires = 0
            remaining = nil
        end
    end
    if not st.present then return "missing" end

    local threshold = t.threshold > 0 and t.threshold or p.threshold
    if remaining and remaining <= threshold then return "expiring", remaining end
    return nil
end

function FB:Update()
    local p = self.db.profile
    if auraDirty and ScanAuras() then
        auraDirty = false
    end

    local n = 0
    if not p.locked then
        -- preview while placing the bar
        for i, t in ipairs(trackers) do
            if not (t.needsSpell and not t.castSpell) then
                n = n + 1
                if i % 2 == 1 then
                    ShowIcon(n, t, "expiring", 8, p)
                else
                    ShowIcon(n, t, "missing", nil, p)
                end
            end
        end
    else
        local inCombat = InCombatLockdown()
        if not GloballyHidden(p, inCombat) then
            local now = GetTime()
            for _, t in ipairs(trackers) do
                local status, remaining
                if inCombat or not t.combatOnly then
                    status, remaining = Evaluate(t, now, p)
                end
                if status then
                    local _, spell = TrackerIcon(t)
                    if p.unusable ~= "hide" or IsCastable(t, spell) then
                        n = n + 1
                        ShowIcon(n, t, status, remaining, p)
                    end
                end
            end
        end
    end
    if n ~= shownCount then LayoutIcons(n, p) end
    for i = n + 1, #icons do
        icons[i]:Hide()
    end
end

function FB:ApplyLayout()
    local p = self.db.profile
    MigrateProfile(p)
    container:ClearAllPoints()
    container:SetPoint("CENTER", UIParent, "CENTER", p.x, p.y)
    container:SetSize(p.iconSize, p.iconSize)
    for _, f in ipairs(icons) do
        f.text:SetFont(STANDARD_TEXT_FONT, p.fontSize, "OUTLINE")
        f:EnableMouse(not p.locked)
    end
    -- unlocked: above the options window, so the bar can be dragged while it is open
    container:SetFrameStrata(p.locked and "MEDIUM" or "TOOLTIP")
    mover:SetShown(not p.locked)
    shownCount = -1
    self:Update()
end

function FB:ResetPosition()
    local p = self.db.profile
    p.x, p.y = 0, -150
    self:ApplyLayout()
end

function FB:CreateFrames()
    container = CreateFrame("Frame", "ForeverBuffedAnchor", UIParent)
    container:SetFrameStrata("MEDIUM")
    container:SetMovable(true)
    container:SetClampedToScreen(true)
    -- the position lives in the profile, not in the client's layout cache
    container:SetDontSavePosition(true)

    -- drag area behind the icons, only shown while unlocked
    mover = CreateFrame("Frame", nil, container, "BackdropTemplate")
    mover:SetFrameLevel(container:GetFrameLevel())
    mover:EnableMouse(true)
    mover:RegisterForDrag("LeftButton")
    mover:SetScript("OnDragStart", StartDrag)
    mover:SetScript("OnDragStop", StopDrag)
    mover:SetBackdrop(BACKDROP)
    mover:SetBackdropColor(0.1, 0.1, 0.8, 0.6)
    mover:SetBackdropBorderColor(0.4, 0.4, 0.9, 1)
    mover:Hide()

    local label = mover:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("BOTTOMLEFT", mover, "TOPLEFT", 0, 2)
    label:SetText("Forever Buffed - drag to move")

    local driver = CreateFrame("Frame")
    local elapsedTotal = 0
    driver:SetScript("OnUpdate", function(_, elapsed)
        elapsedTotal = elapsedTotal + elapsed
        if elapsedTotal < UPDATE_INTERVAL then return end
        elapsedTotal = 0
        FB:Update()
    end)
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")

local function TryScanNow()
    if auraDirty and ScanAuras() then auraDirty = false end
end

-- Unit events are registered for "player" only, so their (possibly secret)
-- unit argument never has to be compared.
eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "UNIT_AURA" then
        auraDirty = true
    elseif event == "UNIT_SPELLCAST_SENT" then
        OnCastSent(...)
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        OnCastSucceeded(...)
    elseif event == "PLAYER_REGEN_DISABLED" then
        TryScanNow() -- last chance before the buff data turns secret
    elseif event == "ADDON_RESTRICTION_STATE_CHANGED" then
        local _, state = ...
        if not IsSecret(state) and state == Enum.AddOnRestrictionState.Activating then
            TryScanNow() -- still readable while this event is dispatched
        else
            auraDirty = true
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        wipe(sentSelf)
        sentCount = 0
        auraDirty = true
    elseif event == "PLAYER_DEAD" then
        for _, t in ipairs(trackers) do
            if t.kind == "aura" then MarkCancelled(t) end
        end
        auraDirty = true
    elseif event == "MINIMAP_UPDATE_TRACKING" then
        FB:RefreshTracking()
    elseif event == "SPELLS_CHANGED" then
        FB:RefreshSpells()
    elseif event == "PLAYER_ENTERING_WORLD" then
        FB:RebuildTrackers()
    else -- PLAYER_ALIVE, PLAYER_UNGHOST
        auraDirty = true
    end
end)

-------------------------------------------------------------------------------
-- Slash command
-------------------------------------------------------------------------------

function FB:PrintBuffs()
    if AurasRestricted() then
        self:Print("The game hides buff data during combat. Try again afterwards.")
        return
    end
    self:Print("Your buffs (name - spell ID):")
    local hidden = 0
    for i = 1, 255 do
        local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
        if not ok then break end
        if IsSecret(aura) or (aura and (IsSecret(aura.name) or IsSecret(aura.spellId))) then
            hidden = hidden + 1
        elseif not aura then
            break
        else
            self:Print(format("   %s - |cffffd200%d|r", aura.name, aura.spellId))
        end
    end
    if hidden > 0 then
        self:Print(format("   (%d buff(s) hidden by the game)", hidden))
    end
    for _, slot in ipairs({ "MainHand", "OffHand" }) do
        local has, left = ReadWeaponEnchant(slot)
        if has then
            local where = slot == "MainHand" and "Main hand" or "Off hand"
            local timeText = left > 0 and (FormatTime(left) .. " left") or "no time limit"
            self:Print(format("   %s: temporary weapon enchant (%s)", where, timeText))
        end
    end
end

function FB:SetLocked(locked)
    self.db.profile.locked = locked
    self:ApplyLayout()
    LibStub("AceConfigRegistry-3.0"):NotifyChange("ForeverBuffed")
end

function FB:SlashCommand(input)
    local cmd = strlower(strtrim(input or ""))
    if cmd == "lock" then
        self:SetLocked(true)
    elseif cmd == "unlock" then
        self:SetLocked(false)
    elseif cmd == "buffs" then
        self:PrintBuffs()
    elseif cmd == "help" then
        self:Print("/fb - options, /fb lock, /fb unlock, /fb buffs (list your buffs with spell IDs)")
    else
        LibStub("AceConfigDialog-3.0"):Open("ForeverBuffed")
    end
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function FB:OnProfileChanged()
    self:RebuildTrackers()
    self:RebuildOptions()
    self:ApplyLayout()
end

function FB:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("ForeverBuffedDB", defaults, true)
    self.db.RegisterCallback(self, "OnProfileChanged", "OnProfileChanged")
    self.db.RegisterCallback(self, "OnProfileCopied", "OnProfileChanged")
    self.db.RegisterCallback(self, "OnProfileReset", "OnProfileChanged")

    self:CreateFrames()
    self:SetupOptions()
    self:RegisterChatCommand("fb", "SlashCommand")
    self:RegisterChatCommand("foreverbuffed", "SlashCommand")
end

function FB:OnEnable()
    playerName = UnitName("player")

    for _, event in ipairs({
        "PLAYER_ENTERING_WORLD", "SPELLS_CHANGED", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
        "ADDON_RESTRICTION_STATE_CHANGED", "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST",
        "MINIMAP_UPDATE_TRACKING",
    }) do
        eventFrame:RegisterEvent(event)
    end
    for _, event in ipairs({ "UNIT_AURA", "UNIT_SPELLCAST_SENT", "UNIT_SPELLCAST_SUCCEEDED" }) do
        eventFrame:RegisterUnitEvent(event, "player")
    end
    self:HookCancels()

    self:RebuildTrackers()
    self:ApplyLayout()
end
