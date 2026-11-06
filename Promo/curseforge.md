**Buff Reminder** puts an icon on your screen when one of your buffs is missing or about to run out. No raid checklists, no huge config. Just the icon, where you want it.

I made this for WoW Forever because WeakAuras isn't available there, and I really missed my old Battle Shout reminder. The other reminder addons I tried check your buffs before the pull and then go blind once combat starts. Shout in the middle of a fight and they never notice. This one does.

### What it tracks out of the box

- **Warrior:** Battle Shout
- **Mage:** Arcane Intellect, your armor
- **Priest:** Fortitude, Inner Fire, Divine Spirit, Touch of Weakness / Shadowguard (Shadow Protection is there too, off by default)
- **Druid:** Mark of the Wild (Thorns off by default)
- **Paladin:** a blessing, an aura, and your seal while in combat (Righteous Fury off by default)
- **Hunter:** an aspect, Trueshot Aura
- **Warlock:** Demon Armor / Demon Skin
- **Shaman:** weapon imbue (Lightning Shield off by default)
- **Rogue:** poisons on both weapons
- **Everyone:** sharpening stones, weightstones and oils. Off by default, turn it on if you use them.

You only get reminded about spells you actually know, so a fresh level 1 priest won't get yelled at about Divine Spirit.

### Add your own

Any buff can be added by spell ID or by name: flasks, elixirs, food, the Mark of the Wild your druid keeps forgetting. Type `/br buffs` and it lists everything you have on right now with the IDs, so you don't have to dig through Wowhead.

### What happens in combat

Forever hides buff data from addons while you're fighting. Buff Reminder works around that as far as it can:

- timers keep counting down, so a buff that runs out mid-fight still pops up
- buffs you put on yourself (Battle Shout, seals, Inner Fire...) are picked up right away
- weapon enchants are always tracked live
- Judgement eats your seal, and the addon knows that

What it can't see: buffs somebody else puts on you during a fight, or buffs that get dispelled. Those fix themselves as soon as combat ends. Right-clicking a buff away mid-fight usually isn't noticed either. If you need that, use a `/cancelaura` macro, that one always works.

### Settings

`/br` opens the options. `/br unlock` lets you drag the icons around, `/br lock` when you're done.

You can change the icon size and direction, set the warning time (for everything or per buff), show reminders only in or out of combat, hide them while resting or mounted, and pick what happens when you're out of mana or rage: show the icon, grey it out, or hide it.

Found a bug, or a spell that's missing? Leave a comment. Forever changed a lot of spells and I don't play every class.
