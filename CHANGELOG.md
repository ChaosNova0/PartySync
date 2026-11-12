# PartySync 0.1.2

Fixes from a full review, mostly to make party sync more forgiving.

### Fixed
- **Party members are recognised more reliably.** If the game spells someone's name differently from what PartySync expects (for example just the first name, different capital letters, or a realm spelled another way), PartySync now still works out who it is, as long as nobody else in the party shares that first name.
- **"(offline)" shows straight away** when a party member logs out, and goes away when they come back.
- **The "Everyone's done" alert can't be spammed.** Each quest alerts at most once a minute, and the big centre text and sound play at most once every 10 seconds (you still get a chat line for every quest).
- **One out-of-sync party member can't hold the alert back forever.** After two minutes they're left out of the check.
- **The minimap icon and font work even if the addon's folder has another name** (for example after installing from a GitHub download).

### New
- **`/psync debug`** turns on extra chat lines until you log out. They help when reporting a problem, especially if party members can't see each other's quests.

### Install
1. Close the game.
2. Unzip so that `Interface\AddOns\PartySync\PartySync.toc` exists, replacing the old folder.
3. Your settings are kept.
