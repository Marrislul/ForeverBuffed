local _, ns = ...
local BR = ns.BR

local AceConfig = LibStub("AceConfig-3.0")
local AceConfigDialog = LibStub("AceConfigDialog-3.0")
local AceConfigRegistry = LibStub("AceConfigRegistry-3.0")

local function P() return BR.db.profile end

local function Rebuild() BR:RebuildTrackers() end
local function Layout() BR:ApplyLayout() end

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

local options = {
    name = "Buff Reminder",
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
                    set = function(_, v) BR:SetLocked(v) end,
                },
                test = {
                    type = "toggle",
                    name = "Test mode",
                    desc = "Show all enabled reminders as a preview, even while locked.",
                    order = 2,
                    get = function() return BR.testMode end,
                    set = function(_, v) BR.testMode = v end,
                },
                resetPosition = {
                    type = "execute",
                    name = "Reset position",
                    order = 3,
                    func = function() BR:ResetPosition() end,
                },
                layoutHeader = { type = "header", name = "Layout", order = 10 },
                iconSize = {
                    type = "range", name = "Icon size", order = 11,
                    min = 16, max = 128, step = 1,
                },
                spacing = {
                    type = "range", name = "Spacing", order = 12,
                    min = 0, max = 40, step = 1,
                },
                grow = {
                    type = "select", name = "Grow direction", order = 13,
                    values = { RIGHT = "Right", LEFT = "Left", UP = "Up", DOWN = "Down" },
                },
                showTimer = {
                    type = "toggle", name = "Show time left", order = 14,
                    desc = "Show the remaining time on reminders for buffs that are about to run out.",
                },
                fontSize = {
                    type = "range", name = "Font size", order = 15,
                    min = 8, max = 40, step = 1,
                },
                glowMissing = {
                    type = "toggle", name = "Glow when missing", order = 16,
                    desc = "Pulsing red border while a buff is missing completely.",
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
                    name = "WoW Forever hides buff data from addons during combat. Buff Reminder keeps working with what it knew right before the fight:\n"
                        .. "- buff timers keep running, so a buff that runs out mid-fight is reported\n"
                        .. "- buffs you cast on yourself (e.g. Battle Shout) are picked up immediately\n"
                        .. "- weapon enchants (stones, oils, poisons, imbues) are always tracked live\n"
                        .. "- buffs that others cast on you, or that get dispelled, show up once combat ends",
                },
            },
        },
        trackers = {
            type = "group",
            name = "Class & Weapons",
            order = 2,
            args = {},
        },
        custom = {
            type = "group",
            name = "Custom Buffs",
            order = 3,
            args = {},
        },
    },
}

-- Plain settings in the General tab read and write the profile key of the same name.
for key, opt in pairs(options.args.general.args) do
    if not opt.get and opt.type ~= "header" and opt.type ~= "description" and opt.type ~= "execute" then
        local apply = (key == "iconSize" or key == "spacing" or key == "grow" or key == "fontSize") and Layout or nil
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
        name = "Reminders for your class. Class reminders only appear once you have learned the spell.\n",
    }
    for i, def in ipairs(list) do
        local function cfg() return P().trackers[def.key] end
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
            set = function(_, v) BR:AddCustom(v) end,
        },
        help = {
            type = "description",
            order = 2,
            fontSize = "medium",
            name = "Tip: type |cffffd200/br buffs|r to list all your current buffs with their spell IDs. IDs from wowhead.com/classic work as well. Names work too (e.g. \"Well Fed\"), but must match the buff name in your game language.\n",
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
                delete = {
                    type = "execute", name = "Delete", order = 7,
                    confirm = true,
                    confirmText = "Delete this reminder?",
                    func = function() BR:RemoveCustom(c) end,
                },
            },
        }
    end
    return args
end

function BR:AddCustom(text)
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

function BR:RemoveCustom(entry)
    local list = P().custom
    for i = #list, 1, -1 do
        if list[i] == entry then table.remove(list, i) end
    end
    self:RebuildTrackers()
    self:RebuildOptions()
end

function BR:RebuildOptions()
    options.args.trackers.args = BuildTrackerArgs()
    options.args.custom.args = BuildCustomArgs()
    AceConfigRegistry:NotifyChange("BuffReminder")
end

function BR:SetupOptions()
    options.args.profiles = LibStub("AceDBOptions-3.0"):GetOptionsTable(self.db)
    options.args.profiles.order = 100
    self:RebuildOptions()
    AceConfig:RegisterOptionsTable("BuffReminder", options)
    self.optionsFrame = AceConfigDialog:AddToBlizOptions("BuffReminder", "Buff Reminder")
end
