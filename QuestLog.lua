-- QuestLog: reads our own quest log into ns.mine, works out what changed
-- since the last look, and keeps our own objective text for the panel.
--
--   ns.mine.quests[id] = quest (shape: see Wire.lua), with the same limits as
--     a sent quest (title 60 bytes, zone 40, 8 objectives, counts 0-9999),
--     plus obj[i].text: our own objective text with the count taken off
--     ("Kobold Vermin slain"), or nil when the game gives none. Never sent.
--     The zone is the quest log header the quest sits under ("Other quests",
--     W.NO_ZONE, when that header is blank).
--     (the table is replaced on every scan that sees a change)
--   ns.mine.list    = the quest IDs, lowest first (at most 40), of the quests
--                     that can be sent (see SendableIDs)
--   ns.mine.listSum = Wire.Checksum of ns.mine.quests (what our L message carries)
--   QL.available    = false when this client has no C_QuestLog to read
--
-- After a scan, "MINE_CHANGED" fires with (dirty, removed): the IDs of quests
-- that are new or changed in what we send, and the IDs that are gone. Comm.lua
-- sends the dirty quests, then the list. Changes only to our own objective
-- text fire just "CHANGED" (the panel redraws; nothing needs sending).
--
-- The quest log API used here (C_QuestLog.GetNumQuestLogEntries, GetInfo,
-- GetQuestObjectives, IsComplete, IsPushableQuest, IsQuestFlaggedCompleted) is
-- only confirmed for Forever on the wiki, so every function is checked before
-- use, and a scan that fails part way changes nothing.

local _, ns = ...
local QL = {}
ns.QuestLog = QL
local W = ns.Wire

QL.available = nil -- nil until the first scan, then true / false
QL.MAX_ENTRIES = 250 -- the most log lines (headers + quests) we ever read
QL.MAX_TEXT = 120 -- bytes of our own objective text kept

-- Takes the count off an objective so we can show someone else's count with it.
-- Forever puts the count at the front: "0/3 Screecher Spirits collected" -> "Screecher Spirits collected"
-- (checked in game, 2026-11-10). Older clients put it at the end: "Kobold Vermin slain: 3/8".
-- We handle both. A count in the middle of the text is left alone.
-- (plain spaces and tabs, not "%s": that follows the language setting and
-- could take the last byte of an accented letter with it)
local COUNT_FRONT = "^[ \t]*%d+[ \t]*/[ \t]*%d+[ \t]*"
local COUNT_END = ":[ \t]*%d+[ \t]*/[ \t]*%d+[ \t]*$"
function QL.StripCount(text)
  if type(text) ~= "string" or ns.IsSecret(text) then return nil end
  text = text:gsub(COUNT_FRONT, ""):gsub(COUNT_END, "")
  text = W.CleanLocal(text, QL.MAX_TEXT)
  if not text or text == "" then return nil end
  return text
end

-- a count from the game, made a whole number in 0 .. 9999 (nil if not a number)
local function Count(v)
  if ns.IsSecret(v) or type(v) ~= "number" or v ~= v then return nil end
  return math.max(0, math.min(W.MAX_COUNT, math.floor(v)))
end

-- calls C_QuestLog[name](...) if this client has it
local function Q(name, ...)
  local fn = C_QuestLog and C_QuestLog[name]
  if type(fn) ~= "function" then return nil end
  return fn(...)
end

local function ReadObjectives(questID)
  local obj = {}
  local list = Q("GetQuestObjectives", questID)
  if type(list) ~= "table" then return obj end
  for i = 1, #list do
    if #obj >= W.MAX_OBJ then break end
    local o = list[i]
    if type(o) == "table" then
      local have, need = Count(o.numFulfilled), Count(o.numRequired)
      -- an objective without a count ("Speak to Marshal Dughan"): 1 when done
      if not need or need == 0 then
        need = 1
        have = o.finished and 1 or 0
      end
      obj[#obj + 1] = { have = have or (o.finished and need or 0), need = need, text = QL.StripCount(o.text) }
    end
  end
  return obj
end

local function ReadQuest(id, title, level, zone)
  local lvl = Count(level)
  return {
    id = id, title = title, zone = zone,
    level = (lvl and lvl <= W.MAX_LEVEL) and lvl or 0,
    complete = Q("IsComplete", id) and true or false,
    pushable = Q("IsPushableQuest", id) and true or false,
    obj = ReadObjectives(id),
  }
end

local function IsQuestID(id)
  return type(id) == "number" and id == math.floor(id) and id >= 1 and id <= W.MAX_ID
end

-- quests the game told us were abandoned or handed in since the last scan
local goneByEvent = {}

-- The whole log -> { [id] = quest }, or nil when there's no API to read.
-- Errors aren't caught here: QL.Scan catches them and keeps the old snapshot.
local function ReadLog()
  local n = Q("GetNumQuestLogEntries")
  if type(n) ~= "number" or not (C_QuestLog and C_QuestLog.GetInfo) then return nil end
  local quests, count = {}, 0
  -- (a sent quest's zone is never blank: see W.NO_ZONE)
  local zone, collapsed = W.NO_ZONE, {}
  for i = 1, math.min(n, QL.MAX_ENTRIES) do
    local info = C_QuestLog.GetInfo(i)
    if type(info) == "table" then
      if info.isHeader then
        zone = W.CleanLocal(info.title, W.MAX_ZONE) or ""
        if zone == "" then zone = W.NO_ZONE end
        if info.isCollapsed then collapsed[zone] = true end
      elseif not info.isHidden then
        local id = info.questID
        local title = W.CleanLocal(info.title, W.MAX_TITLE)
        -- (a quest whose title hasn't loaded yet comes in on a later scan)
        if IsQuestID(id) and not quests[id] and title and title ~= "" and count < W.MAX_QUESTS then
          quests[id] = ReadQuest(id, title, info.level, zone)
          count = count + 1
        end
      end
    end
  end
  -- A collapsed header may hide its quests from the list (the client's
  -- behaviour needs an in-game check). Quests we had under it stay, read
  -- again by ID, unless the game said they're gone or they're handed in.
  for id, old in pairs(ns.mine.quests) do
    if not quests[id] and collapsed[old.zone] and not goneByEvent[id] and count < W.MAX_QUESTS
      and not Q("IsQuestFlaggedCompleted", id) then
      quests[id] = ReadQuest(id, old.title, old.level, old.zone)
      count = count + 1
    end
  end
  return quests
end

-- The IDs our L lists, lowest first: only quests that can be sent. One that
-- can't (it breaks a limit) stays in our own panel, but listing it would make
-- everyone ask for it with R again and again. (The checksum skips it too, so
-- both sides still agree.)
local function SendableIDs(quests)
  local ids = {}
  for _, id in ipairs(W.SortedIDs(quests)) do
    if W.EncodeQuest(quests[id]) then ids[#ids + 1] = id end
  end
  return ids
end

local function ObjectiveText(q)
  local parts = {}
  for i, o in ipairs(q.obj) do parts[i] = o.text or "" end
  return table.concat(parts, "\n")
end

-- Reads the log and updates ns.mine. Returns dirty, removed (sorted arrays of
-- quest IDs) and whether only our own objective text changed; nil when the
-- log couldn't be read (ns.mine is left as it was).
function QL.Scan()
  local ok, quests = pcall(ReadLog)
  if not ok then
    ns.ReportError("quest log: " .. tostring(quests))
    return nil
  end
  if not quests then
    QL.available = false
    return nil
  end
  QL.available = true
  for id in pairs(goneByEvent) do goneByEvent[id] = nil end

  local old = ns.mine.quests
  local dirty, removed, textChanged = {}, {}, false
  for id, q in pairs(quests) do
    local o = old[id]
    if not o or W.EncodeQuest(o) ~= W.EncodeQuest(q) then
      dirty[#dirty + 1] = id
    elseif ObjectiveText(o) ~= ObjectiveText(q) then
      textChanged = true
    end
  end
  for id in pairs(old) do
    if not quests[id] then removed[#removed + 1] = id end
  end
  table.sort(dirty)
  table.sort(removed)
  if #dirty > 0 or #removed > 0 or textChanged then
    ns.mine.quests = quests
    ns.mine.list = SendableIDs(quests)
    ns.mine.listSum = W.Checksum(quests)
  end
  return dirty, removed, textChanged
end

-- scan now, and tell everyone listening what changed
function QL.Rescan()
  local dirty, removed, textChanged = QL.Scan()
  if not dirty then return end
  if #dirty > 0 or #removed > 0 then ns.Fire("MINE_CHANGED", dirty, removed) end
  if #dirty > 0 or #removed > 0 or textChanged then ns.Fire("CHANGED") end
end

-- scan 0.5 s from now; more changes in the meantime join that one scan
function QL.RescanSoon()
  ns.Coalesce("questlog", 0.5, QL.Rescan)
end

------------------------------------------------------------------------
-- For the panel and the chain rules
------------------------------------------------------------------------
-- the label for objective i of a quest: our own text if we have the quest
-- and the game gave text for it, otherwise "Objective i"
function QL.ObjectiveLabel(questID, i)
  local q = ns.mine.quests[questID]
  local o = q and q.obj[i]
  return (o and o.text) or ("Objective " .. i)
end

-- have we ever handed this quest in? (nil when the client can't tell us)
function QL.IsDone(questID)
  if not IsQuestID(questID) then return nil end
  local ok, done = pcall(Q, "IsQuestFlaggedCompleted", questID)
  if not ok then return nil end
  return done and true or false
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------
local function Gone(questID)
  if IsQuestID(questID) then goneByEvent[questID] = true end
  QL.RescanSoon()
end

ns.RegisterEvent("PLAYER_LOGIN", QL.Rescan)
ns.RegisterEvent("QUEST_LOG_UPDATE", QL.RescanSoon)
ns.RegisterEvent("QUEST_ACCEPTED", QL.RescanSoon)
ns.RegisterEvent("QUEST_REMOVED", Gone)
ns.RegisterEvent("QUEST_TURNED_IN", Gone)
ns.RegisterEvent("UNIT_QUEST_LOG_CHANGED", function(unit)
  if unit == "player" then QL.RescanSoon() end
end)
