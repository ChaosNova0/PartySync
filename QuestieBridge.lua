-- QuestieBridge: the ONLY file that reads Questie's quest database. Everything
-- here is guarded: a function is checked before it's called and every call
-- runs under pcall. Any error marks the bridge "broken" for the session (see
-- /psync questie) and from then on it just answers "don't know", so the rest
-- of PartySync carries on without it.
--
-- QuestieDB is GPLv3, so nothing read from it is ever saved: there's only a
-- cache for this session, and the saved "Track next step" keeps quest IDs only.
--
-- Where the data comes from (in order):
--   1. LibQuestieDB, the stand-alone QuestieDB addon (works without Questie).
--      Read from its own source (QuestieDB 1.0.13, contract 4):
--        src/api.lua      LibQuestieDB global, RequireContract(n), contractVersion,
--                         Enum.raceMaskById, Enum.classKeys, readMode
--        src/read/shared.lua   Quest.Get(id, field), Quest.Exists(id), Npc.Get, Object.Get, Item.Get
--        src/meta/questMeta.lua, npcMeta.lua   the field names
--        src/support/data.lua  Support.Get("ZoneDB").private.areaIdToUiMapId (Lua source text)
--      Its data can be read as soon as the addon has loaded; there's no
--      "ready" event, so it's "ready" once the global is there and the
--      contract check passes.
--   2. Full Questie without LibQuestieDB (older Questie with the database
--      inside it): QuestieLoader:ImportModule("QuestieDB").QueryQuestSingle.
--      Not installed here, so this path is a guarded guess: "loading" until
--      QueryQuestSingle exists, checked every 2 s for up to 2 minutes.
--
-- ns.QDB:
--   QDB.state       "none" (not installed) | "loading" | "ready" | "broken"
--   QDB.backend     "LibQuestieDB" | "Questie" | nil
--   QDB.contract    LibQuestieDB.contractVersion, or nil
--   QDB.lastError   the error that broke it, or nil
--   QDB.Init()      at PLAYER_LOGIN (and on first use, whichever comes first)
--   QDB.State()     the state, starting the bridge if it hasn't started yet
--   QDB.Field(kind, id, field)   kind "quest" | "npc" | "object" | "item";
--                   the value checked and cleaned (see SHAPES), or nil
--   QDB.Quest(id) -> { id, name, level, reqLevel, preAll = {ids}, preAny = {ids},
--                      next, exclusive = {ids}, breadcrumbs = {ids},
--                      starters = { npcs = {ids}, objects = {ids}, items = {ids} },
--                      races, classes }      (0 = any race / any class)
--                    false when the database doesn't know the quest, nil when
--                    there's no database to ask
--   QDB.Giver(questID) -> { name, kind = "npc"|"object"|"item", id, areaId, x, y,
--                           zone, dir } or nil   (x, y are 0-100; dir "south-west"...)
--   QDB.ZoneName(areaId), QDB.UiMapID(areaId), QDB.Direction(x, y)
--   QDB.QuestZones(questID [, cachedOnly]) -> { [zoneName] = true }, count:
--                   where the quest's mobs, objects, item drops and explore
--                   spots are (nil: no database, or not worked out yet with
--                   cachedOnly). The table is the cache's own: read it, don't change it.
--   QDB.MyRaceMask(), QDB.MyClassMask()   our bits in requiredRaces / requiredClasses
--   QDB.ShowOnMap(questID) -> ok, how ("pin" | "questie"), giver
--   QDB.ParseMapText(text, into) -> pairs read, or nil (see "Zones and maps")
--   QDB.PrintStatus()   /psync questie

local _, ns = ...
local QDB = {}
ns.QDB = QDB
local W = ns.Wire

QDB.CONTRACT = 4      -- the LibQuestieDB contract this file was written against
QDB.MAX_TEXT = 80     -- bytes kept of any name
QDB.MAX_LIST = 50     -- IDs kept of any list
QDB.MAX_CACHE = 2000  -- cached entries at most (see the cache below)
QDB.MAX_MAP_TEXT = 300 * 1024 -- the area -> map text we'll read, in bytes
QDB.MAX_MAP_ENTRIES = 5000    -- ...and the most pairs we'll take from it
QDB.LOAD_WAIT = 120   -- seconds to wait for full Questie to finish loading
QDB.RETRY = 2         -- seconds between those checks

QDB.state = "none"
QDB.backend = nil
QDB.contract = nil
QDB.lastError = nil

local started = false
local reader        -- { Get(kind, id, field), Exists(id) } for the backend in use
local lib           -- LibQuestieDB, when that's the backend
local startedAt     -- when we started waiting for full Questie

-- The session cache, in two generations: new entries go into `cur`; when it
-- holds half of MAX_CACHE, it becomes `old` and the oldest generation goes.
-- An entry found in `old` is still in use, so it moves into `cur`. That way
-- the cache never holds more than MAX_CACHE entries and never empties at once.
local cur, old = {}, {} -- [kind][id] = value, false for "not known" (session only)
local curCount = 0

local function ClearCache()
  cur, old, curCount = {}, {}, 0
end

local Store
local function Cached(kind, id)
  local t = cur[kind]
  local v = t and t[id]
  if v ~= nil then return v end
  t = old[kind]
  v = t and t[id]
  if v ~= nil then Store(kind, id, v) end
  return v
end

Store = function(kind, id, value)
  if curCount >= QDB.MAX_CACHE / 2 then cur, old, curCount = {}, cur, 0 end
  local t = cur[kind]
  if not t then t = {} cur[kind] = t end
  if t[id] == nil then curCount = curCount + 1 end
  t[id] = value
  return value
end

-- the connection changed (ready, loading, broken): Chain.lua's cache listens
local function StateChanged()
  ns.Fire("QDB_CHANGED")
  ns.Fire("CHANGED")
end

-- Something went wrong inside Questie's code: stop asking it this session.
local function Fail(err)
  QDB.state = "broken"
  QDB.lastError = W.CleanLocal(tostring(err), 200) or "unknown error"
  reader, lib = nil, nil
  ClearCache()
  ns.Debug("Questie bridge broken: " .. QDB.lastError)
  StateChanged()
end

------------------------------------------------------------------------
-- Connecting
------------------------------------------------------------------------
-- 1. LibQuestieDB. Returns the reader, or nil plus why it can't be used
-- (nil, nil: it isn't installed).
local function LibReader()
  local L = LibQuestieDB
  if type(L) ~= "table" then return nil, nil end
  if type(L.RequireContract) ~= "function" then return nil, "this QuestieDB has no contract check" end
  -- (a range check: any QuestieDB that still supports contract 4 passes)
  local ok, good, msg = pcall(L.RequireContract, QDB.CONTRACT)
  if not ok then return nil, good end
  if good ~= true then return nil, msg or ("QuestieDB doesn't support contract " .. QDB.CONTRACT) end
  local entities = { quest = L.Quest, npc = L.Npc, object = L.Object, item = L.Item }
  for _, kind in ipairs({ "quest", "npc" }) do
    local e = entities[kind]
    if type(e) ~= "table" or type(e.Get) ~= "function" then return nil, "QuestieDB has no " .. kind .. " reader" end
  end
  local Quest = entities.quest
  return {
    Get = function(kind, id, field)
      local e = entities[kind]
      if type(e) ~= "table" or type(e.Get) ~= "function" then return nil end
      return e.Get(id, field)
    end,
    Exists = function(id)
      if type(Quest.Exists) == "function" then return Quest.Exists(id) and true or false end
      return Quest.Get(id, "name") ~= nil
    end,
  }, nil, L
end

-- 2. Full Questie's own database module. Returns the reader, "loading", or nil.
local QUESTIE_FN = { quest = "QueryQuestSingle", npc = "QueryNPCSingle", object = "QueryObjectSingle", item = "QueryItemSingle" }
local function QuestieReader()
  if type(QuestieLoader) ~= "table" or type(QuestieLoader.ImportModule) ~= "function" then return nil end
  local ok, db = pcall(QuestieLoader.ImportModule, QuestieLoader, "QuestieDB")
  if not ok or type(db) ~= "table" then return nil end
  local api = type(Questie) == "table" and Questie.API
  if type(api) == "table" and api.isReady == false then return "loading" end
  if type(db.QueryQuestSingle) ~= "function" then return "loading" end
  return {
    Get = function(kind, id, field)
      local fn = db[QUESTIE_FN[kind] or ""]
      if type(fn) ~= "function" then return nil end
      return fn(id, field)
    end,
    Exists = function(id) return db.QueryQuestSingle(id, "name") ~= nil end,
  }
end

local function Connect()
  local r, err, L = LibReader()
  if r then
    reader, lib = r, L
    QDB.backend = "LibQuestieDB"
    QDB.contract = type(L.contractVersion) == "number" and L.contractVersion or nil
    QDB.state = "ready"
    StateChanged()
    return
  end
  if err then return Fail(err) end

  local q = QuestieReader()
  if type(q) == "table" then
    reader = q
    QDB.backend = "Questie"
    QDB.state = "ready"
    StateChanged()
  elseif q == "loading" then
    QDB.backend = "Questie"
    QDB.state = "loading"
    startedAt = startedAt or GetTime()
    if GetTime() - startedAt >= QDB.LOAD_WAIT then
      return Fail("Questie didn't finish loading its quest data")
    end
    ns.After(QDB.RETRY, function()
      if QDB.state == "loading" then
        local ok, e = pcall(Connect)
        if not ok then Fail(e) end
      end
    end)
  else
    QDB.state = "none"
  end
end

function QDB.Init()
  if started then return end
  started = true
  local ok, err = pcall(Connect)
  if not ok then Fail(err) end
end

function QDB.State()
  if not started then QDB.Init() end
  return QDB.state
end

------------------------------------------------------------------------
-- Reading one field, checked and cleaned
------------------------------------------------------------------------
local function IsID(v)
  return type(v) == "number" and v == v and v >= 1 and v <= 9999999 and v == math.floor(v)
end

local function Number(v)
  if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then return nil end
  return v
end

local function IDs(v)
  if type(v) ~= "table" then return nil end
  local out = {}
  for i = 1, math.min(#v, QDB.MAX_LIST) do
    if IsID(v[i]) then out[#out + 1] = v[i] end
  end
  return #out > 0 and out or nil
end

local function Coord(v) return type(v) == "number" and v == v and ((v >= 0 and v <= 100) or v == -1) end

-- spawns: { [areaId] = { { x, y [, phase] }, ... } } -> { { areaId, x, y }, ... }
-- (the first good spot in each zone, lowest zone first, at most 20 zones)
local function Spawns(v)
  if type(v) ~= "table" then return nil end
  local zones = {}
  for areaId, list in pairs(v) do
    if IsID(areaId) and type(list) == "table" then zones[#zones + 1] = areaId end
  end
  table.sort(zones)
  local out = {}
  for _, areaId in ipairs(zones) do
    if #out >= 20 then break end
    for _, spot in ipairs(v[areaId]) do
      if type(spot) == "table" and Coord(spot[1]) and Coord(spot[2]) then
        out[#out + 1] = { areaId = areaId, x = spot[1], y = spot[2] }
        break
      end
    end
  end
  return #out > 0 and out or nil
end

local SHAPES = {
  text = function(v)
    local s = W.CleanLocal(v, QDB.MAX_TEXT)
    return (s and s ~= "") and s or nil
  end,
  number = Number,
  id = function(v) return IsID(v) and v or nil end,
  ids = IDs,
  -- startedBy: { npcIds?, objectIds?, itemIds? }
  starters = function(v)
    if type(v) ~= "table" then return nil end
    return { npcs = IDs(v[1]) or {}, objects = IDs(v[2]) or {}, items = IDs(v[3]) or {} }
  end,
  spawns = Spawns,
  -- objectives: { creature, object, item, reputation, killCredit, spell }, where
  -- creature / object / item are lists of { id, text, icon } and killCredit is a
  -- list of { ids, baseId, baseText, icon } -> { npcs = {ids}, objects = {ids}, items = {ids} }
  objectives = function(v)
    if type(v) ~= "table" then return nil end
    local out = { npcs = {}, objects = {}, items = {} }
    local function Add(list, id)
      if IsID(id) and #list < QDB.MAX_LIST then list[#list + 1] = id end
    end
    for slot, list in pairs({ [1] = out.npcs, [2] = out.objects, [3] = out.items }) do
      local rows = v[slot]
      if type(rows) == "table" then
        for i = 1, math.min(#rows, QDB.MAX_LIST) do
          if type(rows[i]) == "table" then Add(list, rows[i][1]) end
        end
      end
    end
    local credits = v[5]
    if type(credits) == "table" then
      for i = 1, math.min(#credits, QDB.MAX_LIST) do
        local row = credits[i]
        if type(row) == "table" then
          Add(out.npcs, row[2])
          if type(row[1]) == "table" then
            for j = 1, math.min(#row[1], QDB.MAX_LIST) do Add(out.npcs, row[1][j]) end
          end
        end
      end
    end
    return out
  end,
  -- triggerEnd: { text, { [areaId] = { { x, y }, ... } } } -> { areaIds }
  trigger = function(v)
    if type(v) ~= "table" or type(v[2]) ~= "table" then return nil end
    local out = {}
    for areaId in pairs(v[2]) do
      if IsID(areaId) and #out < QDB.MAX_LIST then out[#out + 1] = areaId end
    end
    table.sort(out)
    return #out > 0 and out or nil
  end,
}

-- the shape each field we read should have (anything else reads as nil)
local FIELDS = {
  name = "text", questLevel = "number", requiredLevel = "number",
  requiredRaces = "number", requiredClasses = "number",
  preQuestGroup = "ids", preQuestSingle = "ids", exclusiveTo = "ids", breadcrumbs = "ids",
  nextQuestInChain = "id", startedBy = "starters", spawns = "spawns", zoneID = "id",
  objectives = "objectives", triggerEnd = "trigger", npcDrops = "ids", objectDrops = "ids",
}

function QDB.Field(kind, id, field)
  if QDB.State() ~= "ready" or not reader then return nil end
  local shape = SHAPES[FIELDS[field] or ""]
  if not shape or not IsID(id) then return nil end
  local ok, v = pcall(reader.Get, kind, id, field)
  if not ok then Fail(v) return nil end
  return shape(v)
end

------------------------------------------------------------------------
-- Quests and who starts them
------------------------------------------------------------------------
function QDB.Quest(id)
  if QDB.State() ~= "ready" or not IsID(id) then return nil end
  local hit = Cached("quest", id)
  if hit ~= nil then return hit end
  local ok, exists = pcall(reader.Exists, id)
  if not ok then Fail(exists) return nil end
  if not exists then return Store("quest", id, false) end
  local function F(field) return QDB.Field("quest", id, field) end
  local q = {
    id = id, name = F("name"), level = F("questLevel") or 0, reqLevel = F("requiredLevel") or 0,
    preAll = F("preQuestGroup") or {}, preAny = F("preQuestSingle") or {},
    next = F("nextQuestInChain"), exclusive = F("exclusiveTo") or {}, breadcrumbs = F("breadcrumbs") or {},
    starters = F("startedBy") or { npcs = {}, objects = {}, items = {} },
    races = F("requiredRaces") or 0, classes = F("requiredClasses") or 0,
  }
  -- (a read failed part way: don't keep a half-read quest)
  if QDB.state ~= "ready" then return nil end
  return Store("quest", id, q)
end

-- "south-west", "north", ... from 0-100 map coordinates (a 3 x 3 grid), or nil
function QDB.Direction(x, y)
  if type(x) ~= "number" or type(y) ~= "number" or x < 0 or y < 0 then return nil end
  local northSouth = y < 100 / 3 and "north" or (y > 200 / 3 and "south" or nil)
  local eastWest = x < 100 / 3 and "west" or (x > 200 / 3 and "east" or nil)
  if northSouth and eastWest then return northSouth .. "-" .. eastWest end
  return northSouth or eastWest or "centre"
end

local function Spot(kind, sid, current)
  local name = QDB.Field(kind, sid, "name")
  if not name then return nil end
  local g = { name = name, kind = kind, id = sid }
  local spawns = QDB.Field(kind, sid, "spawns")
  if not spawns then return g, false end
  -- prefer a spot in the zone we're in, then the zone it's most often in
  local home = QDB.Field(kind, sid, "zoneID")
  local pick, here
  for _, s in ipairs(spawns) do
    if current ~= "" and QDB.ZoneName(s.areaId) == current then pick, here = s, true break end
  end
  if not pick and home then
    for _, s in ipairs(spawns) do if s.areaId == home then pick = s break end end
  end
  pick = pick or spawns[1]
  g.areaId, g.x, g.y = pick.areaId, pick.x, pick.y
  g.zone = QDB.ZoneName(pick.areaId)
  g.dir = QDB.Direction(pick.x, pick.y)
  return g, here
end

-- Who or what starts a quest, and where: the first NPC (then object) with a
-- known spot, preferring one in the zone we're in. Items have no spot.
function QDB.Giver(questID)
  local q = QDB.Quest(questID)
  if not q then return nil end
  local hit = Cached("giver", questID)
  if hit ~= nil then return hit or nil end
  local current = ns.CurrentZone()
  local first, named
  for _, kind in ipairs({ "npc", "object" }) do
    local list = kind == "npc" and q.starters.npcs or q.starters.objects
    for i = 1, math.min(#list, 5) do
      local g, here = Spot(kind, list[i], current)
      if QDB.state ~= "ready" then return nil end
      if g then
        if here then return Store("giver", questID, g) end
        if g.areaId then first = first or g else named = named or g end
      end
    end
  end
  if not first and not named and q.starters.items[1] then
    local name = QDB.Field("item", q.starters.items[1], "name")
    if name then named = { name = name, kind = "item", id = q.starters.items[1] } end
  end
  if QDB.state ~= "ready" then return nil end
  local g = first or named
  Store("giver", questID, g or false)
  return g
end

------------------------------------------------------------------------
-- Where a quest's work is done
------------------------------------------------------------------------
-- The quest log files some quests under the city that gave them (Un'Goro Soil
-- sits under "Thunder Bluff"), so the heading alone can miss the zone you do
-- the quest in. This looks up where the quest's mobs and objects are, where its
-- items drop, and where an "explore" spot is.
QDB.MAX_ZONE_SOURCES = 10 -- the most NPCs / objects looked at per objective list
QDB.MAX_DROP_ZONES = 3    -- an item that drops in more zones than this (or from
                          -- more than MAX_ZONE_SOURCES NPCs and objects) drops
                          -- "everywhere" (cloth, say): it says nothing about
                          -- where to go, so it's skipped
QDB.MAX_QUEST_ZONES = 20  -- the most zones kept per quest

-- QDB.QuestZones(questID [, cachedOnly]) -> { [zoneName] = true } (may be
-- empty) and how many zones, or nil when there's no database to ask (or, with
-- cachedOnly, when it hasn't been worked out yet). Cached for the session.
function QDB.QuestZones(questID, cachedOnly)
  if QDB.State() ~= "ready" or not IsID(questID) then return nil end
  local hit = Cached("qzones", questID)
  if hit ~= nil then return hit.zones, hit.count end
  if cachedOnly then return nil end
  local zones, count = {}, 0
  local function AddArea(areaId)
    if count >= QDB.MAX_QUEST_ZONES then return end
    local name = QDB.ZoneName(areaId)
    if name and not zones[name] then zones[name] = true count = count + 1 end
  end
  local function AddSpawner(kind, id)
    local home = QDB.Field(kind, id, "zoneID")
    if home then AddArea(home) end
    for _, s in ipairs(QDB.Field(kind, id, "spawns") or {}) do AddArea(s.areaId) end
  end
  local function Each(list, fn)
    for i = 1, math.min(#list, QDB.MAX_ZONE_SOURCES) do fn(list[i]) end
  end
  local obj = QDB.Field("quest", questID, "objectives")
  if obj then
    Each(obj.npcs, function(id) AddSpawner("npc", id) end)
    Each(obj.objects, function(id) AddSpawner("object", id) end)
    Each(obj.items, function(item)
      local npcs = QDB.Field("item", item, "npcDrops") or {}
      local objects = QDB.Field("item", item, "objectDrops") or {}
      if #npcs + #objects > QDB.MAX_ZONE_SOURCES then return end
      -- (where it drops, kept only if that's a few zones: see MAX_DROP_ZONES)
      local found, n = {}, 0
      local function Note(areaId)
        local name = QDB.ZoneName(areaId)
        if name and not found[name] then found[name] = areaId n = n + 1 end
      end
      local function Drops(kind, id)
        local home = QDB.Field(kind, id, "zoneID")
        if home then Note(home) end
        for _, s in ipairs(QDB.Field(kind, id, "spawns") or {}) do Note(s.areaId) end
      end
      for _, id in ipairs(npcs) do Drops("npc", id) end
      for _, id in ipairs(objects) do Drops("object", id) end
      if n > QDB.MAX_DROP_ZONES then return end
      for _, areaId in pairs(found) do AddArea(areaId) end
    end)
  end
  for _, areaId in ipairs(QDB.Field("quest", questID, "triggerEnd") or {}) do AddArea(areaId) end
  -- (a read failed part way: don't keep a half-read answer)
  if QDB.state ~= "ready" then return nil end
  Store("qzones", questID, { zones = zones, count = count })
  return zones, count
end

------------------------------------------------------------------------
-- Zones and maps
------------------------------------------------------------------------
-- QuestieDB keeps its area -> map table as Lua source text (support data,
-- see src/support/data.lua; support/Forever/Zones/areaIdToUiMapId.lua holds
-- lines like "    [12] = 1429, -- Elwynn Forest" inside "return { ... }").
-- It's READ as text, never run: comments are taken off line by line, the
-- rest may only be "return", digits, spaces and the characters [ ] = { } , -
-- (anything else and the whole text is refused). It must be one flat table:
-- the outer { } and no other braces, or it's refused too. Then each "[n] = m"
-- pair is picked out: areas 1-999999, maps 0-999999 (the override uses 0 to
-- hide an area); other numbers are skipped. At most MAX_MAP_TEXT bytes and
-- MAX_MAP_ENTRIES pairs. Done once per session and never saved. Returns the
-- number of pairs read, or nil when the text was refused.
-- (Spaces are spelled out instead of "%s", which follows the language setting.)
local uiMaps -- [areaId] = uiMapID, false when there's no table to read
function QDB.ParseMapText(text, into)
  if type(text) ~= "string" or #text > QDB.MAX_MAP_TEXT then return nil end
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = (line:gsub("%-%-.*$", ""))
  end
  local body = table.concat(lines, "\n")
  -- (only one "return", at the start)
  local rest = body:gsub("^[ \t\r\n]*return", "", 1)
  if rest:find("[^%d \t\r\n%[%]={},%-]") then return nil end
  local inner = rest:match("^[ \t\r\n]*{([^{}]*)}[ \t\r\n]*$")
  if not inner then return nil end
  local n = 0
  for k, v in inner:gmatch("%[(%d+)%][ \t\r\n]*=[ \t\r\n]*(%d+)") do
    if n >= QDB.MAX_MAP_ENTRIES then break end
    if #k <= 6 and #v <= 6 then
      k, v = tonumber(k), tonumber(v)
      if k >= 1 and into[k] == nil then into[k] = v end
    end
    n = n + 1
  end
  return n
end

local function LoadMapTable(text, into)
  if type(text) == "table" then
    local n = 0
    for k, v in pairs(text) do
      if n >= QDB.MAX_MAP_ENTRIES then break end
      if IsID(k) and into[k] == nil and type(v) == "number" then into[k] = v end
      n = n + 1
    end
    return
  end
  if QDB.ParseMapText(text, into) == nil and text ~= nil then
    ns.Debug("QuestieDB's area map text has an unexpected shape: not read")
  end
end

local function MapTable()
  if uiMaps ~= nil then return uiMaps end
  uiMaps = false
  local ok, err = pcall(function()
    if lib and type(lib.Support) == "table" and type(lib.Support.Get) == "function" then
      local zdb = lib.Support.Get("ZoneDB")
      local private = type(zdb) == "table" and zdb.private
      if type(private) == "table" then
        local t = {}
        -- (the override wins: QuestieDB uses it to hide or redirect some areas)
        LoadMapTable(private.areaIdToUiMapIdOverride, t)
        LoadMapTable(private.areaIdToUiMapId, t)
        uiMaps = t
      end
    end
  end)
  if not ok then ns.Debug("no area map table: " .. tostring(err)) end
  return uiMaps
end

-- the game's map ID (uiMapID) for a QuestieDB area ID, or nil
function QDB.UiMapID(areaId)
  if not IsID(areaId) or QDB.State() ~= "ready" then return nil end
  if lib then
    local t = MapTable()
    local m = t and t[areaId]
    return (IsID(m)) and m or nil
  end
  -- full Questie's own zone module (guarded: not checked on Forever)
  local ok, m = pcall(function()
    local zdb = QuestieLoader:ImportModule("ZoneDB")
    return zdb and zdb.GetUiMapIdByAreaId and zdb:GetUiMapIdByAreaId(areaId)
  end)
  return (ok and IsID(m)) and m or nil
end

local function MapCall(name, ...)
  local fn = C_Map and C_Map[name]
  if type(fn) ~= "function" then return nil end
  local ok, v = pcall(fn, ...)
  if not ok or ns.IsSecret(v) then return nil end
  return v
end

-- the zone's name in the game's language, or nil
function QDB.ZoneName(areaId)
  if not IsID(areaId) then return nil end
  local hit = Cached("zone", areaId)
  if hit ~= nil then return hit or nil end
  local name = MapCall("GetAreaInfo", areaId)
  if type(name) ~= "string" or name == "" then
    local m = QDB.UiMapID(areaId)
    local info = m and MapCall("GetMapInfo", m)
    name = type(info) == "table" and info.name or nil
  end
  name = W.CleanLocal(name, W.MAX_ZONE)
  if name == "" then name = nil end
  Store("zone", areaId, name or false)
  return name
end

------------------------------------------------------------------------
-- Race and class (requiredRaces / requiredClasses are bit masks)
------------------------------------------------------------------------
local raceMask, classMask -- (looked up once a session; false: unknown)

function QDB.MyRaceMask()
  if raceMask == nil then
    raceMask = false
    local ok, _, _, id = pcall(UnitRace, "player")
    if ok and type(id) == "number" and not ns.IsSecret(id) then
      local enum = lib and type(lib.Enum) == "table" and lib.Enum.raceMaskById
      local m = type(enum) == "table" and enum[id]
      -- (Questie's old encoding: race ID n is bit n - 1. Forever's new races
      -- are outside that, which is why QuestieDB has the table.)
      if type(m) ~= "number" and id >= 1 and id <= 11 then m = 2 ^ (id - 1) end
      if type(m) == "number" and m > 0 then raceMask = m end
    end
  end
  return raceMask or nil
end

function QDB.MyClassMask()
  if classMask == nil then
    classMask = false
    local ok, _, file, id = pcall(UnitClass, "player")
    if ok and not ns.IsSecret(file) then
      local keys = lib and type(lib.Enum) == "table" and lib.Enum.classKeys
      local key = type(file) == "string" and (file == "DEATHKNIGHT" and "DEATH_KNIGHT" or file)
      local m = type(keys) == "table" and key and keys[key]
      if type(m) ~= "number" and type(id) == "number" and id >= 1 and id <= 12 then m = 2 ^ (id - 1) end
      if type(m) == "number" and m > 0 then classMask = m end
    end
  end
  return classMask or nil
end

------------------------------------------------------------------------
-- Show on map
------------------------------------------------------------------------
-- Full Questie's own map icons for an NPC or object, used only when we
-- couldn't work out a map for a pin. The call is QuestieMap:ShowNPC(npcID)
-- / QuestieMap:ShowObject(objectID): Questie's source (Modules/Map/
-- QuestieMap.lua) has ShowNPC(npcID, icon, scale, title, body,
-- disableShiftToRemove, typ, excludeDungeon), all but the ID optional, and
-- it finds the spawns itself. Not checked in game (Questie isn't installed).
local function QuestieIcons(g)
  if type(Questie) ~= "table" or type(QuestieLoader) ~= "table" or type(QuestieLoader.ImportModule) ~= "function" then
    return false
  end
  local method = (g.kind == "npc" and "ShowNPC") or (g.kind == "object" and "ShowObject") or nil
  if not method then return false end
  local ok, map = pcall(QuestieLoader.ImportModule, QuestieLoader, "QuestieMap")
  if not ok or type(map) ~= "table" or type(map[method]) ~= "function" then return false end
  return (pcall(map[method], map, g.id)) and true or false
end

-- A map pin (the game's user waypoint) when we know the map; otherwise full
-- Questie's own map icons, if it's installed. Returns ok, how ("pin" |
-- "questie"), giver.
function QDB.ShowOnMap(questID)
  local g = QDB.Giver(questID)
  if not g then return false, nil, nil end
  local m = g.areaId and QDB.UiMapID(g.areaId)
  if m and g.x and g.x >= 0 and g.y >= 0 then
    if C_Map and type(C_Map.SetUserWaypoint) == "function"
      and type(UiMapPoint) == "table" and type(UiMapPoint.CreateFromCoordinates) == "function" then
      if type(C_Map.CanSetUserWaypointOnMap) == "function" then
        local ok, can = pcall(C_Map.CanSetUserWaypointOnMap, m)
        if ok and can == false then return false, nil, g end
      end
      local ok = pcall(function()
        C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(m, g.x / 100, g.y / 100))
        -- (shows the pin's arrow on the edge of the screen, where the game has it)
        if C_SuperTrack and type(C_SuperTrack.SetSuperTrackedUserWaypoint) == "function" then
          C_SuperTrack.SetSuperTrackedUserWaypoint(true)
        end
      end)
      if ok then return true, "pin", g end
    end
    return false, nil, g
  end
  if not m and QuestieIcons(g) then return true, "questie", g end
  return false, nil, g
end

------------------------------------------------------------------------
-- /psync questie
------------------------------------------------------------------------
local STATE_TEXT = {
  none = "not installed. Install QuestieDB to see quest chains and where they start.",
  loading = "Questie is still loading its quest data.",
  ready = "connected.",
  broken = "couldn't read Questie's quest data, so quest chains are off until you /reload.",
}

function QDB.PrintStatus()
  local state = QDB.State()
  ns.Print("QuestieDB: " .. STATE_TEXT[state])
  local function Line(text) DEFAULT_CHAT_FRAME:AddMessage("  " .. text) end
  if QDB.backend then
    local mode = lib and type(lib.readMode) == "string" and (", " .. ns.Escape(lib.readMode) .. " mode") or ""
    Line("Using " .. QDB.backend .. (QDB.contract and (", contract " .. QDB.contract) or "") .. mode)
  end
  Line("Last error: " .. (QDB.lastError and ns.Escape(QDB.lastError) or "none"))
end

ns.RegisterEvent("PLAYER_LOGIN", QDB.Init)
