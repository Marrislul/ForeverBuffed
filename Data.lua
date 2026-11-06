local _, ns = ...

-- Built-in trackers. Spell IDs are WoW Forever (1.60) IDs; rank 1 is enough,
-- because buffs are matched by spell name: every rank and the versions other
-- players cast on you count as well. IDs the client does not know are ignored.
--
--   key         saved-variable key, never change it
--   kind        "aura" (buff on you, default) or "weapon" (temporary weapon enchant)
--   buffs       spell IDs whose buff satisfies the tracker
--   cast        spells that apply it. The tracker is only active once you know
--               one of them; the first known one gives the icon and the
--               "enough rage/mana?" check
--   selfCast    true, or a list of cast IDs, that always land on you. Lets the
--               addon see these casts in combat, where the game hides buff data
--   slot        weapon slot for kind = "weapon": "MainHand" or "OffHand"
--   label       display name; default: the buff names joined with " / "
--   needsSpell  false = active without knowing a cast spell
--   noUsable    true = skip the "enough rage/mana?" check
--   consumedBy  own casts that remove the buff (e.g. Judgement eats the seal)
--   duration    buff duration in seconds, used for a cast in combat before the
--               addon has seen the buff once (it learns the real one out of combat)
--   threshold   default warn threshold in seconds (instead of the general one)
--   combatOnly  default for "only in combat"
--   default     enabled in a new profile

ns.CLASS_TRACKERS = {
    WARRIOR = {
        { key = "battleShout", buffs = { 6673 }, cast = { 6673 }, selfCast = true, duration = 120, default = true },
    },
    MAGE = {
        { key = "arcaneIntellect", buffs = { 1459, 23028 }, cast = { 1459, 23028 }, selfCast = { 23028 }, default = true },
        { key = "mageArmor", buffs = { 7302, 168, 6117 }, cast = { 7302, 168, 6117 }, selfCast = true, default = true },
    },
    PRIEST = {
        { key = "fortitude", buffs = { 1243, 21562 }, cast = { 1243, 21562 }, selfCast = { 21562 }, default = true },
        { key = "innerFire", buffs = { 588 }, cast = { 588 }, selfCast = true, duration = 600, default = true },
        { key = "divineSpirit", buffs = { 14752, 27681 }, cast = { 14752, 27681 }, selfCast = { 27681 }, default = true },
        { key = "shadowProtection", buffs = { 976, 27683 }, cast = { 976, 27683 }, selfCast = { 27683 }, default = false },
    },
    DRUID = {
        { key = "markOfTheWild", buffs = { 1126, 21849 }, cast = { 1126, 21849 }, selfCast = { 21849 }, default = true },
        { key = "omenOfClarity", buffs = { 16864 }, cast = { 16864 }, selfCast = true, default = true },
        { key = "thorns", buffs = { 467 }, cast = { 467 }, default = false },
    },
    PALADIN = {
        {
            key = "blessing", label = "Blessing (any)",
            buffs = { 19740, 19742, 20217, 1038, 19977, 20911, 25782, 25894, 25898, 25895, 25890, 25899 },
            cast = { 19740, 19742, 20217, 1038, 19977, 20911, 25782, 25894, 25898, 25895, 25890, 25899 },
            default = true,
        },
        {
            key = "paladinAura", label = "Aura (any)",
            buffs = { 465, 7294, 19746, 19876, 19888, 19891, 20218 },
            cast = { 465, 7294, 19746, 19876, 19888, 19891, 20218 },
            selfCast = true, default = true,
        },
        { key = "righteousFury", buffs = { 25780 }, cast = { 25780 }, selfCast = true, default = false },
        {
            -- Righteousness (rank 1 is 20154, replaced by 21084 once Judgement is learned),
            -- Crusader, Justice, Light, Wisdom, Command
            key = "seal", label = "Seal (any)",
            buffs = { 20154, 21084, 21082, 20164, 20165, 20166, 20375 },
            cast = { 21084, 20154, 21082, 20164, 20165, 20166, 20375 },
            selfCast = true,
            consumedBy = { 20271 }, -- Judgement
            duration = 30, threshold = 5, combatOnly = true, default = true,
        },
    },
    HUNTER = {
        {
            key = "aspect", label = "Aspect (any)",
            buffs = { 13165, 13163, 5118, 13159, 20043, 13161 },
            cast = { 13165, 13163, 5118, 13159, 20043, 13161 },
            selfCast = true, default = true,
        },
        { key = "trueshotAura", buffs = { 19506 }, cast = { 19506 }, selfCast = true, default = true },
    },
    WARLOCK = {
        { key = "demonArmor", buffs = { 706, 687 }, cast = { 706, 687 }, selfCast = true, default = true },
        { key = "soulLink", buffs = { 19028 }, cast = { 19028 }, selfCast = true, default = false },
    },
    SHAMAN = {
        -- Windfury, Flametongue, Frostbrand, Rockbiter: weapon enchants, not buffs
        { key = "imbueMainHand", kind = "weapon", slot = "MainHand", label = "Weapon imbue (main hand)", cast = { 8232, 8024, 8033, 8017 }, default = true },
        { key = "imbueOffHand", kind = "weapon", slot = "OffHand", label = "Weapon imbue (off hand)", cast = { 8232, 8024, 8033, 8017 }, default = true },
        { key = "lightningShield", buffs = { 324 }, cast = { 324 }, selfCast = true, duration = 600, default = false },
    },
    ROGUE = {
        -- Instant, Deadly, Wound, Crippling, Mind-numbing Poison (the recipes)
        { key = "poisonMainHand", kind = "weapon", slot = "MainHand", label = "Poison (main hand)", cast = { 8687, 2835, 13220, 3420, 5763 }, noUsable = true, default = true },
        { key = "poisonOffHand", kind = "weapon", slot = "OffHand", label = "Poison (off hand)", cast = { 8687, 2835, 13220, 3420, 5763 }, noUsable = true, default = true },
    },
}

-- Available to every class.
ns.GENERAL_TRACKERS = {
    {
        key = "weaponMainHand", kind = "weapon", slot = "MainHand", label = "Weapon buff (main hand)",
        desc = "Any temporary weapon enchant: sharpening stones, weightstones, wizard and mana oils, poisons, imbues.",
        needsSpell = false, default = false,
    },
    {
        key = "weaponOffHand", kind = "weapon", slot = "OffHand", label = "Weapon buff (off hand)",
        desc = "Any temporary weapon enchant on the off-hand weapon. Shields and off-hand items are ignored.",
        needsSpell = false, default = false,
    },
}
