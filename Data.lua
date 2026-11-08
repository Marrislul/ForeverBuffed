local _, ns = ...

-- Built-in trackers. Spell IDs are WoW Forever IDs (checked against wowhead.com/forever
-- and the Forever trainer data). Rank 1 is enough: buffs are matched by name, so every
-- rank and the versions other players cast on you count as well.
--
--   key         saved-variable key, never change it
--   kind        "aura" (buff on you, default), "weapon" (temporary weapon enchant) or
--               "tracking" (any minimap tracking spell, e.g. Find Herbs)
--   buffs       spell IDs whose buff satisfies the tracker
--   cast        spells that apply it. The tracker is only active once you know one
--               of them; the first known one gives the icon and the "enough mana?" check
--   selfCast    true, or a list of cast IDs, that always land on you. Lets the addon
--               see these casts in combat, where the game hides buff data
--   slot        weapon slot for kind = "weapon": "MainHand" or "OffHand"
--   label       display name; default: the buff names joined with " / "
--   needsSpell  false = active without knowing a cast spell
--   noUsable    true = skip the "enough rage/mana?" check
--   duration    seconds, for a cast in combat before the buff was ever seen out of
--               combat (after that the real duration is used)
--   threshold   default warn threshold in seconds instead of the general one
--   combatOnly  default for "only in combat"
--   own         only your own buff counts, not the same buff from someone else
--   kinds       with own: the buffs that don't stack with each other (byName every rank,
--               byID e.g. camp buffs); default: every buff name is a kind of its own.
--               The buffs of others count once they cover every kind you know at least
--               as strong as yours (ns.RANKS), and the icon shows a kind you can still add
--   desc        tooltip in the options
--   default     enabled in a new profile

ns.CLASS_TRACKERS = {
    WARRIOR = {
        { key = "battleShout", buffs = { 6673 }, cast = { 6673 }, selfCast = true, duration = 180, default = true },
    },
    MAGE = {
        -- Arcane Intellect / Arcane Brilliance
        { key = "arcaneIntellect", buffs = { 1459, 23028 }, cast = { 1459, 23028 }, selfCast = { 23028 }, default = true },
        -- Ice Armor, Frost Armor, Mage Armor
        { key = "mageArmor", buffs = { 7302, 168, 6117 }, cast = { 7302, 168, 6117 }, selfCast = true, default = true },
    },
    PRIEST = {
        -- Power Word: Fortitude / Prayer of Fortitude
        { key = "fortitude", buffs = { 1243, 21562 }, cast = { 1243, 21562 }, selfCast = { 21562 }, default = true },
        { key = "innerFire", buffs = { 588 }, cast = { 588 }, selfCast = true, duration = 600, default = true },
        -- Divine Spirit / Prayer of Spirit
        { key = "divineSpirit", buffs = { 14752, 27681 }, cast = { 14752, 27681 }, selfCast = { 27681 }, default = true },
        -- racial: Touch of Weakness (Undead), Shadowguard (Troll)
        { key = "touchOfWeakness", buffs = { 2652 }, cast = { 2652 }, selfCast = true, duration = 600, default = true },
        { key = "shadowguard", buffs = { 18137 }, cast = { 18137 }, selfCast = true, duration = 600, default = true },
        -- Shadow Protection / Prayer of Shadow Protection
        { key = "shadowProtection", buffs = { 976, 27683 }, cast = { 976, 27683 }, selfCast = { 27683 }, default = false },
    },
    DRUID = {
        -- Mark of the Wild / Gift of the Wild (Omen of Clarity is passive on Forever)
        { key = "markOfTheWild", buffs = { 1126, 21849 }, cast = { 1126, 21849 }, selfCast = { 21849 }, default = true },
        { key = "thorns", buffs = { 467 }, cast = { 467 }, default = false },
    },
    PALADIN = {
        -- Might, Wisdom, Kings and their Greater versions. Salvation stacks with the
        -- others on Forever; Light and Sanctuary don't exist there.
        {
            key = "blessing", label = "Blessing (any)",
            buffs = { 19740, 19742, 20217, 25782, 25894, 25898 },
            cast = { 19740, 19742, 20217, 25782, 25894, 25898 },
            -- Every paladin puts one blessing on you, and different ones stack: another
            -- paladin's Wisdom leaves room for your Might.
            own = true,
            kinds = {
                { byName = { 19740, 25782 }, byID = { 1230164 } }, -- Might, camp: Boosted Attack Power
                { byName = { 19742, 25894 }, byID = { 1230587 } }, -- Wisdom, camp: Boosted Mana Regeneration
                { byName = { 20217, 25898 }, byID = { 1230098 } }, -- Kings, camp: Boosted Stats
            },
            desc = "Your own blessing on you. Blessings of other paladins stack with yours, so they "
                .. "only count once they cover every blessing you know, each at least as strong as yours.",
            default = true,
        },
        {
            -- Devotion, Retribution, Concentration, Shadow/Frost/Fire Resistance, Sanctity
            -- Another paladin's aura reaches you too, but yours is a different one on top.
            key = "paladinAura", label = "Aura (any)",
            buffs = { 465, 7294, 19746, 19876, 19888, 19891, 20218 },
            cast = { 465, 7294, 19746, 19876, 19888, 19891, 20218 },
            selfCast = true, own = true, default = true,
            desc = "Your own aura. The aura of another paladin in your group only counts once "
                .. "the auras of others cover every aura you know, each at least as strong as yours.",
        },
        { key = "righteousFury", buffs = { 25780 }, cast = { 25780 }, selfCast = true, default = false },
        {
            -- Righteousness (rank 1 is 20154, replaced by 21084 once Judgement is learned),
            -- Fury (Forever tank seal), Crusader, Justice, Light, Wisdom, Command.
            -- Judgement doesn't use up the seal on Forever.
            key = "seal", label = "Seal (any)",
            buffs = { 20154, 21084, 1311649, 1311656, 21082, 20164, 20165, 20166, 20375 },
            cast = { 21084, 20154, 1311649, 1311656, 21082, 20164, 20165, 20166, 20375 },
            selfCast = true,
            duration = 30, threshold = 5, combatOnly = true, default = true,
        },
    },
    HUNTER = {
        {
            -- Hawk, Monkey, Cheetah, Pack, Wild, Beast (classic and Forever version).
            -- Another hunter's Pack or Wild reaches you too, but leaves room for your own aspect.
            key = "aspect", label = "Aspect (any)",
            buffs = { 13165, 13163, 5118, 13159, 20043, 13161, 1299445 },
            cast = { 13165, 13163, 5118, 13159, 20043, 13161, 1299445 },
            selfCast = true, own = true, default = true,
            desc = "Your own aspect. Aspect of the Pack or of the Wild from another hunter only "
                .. "counts once the aspects of others cover every aspect you know, each at least as strong as yours.",
        },
        -- classic and Forever version
        { key = "trueshotAura", buffs = { 19506, 1299346 }, cast = { 19506, 1299346 }, selfCast = true, default = true },
    },
    WARLOCK = {
        -- Demon Armor / Demon Skin
        { key = "demonArmor", buffs = { 706, 687 }, cast = { 706, 687 }, selfCast = true, default = true },
    },
    SHAMAN = {
        -- Windfury, Flametongue, Frostbrand, Rockbiter: weapon enchants, not buffs.
        -- Shamans can't dual-wield on Forever, so main hand only.
        { key = "imbueMainHand", kind = "weapon", slot = "MainHand", label = "Weapon imbue", cast = { 8232, 8024, 8033, 8017 }, default = true },
        { key = "lightningShield", buffs = { 324 }, cast = { 324 }, selfCast = true, duration = 600, default = false },
    },
    ROGUE = {
        -- the poison recipes (Instant, Deadly, Wound, Crippling, Mind-numbing): knowing one
        -- means you use poisons; the icon is the poison
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
    {
        -- from sitting at a campfire; the bonuses of the camp objects come with it
        key = "campBenefits", buffs = { 1229741 }, needsSpell = false, default = false,
        desc = "Reminds you while you don't have the Camp Benefits buff from sitting at a campfire.",
    },
    {
        -- the tracking spells come from the minimap tracking menu, see FB:RefreshTracking
        key = "tracking", kind = "tracking", label = "Tracking (any)", noUsable = true, default = false,
        desc = "Reminds you while no minimap tracking is on: Find Herbs, Find Minerals, Find Treasure, "
            .. "Sense Undead, Sense Demons, the hunter tracks... Only one can be on at a time, so any of them counts. "
            .. "Only shown if you know a tracking spell.",
    },
}

-- Buffs that don't stack with each other. A reminder (built-in or custom) for one of them
-- counts the others as buffed too, can be turned off per reminder.
--   byName  class buffs, matched by name like the trackers: every rank counts
--   byID    matched by spell ID only, several share a name ("Boosted Stats"). Also found
--           when the game hides them from the buff bar (the camp buffs are hidden)
-- Sources:
-- - Forever camp objects give buffs that the game calls "mutually exclusive" with one class
--   buff each. Kings, Might and Wisdom have camp counterparts too; the paladin's blessing
--   reminder lists them in its kinds instead.
-- - Scrolls never stacked with the class buff of the same stat; the stronger one wins.
-- - Intellect elixirs: reported not to stack with Arcane Intellect. Only the pure Intellect
--   ones, not Owl, Cunning or Sages.
-- - Not here: the Blood Shard buffs from Mangletooth (Wisdom of Agamaggan 7764, Rising
--   Spirit 10767) stack with class buffs.
ns.EXCLUSIVE_GROUPS = {
    {
        byName = { 1459, 23028 },           -- Arcane Intellect, Arcane Brilliance
        byID = {
            1229513,                        -- Boosted Intellect (camp: Incense Candle)
            8096, 8097, 8098, 12176,        -- Scroll of Intellect I-IV
            3166, 11396,                    -- Elixir of Wisdom, Elixir of Greater Intellect
            1250988, 1250989,               -- Elixir of Lesser Intellect, Elixir of Intellect (Forever)
        },
    },
    {
        byName = { 1243, 21562 },           -- Power Word: Fortitude, Prayer of Fortitude
        byID = {
            1230124,                        -- Boosted Stamina (camp: First Aid Kit)
            8099, 8100, 8101, 12178,        -- Scroll of Stamina I-IV
        },
    },
    {
        byName = { 14752, 27681 },          -- Divine Spirit, Prayer of Spirit
        byID = {
            1229718,                        -- Boosted Spirit (camp: Faction Banner)
            8112, 8113, 8114, 12177,        -- Scroll of Spirit I-IV
        },
    },
    {
        byName = { 1126, 21849 },           -- Mark of the Wild, Gift of the Wild
        byID = { 1230653 },                 -- Boosted Stats (camp: Enchanted Lute), not the Fish Bowl one
    },
}

-- Training level of every rank of the buffs that others can cast on you, to tell a weaker
-- rank from yours: someone else's buff of a lower level than the strongest one you know
-- doesn't count, since yours would replace it. The same level means the same strength, also
-- for the group versions (Forever tooltips: Blessing of Might rank 6 = Greater Blessing of
-- Might rank 1 = 112 attack power at level 52). Spells with one rank (Kings, Concentration,
-- Sanctity, Pack) are always equally strong and aren't listed. Levels from the Forever
-- trainer data (WhatsTraining) and forever.warcraftdb.com.
ns.RANKS = {
    -- Power Word: Fortitude, Prayer of Fortitude
    [1243] = 1, [1244] = 12, [1245] = 24, [2791] = 36, [10937] = 48, [10938] = 60,
    [21562] = 48, [21564] = 60,
    -- Divine Spirit, Prayer of Spirit
    [14752] = 30, [14818] = 40, [14819] = 50, [27841] = 60, [27681] = 60,
    -- Shadow Protection, Prayer of Shadow Protection
    [976] = 30, [10957] = 42, [10958] = 56, [27683] = 56,
    -- Arcane Intellect, Arcane Brilliance
    [1459] = 1, [1460] = 14, [1461] = 28, [10156] = 42, [10157] = 56, [23028] = 56,
    -- Mark of the Wild, Gift of the Wild
    [1126] = 1, [5232] = 10, [6756] = 20, [5234] = 30, [8907] = 40, [9884] = 50, [9885] = 60,
    [21849] = 50, [21850] = 60,
    -- Thorns
    [467] = 6, [782] = 14, [1075] = 24, [8914] = 34, [9756] = 44, [9910] = 54,
    -- Battle Shout
    [6673] = 1, [5242] = 12, [6192] = 22, [11549] = 32, [11550] = 42, [11551] = 52, [25289] = 60,
    -- Blessing of Might, Greater Blessing of Might
    [19740] = 4, [19834] = 12, [19835] = 22, [19836] = 32, [19837] = 42, [19838] = 52, [25291] = 60,
    [25782] = 52, [25916] = 60,
    -- Blessing of Wisdom, Greater Blessing of Wisdom
    [19742] = 14, [19850] = 24, [19852] = 34, [19853] = 44, [19854] = 54, [25290] = 60,
    [25894] = 54, [25918] = 60,
    -- Devotion Aura
    [465] = 1, [10290] = 10, [643] = 20, [10291] = 30, [1032] = 40, [10292] = 50, [10293] = 60,
    -- Retribution Aura
    [7294] = 16, [10298] = 26, [10299] = 36, [10300] = 46, [10301] = 56,
    -- Shadow, Frost, Fire Resistance Aura
    [19876] = 28, [19895] = 40, [19896] = 52,
    [19888] = 32, [19897] = 44, [19898] = 56,
    [19891] = 36, [19899] = 48, [19900] = 60,
    -- Aspect of the Wild
    [20043] = 46, [20190] = 56,
    -- Trueshot Aura (ranks 1 and 2 are Forever IDs)
    [1299346] = 25, [1299348] = 32, [19506] = 40, [20905] = 50, [20906] = 60,
}
