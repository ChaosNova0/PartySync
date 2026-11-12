# PartySync

**Your party's quests in one list, for WoW: Forever.**

![Version](https://img.shields.io/badge/version-0.1.2-c9a26b) ![Client](https://img.shields.io/badge/client-WoW%3A%20Forever-555) ![Status](https://img.shields.io/badge/status-testing-orange)

PartySync shows what everyone in your party is working on. You can see who still needs mobs or items, which quests your friends have that you don't, and what's ready to hand in. Everyone who wants to show up in the list needs PartySync installed.

- **[Installation](#installation)** · **[Commands](#commands)** · **[Known limitations](#known-limitations)**

---

## What's in it

- **You're missing**: quests your party members have that you don't.
  - **Ask to share** sends them a request. They get a small popup with a **Share** button, and you're told whether they shared it.
  - **How to get it** appears when a quest can't be shared to you yet. It explains why, for example "You need to be level 30" or "You need the earlier quests in this chain first".
- **Quest chains** (needs [QuestieDB](https://www.curseforge.com/wow/addons/questiedb)): the "How to get it" panel lists the whole chain.
  - Steps you've done are ticked.
  - The step to start from shows who gives it and where.
  - You can see which friend is on which step.
  - **Show on map** places a map pin, and **Track next step** pins the next step under PartySync's title until you pick it up.
  - Without QuestieDB, everything else still works. You just get a short reason instead of the chain.
- **In progress**: every quest you share with someone, with each person's objective counts and a progress bar. Finished rows turn green, and you can fold up quests you don't need to see.
- **Ready to turn in**: quests the whole group has finished.
- **Everyone's done alert**: a message in the middle of the screen, with an optional sound, when the last person finishes a quest.
- **Zone filter**: shows quests for the zone you're in, or for all zones.
- **Party strip**: everyone in your group in class colours. A faded name means that person doesn't have PartySync, so their quests can't be shown.

PartySync works in parties of up to 5. In a raid it pauses, because quest sharing works by party.

---

## Installation

1. Get the latest `PartySync-x.y.z.zip` from whoever shared it with you.
2. Close the game.
3. Unzip it so the folder sits at
   `World of Warcraft\_forever_\Interface\AddOns\PartySync\PartySync.toc`
   (replace any older `PartySync` folder).
4. *Optional, for quest chains:* install **QuestieDB** the same way.
5. Start the game. On the character screen, open **AddOns** and make sure **PartySync** is ticked. If it's listed as out of date, tick **Load out of date AddOns**.
6. Join a party with friends who also have PartySync. The window opens by itself; after that, type **`/psync`** or click the PartySync button on the minimap.

Drag the title bar to move the window. Press Escape or click ✕ to close it. Once you close it, it stays closed until you next join a party (or log in). Drag the minimap button to move it around the minimap's edge, and right-click it for the settings.

---

## Commands

| Command | Does |
|---|---|
| `/psync` | Open or close the window |
| `/psync status` | Who's in your party, who has PartySync, when you last heard from them, and your own quests |
| `/psync sync` | Ask everyone to send their quests again (once every 30 seconds) |
| `/psync questie` | Whether QuestieDB was found and is working |
| `/psync reset` | Put the window back at the top of the screen |
| `/psync minimap` | Hide or show the minimap button |
| `/psync debug` | Extra chat lines that help when reporting a problem (until you log out) |

`/partysync` works as well. The gear button in the window has the settings:
- the alert and its sound
- whether others can send you share requests
- whether to show quests only you have
- whether to hide quests for other classes and races
- whether the window opens by itself when you're in a party
- whether to show the minimap button

---

## Known limitations

- **Everyone needs PartySync.** The game doesn't let an addon see another player's quest log, so each person's PartySync sends theirs to the group.
- **Sharing follows the game's rules.** A quest can only be shared to someone who could pick it up themselves: the right level, earlier quests done, not already finished. "How to get it" tells you which rule is in the way.
- **Quest chain data comes from QuestieDB.** It's still being filled in for Forever, so some chains may be incomplete, and some quests may say "Questie doesn't know this quest yet".
- **Reporting problems:** `/psync status` and `/psync questie` show what PartySync sees. A screenshot of any Lua error (BugSack makes these easy to copy) helps most.
- `## Interface: 16001` matches the Forever client.

---

## Credits

- **Questrial** by Joe Prince and Laura Meseguer, © 2011 The Questrial Project Authors, SIL Open Font License 1.1 (`Media/Fonts/Questrial-OFL.txt`), included unmodified
- Quest chains come from **[QuestieDB](https://www.curseforge.com/wow/addons/questiedb)** when it's installed. PartySync reads it while the game is running and doesn't include any of its data.

---

## Licence

PartySync is released under the [MIT License](LICENSE). The Questrial font keeps its own licence, the SIL Open Font License 1.1.
