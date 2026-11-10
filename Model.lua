-- Model: turns our quest log and the party's into what the panel shows.
-- No drawing here: Model.Build() returns a plain table and the panel draws it.
-- It also watches for quests that become ready for everyone (the done alert).
--
-- Model.Build() returns (every list is in the order to show it):
--   {
--     state   = "party" | "solo" | "raid",
--     message = nil, or the line to show instead of the sections
--               (solo: "You're not in a party...", raid: "PartySync works in parties...")
--     playerLevel = 8,
--     zone = {
--       filter  = "current" | "all" | a zone name   (settings.zoneFilter)
--       current = "Elwynn Forest"                   (GetRealZoneText, "" if unknown)
--       label   = what the dropdown shows: the current zone, "All zones" or the name
--       choices = { { value = "current", label = "Current zone (Elwynn Forest)" },
--                   { value = "all", label = "All zones" },
--                   { value = "Westfall", label = "Westfall" }, ... }   -- every zone in MY quest log
--     },
--     sharedCount = 5,   -- quests in the filter that 2 or more PartySync people have
--     party = { { guid, name, class, isMe, hasAddon (true/false/nil), offline,
--                 versionNote = nil or "has PartySync 0.2.0 (you have 0.1.0)" }, ... }  -- you first
--     missing = { {
--         id, title, level, color = "yellow", zone,
--         holders = { { guid, name, class, pushable }, ... },  holderNames = "Carol Stone, Bob",
--         canAsk = true,         -- one of them can share it
--         askTarget = guid,      -- who "Ask to share" goes to (the first holder who can share it)
--         askable = true,        -- canAsk, and nothing else stands in the way (why.rule == 7):
--                                -- show "Ask to share"; otherwise "How to get it"
--         why = { rule = 2..7, text = nil or the reason, hint = nil or "Ask Bob where it started.",
--                 gold = nil or the part of text shown in gold, chain = nil or Chain.Build's result,
--                 needsDB = true }  -- needsDB: show "Install QuestieDB..." (see Chain.WhyNot)
--       }, ... },    (quests Chain.WhyNot says to hide, e.g. for another class, aren't listed)
--     progress = { {
--         id, title, level, color, zone, solo (only you have it), collapsed (folded in the panel),
--         left = 1,              -- holders who aren't done yet
--         holders = { { guid, name, class, isMe, complete,
--                       objectives = { { label = "Kobold Vermin", have = 7, need = 10, done = false }, ... } },
--                     ... },     -- you first, then by name
--       }, ... },
--     ready = { { id, title, level, color, zone, names = { "Alice", ... }, namesText = "Alice, Bob" }, ... },
--     counts = { missing = 2, progress = 3, ready = 1 },
--     synced = 2,    -- whole seconds since we last heard any party member, or nil
--     alertDone = true,
--   }
-- Text in the table comes from other players: it has no "|" (Wire.lua took
-- it out), but the panel should still pass it through ns.Escape for chat.
--
-- Callback bus event fired here:
--   "ALL_DONE" (questID, title)   a quest just became ready for everyone

local _, ns = ...
local Model = {}
ns.Model = Model
local G = ns.Group

------------------------------------------------------------------------
-- Level colours (Classic rules)
------------------------------------------------------------------------
Model.LEVEL_RGB = {
  red = { 1, 0.1, 0.1 }, orange = { 1, 0.5, 0.25 }, yellow = { 1, 1, 0 },
  green = { 0.25, 0.75, 0.25 }, grey = { 0.5, 0.5, 0.5 },
}

-- the highest quest level that's grey (no XP) for a player of this level
function Model.GreyLevel(playerLevel)
  if playerLevel <= 5 then return 0 end
  if playerLevel <= 39 then return playerLevel - 5 - math.floor(playerLevel / 10) end
  if playerLevel <= 59 then return playerLevel - 1 - math.floor(playerLevel / 5) end
  return playerLevel - 9
end

-- A quest level's colour name compared with the player's level: 5 or more
-- above is red, 3-4 above orange, 2 below to 2 above yellow, then green, and
-- grey when it gives no XP. Level 0 (not known) counts as yellow.
function Model.LevelColor(questLevel, playerLevel)
  if type(questLevel) ~= "number" or questLevel <= 0 or type(playerLevel) ~= "number" then return "yellow" end
  local diff = questLevel - playerLevel
  if diff >= 5 then return "red" end
  if diff >= 3 then return "orange" end
  if diff >= -2 then return "yellow" end
  if questLevel > Model.GreyLevel(playerLevel) then return "green" end
  return "grey"
end

------------------------------------------------------------------------
-- "Why can't I get it?" Chain.lua (loaded before this file) has the full
-- rules, with the quest database. This two-rule version is what's used if
-- Chain.WhyNot ever fails.
------------------------------------------------------------------------
-- quest: the holder's copy, holders: { { name, pushable }, ... }, canAsk
-- Returns { rule, text, hint, needsDB }. Rule 1 (already done) never gets
-- here: those quests aren't listed. Rule 7 means "Ask to share" is the way.
function Model.BasicWhyNot(quest, holders, canAsk)
  local needsDB = not (ns.QDB and ns.QDB.state == "ready")
  local first = holders[1] and holders[1].name or "them"
  if not canAsk then
    return { rule = 2, text = "This quest can't be shared, so you'll need to pick it up yourself.",
             hint = needsDB and ("Ask " .. first .. " where it started.") or nil, needsDB = needsDB }
  end
  return { rule = 7, needsDB = needsDB }
end
Model.WhyNot = (ns.Chain and ns.Chain.WhyNot) or Model.BasicWhyNot

-- Model.WhyNot under pcall: an error falls back to the two-rule version
local function WhyNot(quest, holders, canAsk)
  local ok, why = pcall(Model.WhyNot, quest, holders, canAsk)
  if ok and type(why) == "table" then return why end
  if not ok then ns.ReportError("why not: " .. tostring(why)) end
  return Model.BasicWhyNot(quest, holders, canAsk)
end

------------------------------------------------------------------------
-- Gathering everyone's quests
------------------------------------------------------------------------
local function PlayerLevel()
  local lvl = UnitLevel and UnitLevel("player")
  if type(lvl) ~= "number" or ns.IsSecret(lvl) then return 1 end
  return lvl
end

-- false only when the game says the member is offline
local function Offline(m)
  if not (m.unit and UnitIsConnected) then return false end
  local on = UnitIsConnected(m.unit)
  if ns.IsSecret(on) then return false end
  return on == false
end

local function VersionNote(m)
  if m.hasAddon ~= true then return nil end
  if m.proto and m.proto ~= ns.Wire.PROTO then
    return "has a PartySync that can't talk to yours" .. (m.version and (" (" .. m.version .. ")") or "")
  end
  if m.version and m.version ~= ns.VERSION then
    return "has PartySync " .. m.version .. " (you have " .. ns.VERSION .. ")"
  end
  return nil
end

local function ByName(a, b)
  if a.name ~= b.name then return (a.name or "") < (b.name or "") end
  return (a.guid or "") < (b.guid or "")
end

local function ByLevelTitle(a, b)
  if a.level ~= b.level then return a.level < b.level end
  if a.title ~= b.title then return a.title < b.title end
  return a.id < b.id
end

-- every quest anyone with PartySync has:
--   [id] = { id, mine = our copy or nil, others = { { member, quest }, ... } (by name) }
local function Gather()
  local all = {}
  for id, q in pairs(ns.mine.quests) do all[id] = { id = id, mine = q, others = {} } end
  for _, m in ipairs(G.SortedMembers()) do
    if m.hasAddon == true then
      for id, q in pairs(m.quests) do
        local e = all[id]
        if not e then e = { id = id, others = {} } all[id] = e end
        e.others[#e.others + 1] = { member = m, quest = q }
      end
    end
  end
  return all
end

-- the shown copy of a quest (ours if we have it) and its zone
local function Main(e) return e.mine or (e.others[1] and e.others[1].quest) end

-- is this quest ready for everyone? (2+ holders, every one complete)
local function IsReady(e)
  if not e.mine or not e.mine.complete or #e.others == 0 then return false end
  for _, o in ipairs(e.others) do
    if not o.quest.complete then return false end
  end
  return true
end

local function Objectives(q, id)
  local out = {}
  for i, o in ipairs(q.obj or {}) do
    out[i] = { label = ns.QuestLog.ObjectiveLabel(id, i), have = o.have, need = o.need, done = o.have >= o.need }
  end
  return out
end

local function HolderRow(guid, name, class, isMe, q, id)
  return { guid = guid, name = name, class = class, isMe = isMe, complete = q.complete and true or false,
           objectives = Objectives(q, id) }
end

------------------------------------------------------------------------
-- Build
------------------------------------------------------------------------
local SOLO_TEXT = "You're not in a party. PartySync works in parties: join one to see everyone's quests."
local RAID_TEXT = "PartySync works in parties. It's paused while you're in a raid."

function Model.Build()
  local settings = (ns.db and ns.db.settings) or ns.DEFAULTS.settings
  local mode = G.Mode()
  local level = PlayerLevel()
  local out = {
    state = mode, playerLevel = level, sharedCount = 0, party = {},
    missing = {}, progress = {}, ready = {}, counts = { missing = 0, progress = 0, ready = 0 },
    alertDone = settings.alertDone and true or false,
  }
  if mode == "solo" then out.message = SOLO_TEXT elseif mode == "raid" then out.message = RAID_TEXT end

  -- the party strip: you first
  local me = ns.mine
  out.party[1] = { guid = me.guid, name = me.name or "You", class = me.class, isMe = true,
                   hasAddon = true, offline = false }
  local members = G.SortedMembers()
  local lastHeard
  for _, m in ipairs(members) do
    out.party[#out.party + 1] = { guid = m.guid, name = m.name, class = m.class, isMe = false,
                                  hasAddon = m.hasAddon, offline = Offline(m), versionNote = VersionNote(m) }
    if m.lastHeard and (not lastHeard or m.lastHeard > lastHeard) then lastHeard = m.lastHeard end
  end
  if lastHeard then out.synced = math.max(0, math.floor(GetTime() - lastHeard)) end

  -- the zone filter
  local current = ns.CurrentZone()
  local filter = settings.zoneFilter
  local all = (mode == "party") and Gather() or {}
  -- (the choices are the zones in MY quest log only, so the saved filter is
  -- never a name another player sent)
  local zones, zoneList = {}, {}
  for _, q in pairs(me.quests) do
    local z = q.zone
    if z ~= "" and not zones[z] then zones[z] = true zoneList[#zoneList + 1] = z end
  end
  if filter ~= "current" and filter ~= "all" and not zones[filter] then zoneList[#zoneList + 1] = filter end
  table.sort(zoneList)
  local choices = {
    { value = "current", label = "Current zone (" .. (current ~= "" and current or "unknown") .. ")" },
    { value = "all", label = "All zones" },
  }
  for _, z in ipairs(zoneList) do choices[#choices + 1] = { value = z, label = z } end
  local want -- the zone shown, or nil for every zone
  if filter == "current" then want = current ~= "" and current or nil
  elseif filter ~= "all" then want = filter end
  out.zone = { filter = filter, current = current, choices = choices,
               label = filter == "current" and (current ~= "" and current or "Current zone")
                 or (filter == "all" and "All zones" or filter) }

  local myName = me.name or "You"
  for id, e in pairs(all) do
    local main = Main(e)
    if not want or main.zone == want then
      if (e.mine and 1 or 0) + #e.others >= 2 then out.sharedCount = out.sharedCount + 1 end
      local base = { id = id, title = main.title, level = main.level,
                     color = Model.LevelColor(main.level, level), zone = main.zone }

      if not e.mine then
        -- you're missing it (unless you've handed it in before)
        if ns.QuestLog.IsDone(id) ~= true then
          local holders, names, askTarget = {}, {}, nil
          for i, o in ipairs(e.others) do
            holders[i] = { guid = o.member.guid, name = o.member.name, class = o.member.class,
                           pushable = o.quest.pushable and true or false }
            names[i] = o.member.name
            if o.quest.pushable and not askTarget then askTarget = o.member.guid end
          end
          base.holders, base.holderNames = holders, table.concat(names, ", ")
          base.canAsk, base.askTarget = askTarget ~= nil, askTarget
          base.why = WhyNot(main, holders, base.canAsk)
          base.askable = base.canAsk and base.why.rule == 7
          if not base.why.hide then out.missing[#out.missing + 1] = base end
        end

      elseif IsReady(e) then
        local names = { myName }
        for _, o in ipairs(e.others) do names[#names + 1] = o.member.name end
        base.names, base.namesText = names, table.concat(names, ", ")
        out.ready[#out.ready + 1] = base

      elseif #e.others > 0 or settings.showSolo then
        local holders = { HolderRow(me.guid, myName, me.class, true, e.mine, id) }
        for _, o in ipairs(e.others) do
          holders[#holders + 1] = HolderRow(o.member.guid, o.member.name, o.member.class, false, o.quest, id)
        end
        local left = 0
        for _, h in ipairs(holders) do if not h.complete then left = left + 1 end end
        base.holders, base.left, base.solo = holders, left, #e.others == 0
        base.collapsed = (ns.db and ns.db.collapsed.quests[id]) and true or false
        out.progress[#out.progress + 1] = base
      end
    end
  end
  table.sort(out.missing, ByLevelTitle)
  table.sort(out.progress, ByLevelTitle)
  table.sort(out.ready, ByLevelTitle)
  out.counts.missing, out.counts.progress, out.counts.ready = #out.missing, #out.progress, #out.ready
  return out
end

------------------------------------------------------------------------
-- The done alert: a quest that *moves* into ready, only with alertDone on.
--   - Only what we know for sure counts: while any online party member with
--     PartySync isn't synced yet (we haven't had their list, or what we hold
--     doesn't match its checksum), nothing alerts and the last sure answer
--     is kept. Otherwise a quest could look ready because a slower member's
--     copy of it simply hadn't arrived.
--   - Muted after logging in, /reload or a party change, so what was already
--     ready doesn't go off: for at least 10 s, and then until everyone is
--     synced (at most 60 s). What's ready when the mute ends is the start.
--   - Once per quest while it stays ready; leaving ready allows it again.
-- It always prints a line in chat; Model.ShowAlert adds the big text in the
-- middle of the screen (the raid warning spot) and the ready-check sound.
------------------------------------------------------------------------
Model.MUTE = 10
Model.MUTE_MAX = 60
local wasReady       -- [questID] = true: ready at the last sure check (nil: none yet)
local alerted = {}   -- [questID] = true: alerted, and still ready since
local muteStart = -math.huge

-- are we sure we have this member's quests as they are now?
local function Synced(m)
  return m.listSum ~= nil and ns.Wire.Checksum(m.quests) == m.listSum
end

-- Could a member we've never heard from still turn out to have PartySync?
-- Only for MUTE_MAX seconds after the mute started or after they joined,
-- so one silent member can't hold the alert back for longer than that.
local function MayStillAnswer(m, now)
  if now < muteStart + Model.MUTE_MAX then return true end
  local joined = ns.Comm and ns.Comm.JoinedAt and ns.Comm.JoinedAt(m.guid)
  return joined ~= nil and now < joined + Model.MUTE_MAX
end

-- is every online party member who has (or may have) PartySync synced?
-- (members known to be without it, or on a protocol we can't read, don't
-- count, and nor do silent ones once MayStillAnswer runs out)
function Model.AllSynced()
  local now = GetTime()
  for _, m in pairs(ns.members) do
    if m.hasAddon ~= false and (m.proto == nil or m.proto == ns.Wire.PROTO)
      and not Offline(m) and not Synced(m)
      and (m.hasAddon == true or MayStillAnswer(m, now)) then
      return false
    end
  end
  return true
end

-- the IDs that are ready for everyone right now (every zone)
function Model.ReadyIDs()
  local ids = {}
  if G.Mode() ~= "party" then return ids end
  for id, e in pairs(Gather()) do
    if IsReady(e) then ids[id] = true end
  end
  return ids
end

function Model.CheckAlert()
  local now = GetTime()
  local ready = Model.ReadyIDs()
  local synced = Model.AllSynced()
  local muted = now < muteStart + Model.MUTE or (not synced and now < muteStart + Model.MUTE_MAX)
  if not synced then
    -- (not sure yet: keep the last sure answer. If the mute ran out before
    -- anyone was sure, what we have now becomes the start.)
    if not muted and not wasReady then wasReady = ready end
    return
  end
  for id in pairs(alerted) do
    if not ready[id] then alerted[id] = nil end
  end
  if muted or not wasReady then
    wasReady = ready
    return
  end
  local on = ns.db and ns.db.settings.alertDone
  for id in pairs(ready) do
    if not wasReady[id] and not alerted[id] and on then
      alerted[id] = true
      local q = ns.mine.quests[id]
      local title = q and q.title or ("quest " .. id)
      ns.Print(("Everyone's done with %s. Time to hand it in!"):format(ns.Escape(title)))
      ns.Fire("ALL_DONE", id, title)
    end
  end
  wasReady = ready
end

local function Mute()
  muteStart = GetTime()
  wasReady = nil
end

-- The big text and the sound. Both game functions are checked first and
-- run under pcall: if the raid warning isn't there, the chat line is it.
function Model.ShowAlert(questID, title)
  local text = ("Everyone's done with %s!"):format(ns.Escape(title or ("quest " .. tostring(questID))))
  if type(RaidNotice_AddMessage) == "function" and RaidWarningFrame then
    local colour = ChatTypeInfo and ChatTypeInfo.RAID_WARNING
    if type(colour) ~= "table" then colour = { r = 1, g = 0.82, b = 0 } end
    local ok, err = pcall(RaidNotice_AddMessage, RaidWarningFrame, text, colour)
    if not ok then ns.Debug("raid warning: " .. tostring(err)) end
  end
  local settings = ns.db and ns.db.settings
  if settings and settings.alertSound and type(PlaySound) == "function"
    and type(SOUNDKIT) == "table" and SOUNDKIT.READY_CHECK then
    local ok, err = pcall(PlaySound, SOUNDKIT.READY_CHECK, "Master")
    if not ok then ns.Debug("alert sound: " .. tostring(err)) end
  end
end

ns.On("ALL_DONE", Model.ShowAlert)
ns.On("CHANGED", function() ns.Coalesce("alert", 0.2, Model.CheckAlert) end)
ns.On("ROSTER_CHANGED", Mute)
ns.RegisterEvent("PLAYER_LOGIN", Mute)
