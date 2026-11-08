local _, ns = ...
local FB = ns.FB

local AceConfig = LibStub("AceConfig-3.0")
local AceConfigDialog = LibStub("AceConfigDialog-3.0")
local AceConfigRegistry = LibStub("AceConfigRegistry-3.0")

local function P() return FB.db.profile end

local function Rebuild() FB:RebuildTrackers() end
local function Layout() FB:ApplyLayout() end

-- Simple profile setting: get/set by key, with an optional apply step.
local function Setting(key, apply)
    return function() return P()[key] end, function(_, value)
        P()[key] = value
        if apply then apply() end
    end
end

local function SpellLabel(id)
    local name = C_Spell.GetSpellName(id)
    return name and string.format("%s (%d)", name, id) or string.format("|cffff6060unknown spell ID %d|r", id)
end

local function CustomName(c)
    if c.label and c.label ~= "" then return c.label end
    local ids, names = ns.ParseSpellList(c.spells)
    local parts = {}
    for _, id in ipairs(ids) do parts[#parts + 1] = C_Spell.GetSpellName(id) or tostring(id) end
    for _, n in ipairs(names) do parts[#parts + 1] = n end
    return parts[1] and table.concat(parts, " / ") or "(empty)"
end

local function CustomMatches(c)
    local ids, names = ns.ParseSpellList(c.spells)
    local parts = {}
    for _, id in ipairs(ids) do parts[#parts + 1] = SpellLabel(id) end
    for _, n in ipairs(names) do parts[#parts + 1] = "\"" .. n .. "\"" end
    if not parts[1] then return "|cffff6060Nothing to track yet.|r" end
    return "Counts as up while any of these buffs is on you (all ranks): " .. table.concat(parts, ", ")
end

local function CustomIcon(c)
    local ids, names = ns.ParseSpellList(c.spells)
    local texture = ids[1] and C_Spell.GetSpellTexture(ids[1]) or names[1] and C_Spell.GetSpellTexture(names[1])
    return texture or "Interface\\Icons\\INV_Misc_QuestionMark"
end

local thresholdRange = {
    type = "range",
    name = "Warn threshold (0 = global)",
    desc = "Show the icon when less than this many seconds are left. 0 uses the general setting.",
    min = 0, max = 7200, softMax = 1800, step = 1, bigStep = 5,
}

local function WithThreshold(base)
    local t = {}
    for k, v in pairs(thresholdRange) do t[k] = v end
    for k, v in pairs(base) do t[k] = v end
    return t
end

local GLOW_VALUES = { off = "Off", missing = "When missing", both = "When missing or running out" }
local GLOW_SORTING = { "off", "missing", "both" }

-- Per-reminder glow; nil in the saved settings means "use the general setting".
local function GlowSelect(order, get, set)
    local values = { default = "General setting" }
    for k, v in pairs(GLOW_VALUES) do values[k] = v end
    return {
        type = "select", name = "Glow", order = order,
        desc = "Pulsing border: red while the buff is missing, orange while it is running out (below the warn threshold).",
        values = values,
        sorting = { "default", "off", "missing", "both" },
        get = function() return get() or "default" end,
        set = function(_, v)
            set(v ~= "default" and v or nil)
            Rebuild()
        end,
    }
end

-- Per-reminder switch for the buffs that don't stack with it (Data.lua EXCLUSIVE_GROUPS);
-- only shown if the reminder belongs to such a group. nil in the settings means on.
local function ExclusiveToggle(order, groups, get, set)
    return {
        type = "toggle", name = "Non-stacking buffs count", order = order,
        hidden = function() return not groups()[1] end,
        desc = function()
            local names = {}
            for _, g in ipairs(groups()) do
                for _, list in ipairs({ g.byName, g.byID }) do
                    for _, id in ipairs(list) do names[#names + 1] = SpellLabel(id) end
                end
            end
            return "These buffs don't stack with each other, so any of them counts as buffed. "
                .. "Turn it off to be reminded anyway, e.g. to replace a weaker scroll with a stronger buff.\n\n"
                .. table.concat(names, "\n")
        end,
        get = function() return get() ~= false end,
        set = function(_, v)
            set(v)
            Rebuild()
        end,
    }
end

local options = {
    name = "Forever Buffed",
    type = "group",
    childGroups = "tab",
    args = {
        general = {
            type = "group",
            name = "General",
            order = 1,
            args = {
                locked = {
                    type = "toggle",
                    name = "Lock frame",
                    desc = "Unlock to drag the icons into place. While unlocked, all enabled reminders are shown as a preview.",
                    order = 1,
                    get = function() return P().locked end,
                    set = function(_, v) FB:SetLocked(v) end,
                },
                resetPosition = {
                    type = "execute",
                    name = "Reset position",
                    order = 3,
                    func = function() FB:ResetPosition() end,
                },
                x = {
                    type = "range", name = "Position X", order = 4,
                    desc = "Horizontal distance of the bar from the screen center. With a centered grow direction this is the middle of the bar, otherwise the middle of the first icon.",
                    min = -4000, max = 4000, softMin = -1500, softMax = 1500, step = 1, bigStep = 1,
                },
                y = {
                    type = "range", name = "Position Y", order = 5,
                    desc = "Vertical distance of the bar from the screen center. With a centered grow direction this is the middle of the bar, otherwise the middle of the first icon.",
                    min = -4000, max = 4000, softMin = -1500, softMax = 1500, step = 1, bigStep = 1,
                },
                layoutHeader = { type = "header", name = "Layout", order = 10 },
                iconSize = {
                    type = "range", name = "Icon size", order = 11,
                    desc = "Icons grow and shrink around the position, evenly in all directions.",
                    min = 16, max = 128, step = 1,
                },
                spacing = {
                    type = "range", name = "Spacing", order = 12,
                    min = 0, max = 40, step = 1,
                },
                grow = {
                    type = "select", name = "Grow direction", order = 13,
                    desc = "Right, Left, Up, Down: the first icon sits at the position and further icons line up in that direction.\n\n"
                        .. "Centered: the icons spread out evenly to both sides of the position, so the bar stays centered however many reminders are shown.",
                    values = {
                        RIGHT = "Right", LEFT = "Left", UP = "Up", DOWN = "Down",
                        HCENTER = "Centered, horizontal", VCENTER = "Centered, vertical",
                    },
                    sorting = { "RIGHT", "LEFT", "UP", "DOWN", "HCENTER", "VCENTER" },
                },
                showTimer = {
                    type = "toggle", name = "Show time left", order = 14,
                    desc = "Show the remaining time on reminders for buffs that are about to run out.",
                },
                fontSize = {
                    type = "range", name = "Font size", order = 15,
                    min = 8, max = 40, step = 1,
                },
                glow = {
                    type = "select", name = "Glow", order = 16,
                    desc = "Pulsing border: red while a buff is missing, orange while it is running out (below the warn threshold). Each reminder can override this.",
                    values = GLOW_VALUES,
                    sorting = GLOW_SORTING,
                },
                behaviorHeader = { type = "header", name = "Behavior", order = 20 },
                threshold = WithThreshold({
                    name = "Warn threshold",
                    desc = "Show the icon when a buff has less than this many seconds left. 0 = only when it is missing.",
                    order = 21,
                }),
                unusable = {
                    type = "select", name = "When you can't cast it", order = 22,
                    desc = "What to do while the spell is not castable, e.g. no rage for Battle Shout or no mana.",
                    values = { show = "Show normally", desaturate = "Show greyed out", hide = "Hide" },
                    sorting = { "show", "desaturate", "hide" },
                },
                visibilityHeader = { type = "header", name = "Visibility", order = 30 },
                showWhen = {
                    type = "select", name = "Show", order = 31,
                    values = { always = "Always", combat = "Only in combat", nocombat = "Only out of combat" },
                    sorting = { "always", "combat", "nocombat" },
                },
                hideResting = {
                    type = "toggle", name = "Hide while resting", order = 32,
                    desc = "Hide out of combat in inns and cities.",
                },
                hideMounted = { type = "toggle", name = "Hide while mounted", order = 33 },
                combatHeader = { type = "header", name = "Combat", order = 40 },
                combatInfo = {
                    type = "description", order = 41, fontSize = "medium",
                    name = "WoW Forever hides buff data from addons during combat. Forever Buffed keeps working with what it knew right before the fight:\n"
                        .. "- buff timers keep running, so a buff that runs out mid-fight is reported\n"
                        .. "- buffs you cast on yourself (e.g. Battle Shout) are picked up immediately\n"
                        .. "- weapon enchants (stones, oils, poisons, imbues) are always tracked live\n"
                        .. "- buffs that others cast on you, that get dispelled or whose charges are used up (Lightning Shield) show up once combat ends\n"
                        .. "- a buff you right-click away in combat is only noticed until your buffs first change in that fight. "
                        .. "A /cancelaura macro (e.g. /cancelaura Devotion Aura) is always recognised",
                },
            },
        },
        trackers = {
            type = "group",
            name = "Class & General",
            order = 2,
            args = {},
        },
        custom = {
            type = "group",
            name = "Custom Buffs",
            order = 3,
            args = {},
        },
        buffs = {
            type = "group",
            name = "Your Buffs",
            order = 4,
            args = {},
        },
    },
}

-- Plain settings in the General tab read and write the profile key of the same name.
local LAYOUT_KEYS = { x = true, y = true, iconSize = true, spacing = true, grow = true, fontSize = true }
for key, opt in pairs(options.args.general.args) do
    if not opt.get and opt.type ~= "header" and opt.type ~= "description" and opt.type ~= "execute" then
        local apply = LAYOUT_KEYS[key] and Layout or nil
        opt.get, opt.set = Setting(key, apply)
    end
end

local function BuildTrackerArgs()
    local args = {}
    local _, class = UnitClass("player")
    local list = {}
    for _, def in ipairs(ns.CLASS_TRACKERS[class] or {}) do list[#list + 1] = def end
    for _, def in ipairs(ns.GENERAL_TRACKERS) do list[#list + 1] = def end

    args.intro = {
        type = "description", order = 0, fontSize = "medium",
        name = "Reminders for your class, weapons, gathering and camps. Reminders tied to a spell only appear once you have learned it.\n",
    }
    for i, def in ipairs(list) do
        local function cfg() return P().trackers[def.key] end
        local groups = ns.ExclusiveGroups(def.buffs or {})
        args[def.key] = {
            type = "group",
            inline = true,
            order = i,
            name = function() return ns.TrackerLabel(def) end,
            args = {
                enabled = {
                    type = "toggle",
                    name = "Enabled",
                    desc = def.desc,
                    order = 1,
                    get = function()
                        local v = cfg().enabled
                        if v == nil then return def.default end
                        return v
                    end,
                    set = function(_, v)
                        cfg().enabled = v
                        Rebuild()
                    end,
                },
                combatOnly = {
                    type = "toggle",
                    name = "Only in combat",
                    order = 2,
                    get = function()
                        local v = cfg().combatOnly
                        if v == nil then return def.combatOnly or false end
                        return v
                    end,
                    set = function(_, v)
                        cfg().combatOnly = v
                        Rebuild()
                    end,
                },
                threshold = WithThreshold({
                    order = 3,
                    name = def.threshold and "Warn threshold (0 = default)" or thresholdRange.name,
                    desc = def.threshold
                        and string.format("Show the icon when less than this many seconds are left. 0 uses the default for this reminder (%d s).", def.threshold)
                        or thresholdRange.desc,
                    get = function() return cfg().threshold or 0 end,
                    set = function(_, v)
                        cfg().threshold = v
                        Rebuild()
                    end,
                }),
                glow = GlowSelect(4, function() return cfg().glow end, function(v) cfg().glow = v end),
                exclusive = ExclusiveToggle(5, function() return groups end,
                    function() return cfg().exclusive end, function(v) cfg().exclusive = v end),
            },
        }
    end
    return args
end

local function BuildCustomArgs()
    local args = {
        add = {
            type = "input",
            name = "Add buff",
            desc = "Spell ID(s) or buff name(s), separated by commas. Several entries form one reminder that is satisfied by any of them, e.g. \"1459, 23028\" for Arcane Intellect or Arcane Brilliance.",
            order = 1,
            width = "full",
            get = function() return "" end,
            set = function(_, v) FB:AddCustom(v) end,
        },
        help = {
            type = "description",
            order = 2,
            fontSize = "medium",
            name = "Tip: the |cffffd200Your Buffs|r tab lists all your current buffs with their spell IDs and adds them here with one click. IDs from wowhead.com/classic work as well. Names work too (e.g. \"Well Fed\"), but must match the buff name in your game language.\n",
        },
    }
    for i, c in ipairs(P().custom) do
        args["custom" .. c.uid] = {
            type = "group",
            inline = true,
            order = 10 + i,
            name = function() return CustomName(c) end,
            args = {
                matches = {
                    type = "description",
                    order = 1,
                    width = "full",
                    name = function() return CustomMatches(c) end,
                    image = function() return CustomIcon(c) end,
                    imageWidth = 24,
                    imageHeight = 24,
                },
                enabled = {
                    type = "toggle", name = "Enabled", order = 2,
                    get = function() return c.enabled end,
                    set = function(_, v)
                        c.enabled = v
                        Rebuild()
                    end,
                },
                needsSpell = {
                    type = "toggle", name = "Only if I know the spell", order = 3,
                    desc = "Only remind while you can cast one of these spells yourself. Leave it off for buffs from others, food, elixirs or flasks.",
                    get = function() return c.needsSpell end,
                    set = function(_, v)
                        c.needsSpell = v
                        Rebuild()
                    end,
                },
                combatOnly = {
                    type = "toggle", name = "Only in combat", order = 3.5,
                    get = function() return c.combatOnly end,
                    set = function(_, v)
                        c.combatOnly = v
                        Rebuild()
                    end,
                },
                exclusive = ExclusiveToggle(3.7, function() return ns.ExclusiveGroups(ns.ParseSpellList(c.spells)) end,
                    function() return c.exclusive end, function(v) c.exclusive = v end),
                spells = {
                    type = "input", name = "Spell IDs / names", order = 4, width = "double",
                    get = function() return c.spells end,
                    set = function(_, v)
                        c.spells = v
                        Rebuild()
                    end,
                },
                label = {
                    type = "input", name = "Display name (optional)", order = 5,
                    get = function() return c.label or "" end,
                    set = function(_, v) c.label = strtrim(v) end,
                },
                threshold = WithThreshold({
                    order = 6,
                    get = function() return c.threshold or 0 end,
                    set = function(_, v)
                        c.threshold = v
                        Rebuild()
                    end,
                }),
                glow = GlowSelect(6.5, function() return c.glow end, function(v) c.glow = v end),
                delete = {
                    type = "execute", name = "Delete", order = 7,
                    confirm = true,
                    confirmText = "Delete this reminder?",
                    func = function() FB:RemoveCustom(c) end,
                },
            },
        }
    end
    return args
end

-------------------------------------------------------------------------------
-- Your Buffs tab: what is on you right now
-------------------------------------------------------------------------------

local BUFF_ROWS = 60
local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"
local buffList, buffSecret, buffReadAt, buffListOld = {}, 0, nil, false

-- The current buffs, read once per frame so that every option of one redraw sees the
-- same list. In combat the game hides them and the list from before the fight stays.
local function BuffList()
    local now = GetTime()
    if buffReadAt ~= now then
        buffReadAt = now
        local list, secret = FB:ReadBuffs()
        if list then
            buffList, buffSecret, buffListOld = list, secret, false
        else
            buffListOld = true
        end
    end
    return buffList
end

local function TrackerName(t)
    if t.def then return ns.TrackerLabel(t.def) end
    return CustomName(t.custom)
end

local function InCustomList(e)
    for _, c in ipairs(P().custom) do
        local ids, names = ns.ParseSpellList(c.spells)
        for _, id in ipairs(ids) do
            local n = C_Spell.GetSpellName(id)
            if id == e.id or (n and strlower(n) == e.key) then return true end
        end
        for _, n in ipairs(names) do
            if strlower(n) == e.key then return true end
        end
    end
    return false
end

local function BuffRowText(e)
    local lines = {}
    if e.weapon then
        lines[1] = string.format("|cffffd200%s: temporary weapon enchant|r",
            e.weapon == "MainHand" and "Main hand" or "Off hand")
        if e.enchantID and e.enchantID > 0 then
            lines[1] = lines[1] .. string.format("  |cff999999enchant ID %d|r", e.enchantID)
        end
    else
        local rank = (e.rank and e.rank ~= "") and (" " .. e.rank) or ""
        lines[1] = string.format("|cffffd200%s|r%s  |cff999999spell ID %d|r", e.name, rank, e.id)
        if e.stacks > 1 then lines[1] = lines[1] .. string.format("  x%d", e.stacks) end
        if e.hidden then lines[1] = lines[1] .. "  |cff999999(hidden buff)|r" end
    end

    local info = {}
    if not e.weapon then info[1] = "cast by " .. ns.BuffCaster(e) end
    if e.expires > 0 then
        local left = ns.FormatTime(math.max(0, e.expires - GetTime())) .. " left"
        if e.duration > 0 then left = left .. " of " .. ns.FormatTime(e.duration) end
        info[#info + 1] = left
    else
        info[#info + 1] = "no time limit"
    end
    if e.charges and e.charges > 0 then info[#info + 1] = string.format("%d charges", e.charges) end
    lines[2] = table.concat(info, ", ")

    if e.trackers[1] then
        local names = {}
        for _, m in ipairs(e.trackers) do
            local n = TrackerName(m.tracker)
            if m.note == "weaker" then
                n = n .. " |cffff9050(weaker than yours: doesn't count)|r"
            elseif m.note == "others" then
                n = n .. " |cffaaaaaa(not yours: only counts if you can't add your own)|r"
            elseif m.note == "kind" then
                n = n .. " |cffaaaaaa(takes the place of one of them)|r"
            end
            names[#names + 1] = n
        end
        lines[3] = "|cff80ff80Counts for:|r " .. table.concat(names, ", ")
    else
        lines[3] = "|cff999999No reminder uses it.|r"
    end
    return table.concat(lines, "\n")
end

local function BuildBuffArgs()
    local args = {
        intro = {
            type = "description", order = 0, fontSize = "medium",
            name = function()
                local list = BuffList()
                local text = "All buffs on you right now: spell ID, who cast them, time left and which reminder they count for. "
                    .. "|cffffd200Add reminder|r puts a buff into Custom Buffs. The list updates by itself while this tab is open."
                if buffListOld then
                    text = text .. "\n\n|cffff6060The game hides buff data during combat. This is the list from before the fight.|r"
                end
                if not list[1] then text = text .. "\n\nYou have no buffs right now." end
                if buffSecret > 0 then
                    text = text .. string.format("\n\n%d buff(s) hidden by the game.", buffSecret)
                end
                return text .. "\n"
            end,
        },
    }
    for i = 1, BUFF_ROWS do
        local function entry() return BuffList()[i] end
        args["buff" .. i] = {
            type = "description", order = i * 3, fontSize = "medium", width = 2.4,
            hidden = function() return not entry() end,
            name = function()
                local e = entry()
                return e and BuffRowText(e) or ""
            end,
            image = function()
                local e = entry()
                return e and e.icon or QUESTION_MARK
            end,
            imageWidth = 28,
            imageHeight = 28,
        }
        args["add" .. i] = {
            type = "execute", order = i * 3 + 1, width = 0.8,
            name = function()
                local e = entry()
                return (e and not e.weapon and InCustomList(e)) and "In your list" or "Add reminder"
            end,
            desc = function()
                local e = entry()
                if not e or e.weapon then return nil end
                if InCustomList(e) then return "Custom Buffs already has a reminder for " .. e.name .. "." end
                return string.format("Adds a reminder for %s (spell ID %d) to Custom Buffs. Every rank counts.", e.name, e.id)
            end,
            -- custom reminders only see the buff list, not hidden buffs or weapon enchants
            hidden = function()
                local e = entry()
                return not e or e.weapon or e.hidden
            end,
            disabled = function()
                local e = entry()
                return not e or InCustomList(e)
            end,
            func = function()
                -- the row as it was drawn, not a fresh read
                local e = buffList[i]
                if e and not e.weapon and not e.hidden and not InCustomList(e) then
                    FB:AddCustom(tostring(e.id))
                    FB:Print(string.format("Added %s to Custom Buffs.", e.name))
                end
            end,
        }
        -- line break, so a wide window doesn't put two buffs on one line
        args["break" .. i] = {
            type = "description", order = i * 3 + 2, width = "full", name = "",
            hidden = function() return not entry() end,
        }
    end
    return args
end
-- fixed rows that read the list while they are drawn, so they are built once
options.args.buffs.args = BuildBuffArgs()

-- Redraw the Your Buffs tab while it is open: right after your buffs change, and every
-- few seconds for the timers. Other tabs are never redrawn, that would get in the way
-- of dragging a slider.
local function BuffsTabShown()
    local groups = AceConfigDialog:GetStatusTable("ForeverBuffed").groups
    if not groups or groups.selected ~= "buffs" then return false end
    if AceConfigDialog.OpenFrames.ForeverBuffed then return true end
    return FB.optionsFrame ~= nil and FB.optionsFrame:IsVisible()
end

local refresher = CreateFrame("Frame")
local buffsChanged, sinceRedraw = false, 0
refresher:RegisterUnitEvent("UNIT_AURA", "player")
refresher:RegisterUnitEvent("UNIT_INVENTORY_CHANGED", "player")
refresher:RegisterEvent("PLAYER_REGEN_DISABLED")
refresher:RegisterEvent("PLAYER_REGEN_ENABLED")
refresher:SetScript("OnEvent", function() buffsChanged = true end)
refresher:SetScript("OnUpdate", function(_, elapsed)
    sinceRedraw = sinceRedraw + elapsed
    if sinceRedraw < 1 or (not buffsChanged and sinceRedraw < 10) then return end
    if BuffsTabShown() then AceConfigRegistry:NotifyChange("ForeverBuffed") end
    buffsChanged, sinceRedraw = false, 0
end)

function FB:AddCustom(text)
    local ids, names = ns.ParseSpellList(text)
    if #ids == 0 and #names == 0 then return end
    local p = P()
    local uid = p.nextCustomID
    p.nextCustomID = uid + 1
    p.custom[#p.custom + 1] = {
        uid = uid,
        spells = strtrim(text),
        label = "",
        enabled = true,
        needsSpell = false,
        threshold = 0,
    }
    self:RebuildTrackers()
    self:RebuildOptions()
end

function FB:RemoveCustom(entry)
    local list = P().custom
    for i = #list, 1, -1 do
        if list[i] == entry then table.remove(list, i) end
    end
    self:RebuildTrackers()
    self:RebuildOptions()
end

function FB:RebuildOptions()
    options.args.trackers.args = BuildTrackerArgs()
    options.args.custom.args = BuildCustomArgs()
    AceConfigRegistry:NotifyChange("ForeverBuffed")
end

function FB:SetupOptions()
    options.args.profiles = LibStub("AceDBOptions-3.0"):GetOptionsTable(self.db)
    options.args.profiles.order = 100
    self:RebuildOptions()
    AceConfig:RegisterOptionsTable("ForeverBuffed", options)
    self.optionsFrame = AceConfigDialog:AddToBlizOptions("ForeverBuffed", "Forever Buffed")
end
