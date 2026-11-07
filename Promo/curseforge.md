**Forever Buffed** puts an icon on your screen when one of your buffs is missing or about to run out. No raid checklists, no huge config. Just the icon, where you want it.

I made this for WoW Forever because WeakAuras isn't available there, and I really missed my old Battle Shout reminder. The other reminder addons I tried check your buffs before the pull and then go blind once combat starts. Shout in the middle of a fight and they never notice. This one does.

### What it tracks out of the box

- **Warrior:** Battle Shout
- **Mage:** Arcane Intellect, your armor
- **Priest:** Fortitude, Inner Fire, Divine Spirit, Touch of Weakness / Shadowguard (Shadow Protection is there too, off by default)
- **Druid:** Mark of the Wild (Thorns off by default)
- **Paladin:** Your blessing, your aura, and your seal while in combat (Righteous Fury off by default)
- **Hunter:** Aspects, Trueshot Aura
- **Warlock:** Demon Armor / Demon Skin
- **Shaman:** Weapon imbue (Lightning Shield off by default)
- **Rogue:** Poisons on both weapons
- **Everyone:** Sharpening stones, weightstones and oils, the Camp Benefits buff from a campfire, and minimap tracking (Find Herbs, Find Minerals, Sense Undead, hunter tracks… any of them counts, since only one can be on). Off by default, turn on what you use.

Some buffs don't stack with a class buff: camp object buffs, scrolls and Intellect elixirs. Those count both ways: with Boosted Intellect from an Incense Candle you won't be told to cast Arcane Intellect, and a reminder for your Intellect elixir is happy when a mage's Arcane Intellect replaced it. You can turn that off per reminder.

You only get reminded about spells you actually know, so a fresh level 1 priest won't get yelled at about Divine Spirit.

### Add your own

Any buff can be added by spell ID or by name: flasks, elixirs, food, the Mark of the Wild your druid keeps forgetting. Type `/fb buffs` and it lists everything you have on right now with the IDs, so you don't have to dig through Wowhead.

### What happens in combat

Forever hides buff data from addons while you're fighting. Forever Buffed works around that as far as it can:

- timers keep counting down, so a buff that runs out mid-fight still pops up
- buffs you put on yourself (Battle Shout, seals, Inner Fire…) are picked up right away
- weapon enchants are always tracked live

What it can't see: buffs somebody else puts on you during a fight, buffs that get dispelled, or Lightning Shield running out of charges. Those fix themselves as soon as combat ends. Right-clicking a buff away mid-fight usually isn't noticed either. If you need that, use a `/cancelaura` macro, that one always works.

### Settings

`/fb` opens the options. `/fb unlock` lets you drag the icons around, `/fb lock` when you're done.

You can change the icon size and direction (or keep the bar centered), type in the exact position, set the warning time (for everything or per buff), show reminders only in or out of combat, hide them while resting or mounted, and pick what happens when you're out of mana or rage: show the icon, grey it out, or hide it. Each reminder can glow when it's missing, or already while it's running out.

Found a bug, or a spell that's missing? Leave a comment. Forever changed a lot of spells and I don't play every class.
