# PartySync 0.1.1

A fix for the zone filter.

### Fixed
- **Quests now show in the zone you do them in.** The quest log puts some quests under the city that gave them. Un'Goro Soil, for example, sits under "Thunder Bluff", so it didn't show while you were in Un'Goro Crater. With **QuestieDB** installed, a quest now also shows in the zones where its mobs, objects, item drops and explore spots are, and those zones appear in the zone dropdown. It still shows under its quest log heading as before.

### Good to know
- This needs QuestieDB. Without it, quests go by their quest log heading, the same as 0.1.0.
- Items that drop all over the world (cloth, for example) don't count for any zone, so those quests won't pop up in random places.
- With a big party, a few quests may take a second or two to appear after the window first opens, while PartySync works out their zones.

### Install
1. Close the game.
2. Unzip so that `Interface\AddOns\PartySync\PartySync.toc` exists, replacing the old folder.
3. Your settings are kept.
