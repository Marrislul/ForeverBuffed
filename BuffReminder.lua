local _, ns = ...

local BR = LibStub("AceAddon-3.0"):NewAddon("BuffReminder", "AceConsole-3.0")
ns.BR = BR

local GetTime, pairs, ipairs, type, tonumber, pcall = GetTime, pairs, ipairs, type, tonumber, pcall
local format, ceil, strlower, wipe = string.format, math.ceil, string.lower, wipe

-- WoW Forever runs the Midnight "secret values" system: in combat, buff data
-- reaches addons as secret values that cannot be compared or tested. Every
-- value read from the aura API passes through IsSecret first.
local IsSecret = issecretvalue or function() return false end

local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"
local INV_SLOT = { MainHand = 16, OffHand = 17 }
local WEAPON_SLOT = { MainHand = 0, OffHand = 1 } -- Enum.WeaponSlot
local WEAPON_CLASS = Enum.ItemClass and Enum.ItemClass.Weapon or 2
local PERMANENT_ENCHANT = Enum.ItemEnchantType and Enum.ItemEnchantType.Permanent
local RESTRICTION_ACTIVATING = Enum.AddOnRestrictionState and Enum.AddOnRestrictionState.Activating or 1
local UPDATE_INTERVAL = 0.1
local RED_TEXT_BELOW = 5

local defaults = {
    profile = {
        locked = true,
        point = "CENTER",
        relativePoint = "CENTER",
        x = 0,
        y = -150,
        iconSize = 40,
        spacing = 4,
        grow = "RIGHT",
        threshold = 30,
        showTimer = true,
        fontSize = 14,
        glowMissing = true,
        unusable = "desaturate",
        showWhen = "always",
        hideResting = false,
        hideMounted = false,
        trackers = { ["*"] = { threshold = 0 } },
        custom = {},
        nextCustomID = 1,
    },
    char = {
        durations = {}, -- lowercase buff name -> last seen full duration
    },
}

local trackers = {}      -- enabled trackers, in display order
local states = {}        -- tracker key -> { present, expires, duration, lastID, lastName }
local auraDirty = true   -- buffs changed since the last successful scan
local sentSelf = {}      -- castGUID -> true while a cast aimed at the player is in flight
local sentCount = 0
local readableCache = {} -- spellID -> buff stays readable while auras are secret
local scan = {}          -- reused scan records
local icons = {}
local container, playerName

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function SpellName(id)
    return C_Spell.GetSpellName(id)
end

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
ns.FormatTime = FormatTime

-- The spell ID to use if the player knows this spell (current rank), else nil.
local function KnownSpell(id)
    local known = C_SpellBook.IsSpellKnown(id) or (IsPlayerSpell and IsPlayerSpell(id))
    local name = SpellName(id)
    -- A name lookup returns the current override, i.e. the highest rank.
    local info = name and C_Spell.GetSpellInfo(name)
    local rankID = info and info.spellID
    if rankID and rankID ~= id and C_SpellBook.IsSpellKnown(rankID) then return rankID end
    if known then return id end
end

local function KnownSpellByName(name)
    local info = C_Spell.GetSpellInfo(name)
    if info and info.spellID and C_SpellBook.IsSpellKnown(info.spellID) then return info.spellID end
end

-- True while the game hides buff data from addons (combat and similar).
local function AurasRestricted()
    if not (C_Secrets and C_Secrets.ShouldAurasBeSecret) then return false end
    local ok, restricted = pcall(C_Secrets.ShouldAurasBeSecret)
    if not ok or IsSecret(restricted) then return true end
    return restricted and true or false
end
ns.AurasRestricted = AurasRestricted

-- Some spells are flagged "never secret"; those stay readable in combat.
local function AuraReadable(id)
    local readable = readableCache[id]
    if readable == nil then
        readable = false
        if C_Secrets and C_Secrets.ShouldSpellAuraBeSecret then
            local ok, secret = pcall(C_Secrets.ShouldSpellAuraBeSecret, id)
            readable = ok and not IsSecret(secret) and secret == false
        end
        readableCache[id] = readable
    end
    return readable
end

-- Temporary enchant on a weapon slot: hasEnchant, secondsLeft. nil = unreadable.
local function ReadWeaponEnchant(slot)
    if C_Item and C_Item.GetWeaponEnchantInfo then
        local slotID = (Enum.WeaponSlot and Enum.WeaponSlot[slot]) or WEAPON_SLOT[slot]
        local ok, enchants = pcall(C_Item.GetWeaponEnchantInfo, slotID)
        if not ok or IsSecret(enchants) or type(enchants) ~= "table" then return nil end
        for _, e in pairs(enchants) do
            local has, kind, left = e.hasEnchant, e.enchantType, e.timeLeft
            if IsSecret(has) or IsSecret(kind) or IsSecret(left) then return nil end
            if has and kind ~= PERMANENT_ENCHANT then return true, (left or 0) / 1000 end
        end
        return false, 0
    elseif GetWeaponEnchantInfo then
        local hasMain, mainMs, _, _, hasOff, offMs = GetWeaponEnchantInfo()
        if slot == "MainHand" then return hasMain and true or false, (mainMs or 0) / 1000 end
        return hasOff and true or false, (offMs or 0) / 1000
    end
end
ns.ReadWeaponEnchant = ReadWeaponEnchant

local function GetItemClassID(itemID)
    local getInfo = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    return getInfo and select(6, getInfo(itemID))
end

-- Off-hand counts only for weapons, not shields or held-in-off-hand items.
local function SlotHasWeapon(slot)
    local itemID = GetInventoryItemID("player", INV_SLOT[slot])
    if not itemID then return false end
    if slot == "MainHand" then return true end
    return GetItemClassID(itemID) == WEAPON_CLASS
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
    if type(selfCast) == "table" then
        for _, v in ipairs(selfCast) do
            if v == id then return true end
        end
    end
    return false
end

local function NewTracker(key, kind)
    return {
        key = key,
        kind = kind or "aura",
        buffIDs = {},    -- set of buff spell IDs
        buffNames = {},  -- set of lowercase buff names
        seenIDs = {},    -- buff IDs actually seen on the player (all ranks)
        castIDs = {},
        castNames = {},  -- lowercase names of spells that apply the buff
        selfNames = {},  -- subset of castNames that always land on the player
        consumeNames = {}, -- lowercase names of own casts that remove the buff
        knownCasts = {}, -- lowercase name -> known spell ID
        state = GetState(key),
    }
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

function BR:RebuildTrackers()
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
        t.threshold = (cfg.threshold and cfg.threshold > 0) and cfg.threshold or def.threshold or 0
        if cfg.combatOnly == nil then
            t.combatOnly = def.combatOnly
        else
            t.combatOnly = cfg.combatOnly
        end
        for _, id in ipairs(def.consumedBy or {}) do AddName(t.consumeNames, SpellName(id)) end
        t.defaultDuration = def.duration
        t.needsSpell = def.needsSpell ~= false
        t.noUsable = def.noUsable
        t.castIDs = def.cast or {}
        for _, id in ipairs(def.buffs or {}) do
            t.buffIDs[id] = true
            t.firstID = t.firstID or id
            AddName(t.buffNames, SpellName(id))
        end
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
            t.combatOnly = c.combatOnly
            t.needsSpell = c.needsSpell
            t.castIDs = ids
            t.literalNames = names
            for _, id in ipairs(ids) do
                t.buffIDs[id] = true
                t.firstID = t.firstID or id
                local n = SpellName(id)
                AddName(t.buffNames, n)
                AddName(t.castNames, n)
            end
            for _, n in ipairs(names) do
                AddName(t.buffNames, n)
                AddName(t.castNames, n)
            end
            trackers[#trackers + 1] = t
        end
    end

    self:RefreshSpells()
    auraDirty = true
end

-- Which cast spells (and ranks) the player knows. Runs on SPELLS_CHANGED.
function BR:RefreshSpells()
    for _, t in ipairs(trackers) do
        t.castSpell = nil
        wipe(t.knownCasts)
        for _, id in ipairs(t.castIDs) do
            local known = KnownSpell(id)
            if known then
                t.castSpell = t.castSpell or known
                local n = SpellName(id)
                if n then t.knownCasts[strlower(n)] = known end
            end
        end
        if t.literalNames then
            for _, n in ipairs(t.literalNames) do
                local known = KnownSpellByName(n)
                if known then
                    t.castSpell = t.castSpell or known
                    t.knownCasts[strlower(n)] = known
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Buff state
-------------------------------------------------------------------------------

-- Whether every buff of a tracker is readable, so "not found" means "not there".
local function TrackerReadable(t)
    if not t.firstID or t.literalNames and t.literalNames[1] then return false end
    for id in pairs(t.buffIDs) do
        if not AuraReadable(id) then return false end
    end
    for id in pairs(t.seenIDs) do
        if not AuraReadable(id) then return false end
    end
    return true
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
            local name, id, expires, duration = aura.name, aura.spellId, aura.expirationTime, aura.duration
            if IsSecret(name) or IsSecret(id) or IsSecret(expires) or IsSecret(duration) then
                -- a single buff flagged "always secret"
                hidden = hidden + 1
            else
                n = n + 1
                local rec = scan[n]
                if not rec then
                    rec = {}
                    scan[n] = rec
                end
                rec.name = name and strlower(name) or ""
                rec.id = id
                rec.expires = expires or 0
                rec.duration = duration or 0
            end
        end
    end

    local durations = BR.db.char.durations
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
            local st = t.state
            if best then
                st.present = true
                st.expires = best.expires
                st.duration = best.duration
                st.lastID = best.id
                st.lastName = best.name
                if best.id then t.seenIDs[best.id] = true end
                if best.duration > 0 then durations[best.name] = best.duration end
            elseif hidden == 0 or TrackerReadable(t) then
                st.present = false
                st.expires = 0
            end
            -- else: it may be one of the hidden buffs, keep the last known state
        end
    end
    return true
end

local function ReadLiveAura(id)
    local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, id)
    if not ok or not aura or IsSecret(aura) then return nil end
    local expires, duration = aura.expirationTime, aura.duration
    if IsSecret(expires) or IsSecret(duration) then return nil end
    return expires or 0, duration or 0
end

local function LiveFromSet(t, set)
    for id in pairs(set) do
        if AuraReadable(id) then
            local expires, duration = ReadLiveAura(id)
            if expires then
                local st = t.state
                st.present = true
                st.expires = expires
                st.duration = duration
                st.lastID = id
                return true
            end
        end
    end
    return false
end

-- While buff data is secret: read the spells Blizzard keeps readable.
local function LiveCheck(t)
    if LiveFromSet(t, t.buffIDs) or LiveFromSet(t, t.seenIDs) then return end
    local st = t.state
    -- The exact buff we last saw is readable and gone: it really dropped.
    if st.present and st.lastID and AuraReadable(st.lastID) then
        st.present = false
        st.expires = 0
    end
end

local function OnCastSent(_, target, castGUID)
    if not castGUID or IsSecret(castGUID) or IsSecret(target) then return end
    if target == nil or target == "" or target == playerName then
        if sentCount > 50 then
            wipe(sentSelf)
            sentCount = 0
        end
        sentSelf[castGUID] = true
        sentCount = sentCount + 1
    end
end

-- The player's own cast stays readable in combat. A buff cast on yourself
-- (e.g. Battle Shout mid-fight) counts as freshly applied, with the duration
-- learned out of combat.
local function OnCastSucceeded(_, castGUID, spellID)
    if not spellID or IsSecret(spellID) then return end
    local name = SpellName(spellID)
    if not name then return end
    name = strlower(name)

    local onSelf = false
    if castGUID and not IsSecret(castGUID) then
        onSelf = sentSelf[castGUID] or false
        sentSelf[castGUID] = nil
    end

    local now = GetTime()
    local durations = BR.db.char.durations
    for _, t in ipairs(trackers) do
        if t.kind == "aura" and t.consumeNames[name] then
            -- e.g. Judgement uses up the seal
            local st = t.state
            st.present = false
            st.expires = 0
            st.lastID = nil
        elseif t.kind == "aura" and t.castNames[name] and (t.selfNames[name] or onSelf) then
            local st = t.state
            local duration = durations[name] or st.duration or t.defaultDuration
            st.present = true
            st.expires = (duration and duration > 0) and (now + duration) or 0
            st.lastName = name
            st.lastID = nil -- unconfirmed until we actually see the buff again
        end
    end
    auraDirty = true
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

local function PositionIcon(f, i, p)
    local size = p.iconSize
    local offset = (i - 1) * (size + p.spacing)
    f:SetSize(size, size)
    f:ClearAllPoints()
    if p.grow == "LEFT" then
        f:SetPoint("TOPRIGHT", container, "TOPRIGHT", -offset, 0)
    elseif p.grow == "UP" then
        f:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 0, offset)
    elseif p.grow == "DOWN" then
        f:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -offset)
    else
        f:SetPoint("TOPLEFT", container, "TOPLEFT", offset, 0)
    end
end

local function CreateIcon(i)
    local p = BR.db.profile
    local f = CreateFrame("Frame", nil, container)
    f:EnableMouse(false)

    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetColorTexture(0, 0, 0, 1)
    f.bg:SetPoint("TOPLEFT", -1, 1)
    f.bg:SetPoint("BOTTOMRIGHT", 1, -1)

    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetAllPoints()
    f.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    -- pulsing red border while the buff is missing
    local glow = CreateFrame("Frame", nil, f)
    glow:SetPoint("TOPLEFT", -3, 3)
    glow:SetPoint("BOTTOMRIGHT", 3, -3)
    glow:SetFrameLevel(f:GetFrameLevel() + 2)
    local edges = {}
    for j = 1, 4 do
        edges[j] = glow:CreateTexture(nil, "OVERLAY")
        edges[j]:SetColorTexture(1, 0.15, 0.1, 1)
    end
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

    PositionIcon(f, i, p)
    icons[i] = f
    return f
end

local function TrackerIcon(t)
    local st = t.state
    local spell = (st.lastName and t.knownCasts[st.lastName]) or t.castSpell
    local texture = spell and C_Spell.GetSpellTexture(spell)
    if texture then return texture, spell end
    if t.kind == "weapon" then
        return GetInventoryItemTexture("player", INV_SLOT[t.slot]) or QUESTION_MARK
    end
    if t.firstID then
        texture = C_Spell.GetSpellTexture(t.firstID)
    elseif t.literalNames and t.literalNames[1] then
        texture = C_Spell.GetSpellTexture(t.literalNames[1])
    end
    return texture or QUESTION_MARK
end

local function IsCastable(t, spell)
    if t.noUsable or not spell then return true end
    local ok, usable = pcall(C_Spell.IsSpellUsable, spell)
    if not ok or IsSecret(usable) then return true end
    return usable and true or false
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

    if p.showTimer and status == "expiring" and remaining then
        f.text:SetText(FormatTime(remaining))
        if remaining < RED_TEXT_BELOW then
            f.text:SetTextColor(1, 0.15, 0.15)
        else
            f.text:SetTextColor(1, 1, 1)
        end
    else
        f.text:SetText("")
    end

    local glow = status == "missing" and p.glowMissing
    if glow ~= f.glowOn then
        f.glowOn = glow
        if glow then
            f.glow:Show()
            f.glow.anim:Play()
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
    if UnitHasVehicleUI and UnitHasVehicleUI("player") then return true end
    if p.showWhen == "combat" and not inCombat then return true end
    if p.showWhen == "nocombat" and inCombat then return true end
    if p.hideResting and not inCombat and IsResting() then return true end
    if p.hideMounted and IsMounted() then return true end
    return false
end

-- Status of one tracker: nil (all good), "missing" or "expiring" (+ seconds left).
local function Evaluate(t, now, restricted, p)
    if t.needsSpell and not t.castSpell then return nil end
    local st = t.state

    if t.kind == "weapon" then
        if not SlotHasWeapon(t.slot) then return nil end
        local has, left = ReadWeaponEnchant(t.slot)
        if has ~= nil then
            st.present = has
            st.expires = (has and left > 0) and (now + left) or 0
        end
    elseif restricted then
        LiveCheck(t)
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

    local threshold = (t.threshold and t.threshold > 0) and t.threshold or p.threshold
    if remaining and remaining <= threshold then return "expiring", remaining end
    return nil
end

function BR:Update()
    local p = self.db.profile
    local now = GetTime()
    local restricted = AurasRestricted()
    if auraDirty and not restricted and ScanAuras() then
        auraDirty = false
    end

    local preview = self.testMode or not p.locked
    local inCombat = InCombatLockdown()
    local n = 0
    if preview then
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
    elseif not GloballyHidden(p, inCombat) then
        for _, t in ipairs(trackers) do
            local status, remaining
            if inCombat or not t.combatOnly then
                status, remaining = Evaluate(t, now, restricted, p)
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
    for i = n + 1, #icons do
        icons[i]:Hide()
    end
end

function BR:ApplyLayout()
    local p = self.db.profile
    container:ClearAllPoints()
    container:SetPoint(p.point, UIParent, p.relativePoint, p.x, p.y)
    container:SetSize(p.iconSize, p.iconSize)
    for i, f in ipairs(icons) do
        PositionIcon(f, i, p)
        f.text:SetFont(STANDARD_TEXT_FONT, p.fontSize, "OUTLINE")
    end
    if p.locked then
        container:EnableMouse(false)
        container:SetBackdrop(nil)
        container.label:Hide()
    else
        container:EnableMouse(true)
        container:SetBackdrop(BACKDROP)
        container:SetBackdropColor(0.1, 0.1, 0.8, 0.6)
        container:SetBackdropBorderColor(0.4, 0.4, 0.9, 1)
        container.label:Show()
    end
end

function BR:ResetPosition()
    local p = self.db.profile
    p.point, p.relativePoint, p.x, p.y = "CENTER", "CENTER", 0, -150
    self:ApplyLayout()
end

function BR:CreateFrames()
    container = CreateFrame("Frame", "BuffReminderAnchor", UIParent, "BackdropTemplate")
    container:SetFrameStrata("MEDIUM")
    container:SetMovable(true)
    container:SetClampedToScreen(true)
    container:RegisterForDrag("LeftButton")
    container:SetScript("OnDragStart", function(f) f:StartMoving() end)
    container:SetScript("OnDragStop", function(f)
        f:StopMovingOrSizing()
        local point, _, relativePoint, x, y = f:GetPoint()
        local p = BR.db.profile
        p.point, p.relativePoint, p.x, p.y = point, relativePoint, x, y
    end)

    container.label = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    container.label:SetPoint("BOTTOMLEFT", container, "TOPLEFT", 0, 4)
    container.label:SetText("Buff Reminder - drag to move")

    local driver = CreateFrame("Frame")
    local elapsedTotal = 0
    driver:SetScript("OnUpdate", function(_, elapsed)
        elapsedTotal = elapsedTotal + elapsed
        if elapsedTotal < UPDATE_INTERVAL then return end
        elapsedTotal = 0
        BR:Update()
    end)
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")

local function Register(event, unit)
    if C_EventUtils and C_EventUtils.IsEventValid and not C_EventUtils.IsEventValid(event) then return end
    if unit then
        eventFrame:RegisterUnitEvent(event, unit)
    else
        eventFrame:RegisterEvent(event)
    end
end

local function TryScanNow()
    if auraDirty and ScanAuras() then auraDirty = false end
end

local function ClearAuraStates()
    for _, t in ipairs(trackers) do
        if t.kind == "aura" then
            t.state.present = false
            t.state.expires = 0
        end
    end
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
        wipe(readableCache)
        TryScanNow() -- last chance before the buff data turns secret
    elseif event == "PLAYER_REGEN_ENABLED" then
        wipe(readableCache)
        wipe(sentSelf)
        sentCount = 0
        auraDirty = true
    elseif event == "ADDON_RESTRICTION_STATE_CHANGED" then
        wipe(readableCache)
        local _, state = ...
        if not IsSecret(state) and state == RESTRICTION_ACTIVATING then
            TryScanNow()
        else
            auraDirty = true
        end
    elseif event == "PLAYER_DEAD" then
        ClearAuraStates()
        auraDirty = true
    elseif event == "SPELLS_CHANGED" then
        BR:RefreshSpells()
    elseif event == "PLAYER_ENTERING_WORLD" then
        BR:RebuildTrackers()
    else
        auraDirty = true
    end
end)

-------------------------------------------------------------------------------
-- Slash command helpers
-------------------------------------------------------------------------------

function BR:PrintBuffs()
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
            self:Print(format("   %s - |cffffd200%d|r", aura.name or "?", aura.spellId or 0))
        end
    end
    if hidden > 0 then
        self:Print(format("   (%d buff(s) hidden by the game)", hidden))
    end
    for _, slot in ipairs({ "MainHand", "OffHand" }) do
        local has, left = ReadWeaponEnchant(slot)
        if has then
            local where = slot == "MainHand" and "Main hand" or "Off hand"
            local timeText = left and left > 0 and (FormatTime(left) .. " left") or "no time limit"
            self:Print(format("   %s: temporary weapon enchant (%s)", where, timeText))
        end
    end
end

function BR:SetLocked(locked)
    self.db.profile.locked = locked
    self:ApplyLayout()
    LibStub("AceConfigRegistry-3.0"):NotifyChange("BuffReminder")
end

function BR:SlashCommand(input)
    local cmd = strlower(strtrim(input or ""))
    if cmd == "lock" then
        self:SetLocked(true)
    elseif cmd == "unlock" then
        self:SetLocked(false)
    elseif cmd == "test" then
        self.testMode = not self.testMode
        self:Print("Test mode " .. (self.testMode and "on" or "off"))
    elseif cmd == "buffs" then
        self:PrintBuffs()
    elseif cmd == "help" then
        self:Print("/br - options, /br lock, /br unlock, /br test, /br buffs (list your buffs with spell IDs)")
    else
        LibStub("AceConfigDialog-3.0"):Open("BuffReminder")
    end
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function BR:OnProfileChanged()
    self:RebuildTrackers()
    self:RebuildOptions()
    self:ApplyLayout()
end

function BR:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("BuffReminderDB", defaults, true)
    self.db.RegisterCallback(self, "OnProfileChanged", "OnProfileChanged")
    self.db.RegisterCallback(self, "OnProfileCopied", "OnProfileChanged")
    self.db.RegisterCallback(self, "OnProfileReset", "OnProfileChanged")

    self:CreateFrames()
    self:SetupOptions()
    self:RegisterChatCommand("br", "SlashCommand")
    self:RegisterChatCommand("buffreminder", "SlashCommand")
end

function BR:OnEnable()
    playerName = UnitName("player")

    Register("PLAYER_ENTERING_WORLD")
    Register("SPELLS_CHANGED")
    Register("PLAYER_REGEN_DISABLED")
    Register("PLAYER_REGEN_ENABLED")
    Register("ADDON_RESTRICTION_STATE_CHANGED")
    Register("PLAYER_DEAD")
    Register("PLAYER_ALIVE")
    Register("PLAYER_UNGHOST")
    Register("UNIT_AURA", "player")
    Register("UNIT_SPELLCAST_SENT", "player")
    Register("UNIT_SPELLCAST_SUCCEEDED", "player")

    self:RebuildTrackers()
    self:ApplyLayout()
end
