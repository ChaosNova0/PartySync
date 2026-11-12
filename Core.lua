-- PartySync: your party's quests in one list, for WoW: Forever
-- Core: namespace, saved data + migration, event dispatch, errors, Print,
-- the callback bus, timers and the slash command.
--
-- Saved data (one table per account, see DEFAULTS below):
--   PartySyncDB = {
--     dbVersion = 2,
--     settings  = { alertDone, alertSound, allowAsks, showSolo, hideOtherClass,
--                   autoOpen  (true/false; autoOpen: open the panel when a party starts),
--                   zoneFilter = "current" | "all" | a zone from your own quest log },
--     window    = { point = "TOPLEFT", relPoint, x, y, shown },
--     popup     = { point = "TOPLEFT", relPoint, x, y },  -- where the share popup was dragged to
--                   (both always by the top-left corner; version 1 kept any corner)
--     track     = { questID, forQuest, owner },     -- "Track next step": the step to pick
--                   up and the quest it leads to (0 = nothing tracked), and the GUID of
--                   the character who tracked it (other characters ignore it). Only IDs:
--                   names come from Questie each session and are never saved.
--     collapsed = { sections = { missing, progress, ready  (true/false) },
--                   quests   = { [questID] = true } },   -- at most 200 entries
--     minimap   = { angle, hide },   -- the minimap button: where it sits around
--                   the edge (degrees, 0-360) and whether it's hidden
--   }
-- Nothing about other players is ever saved: party members' quests live in
-- memory only (ns.members, see Group.lua) and a /reload just asks again.
--
-- Callback bus (ns.On / ns.Fire) events used so far:
--   "DB_READY"                saved data is set up
--   "ROSTER_CHANGED" (added, removed)   party GUIDs changed (Group.lua)
--   "MINE_CHANGED"   (dirty, removed)   our own quest log changed (QuestLog.lua)
--   "ZONE_CHANGED", "LEVEL_UP"
--   "CHANGED"                 something the panel shows may have changed
--   "SHARE_ASKED", "SHARE_ANSWERED"   ask to share (Comm.lua)
--   "ALL_DONE"       (questID, title)   a quest is ready for everyone (Model.lua)

local ADDON, ns = ...
ns.VERSION = "0.1.2" -- keep equal to ## Version in PartySync.toc

------------------------------------------------------------------------
-- Errors
------------------------------------------------------------------------
-- Errors inside PartySync are caught so one broken part can't stop the rest,
-- but each distinct error is passed once to the game's error handler, so it
-- shows up in BugSack / "Display Lua errors" and can be reported.
local reported = {}
function ns.ReportError(err)
  err = tostring(err)
  ns.Debug("error: " .. err)
  if reported[err] then return end
  reported[err] = true
  local handler = geterrorhandler and geterrorhandler()
  if handler then pcall(handler, "PartySync " .. (ns.VERSION or "") .. ": " .. err) end
end

-- Runs fn(...) under pcall; an error is reported (see above) instead of
-- stopping whoever called us. Returns fn's first result on success.
function ns.Call(fn, ...)
  local ok, res = pcall(fn, ...)
  if not ok then ns.ReportError(res) return nil end
  return res
end

------------------------------------------------------------------------
-- Small callback bus so files can react to each other without knowing
-- about each other (the panel listens for "CHANGED", for example)
------------------------------------------------------------------------
local listeners = {}
function ns.On(event, fn)
  listeners[event] = listeners[event] or {}
  table.insert(listeners[event], fn)
end
function ns.Fire(event, ...)
  local list = listeners[event]
  if not list then return end
  for _, fn in ipairs(list) do
    local ok, err = pcall(fn, ...)
    if not ok then ns.ReportError(event .. ": " .. tostring(err)) end
  end
end

------------------------------------------------------------------------
-- Printing
------------------------------------------------------------------------
function ns.Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cffdca77fPartySync|r: " .. tostring(msg))
end
-- debug lines only show when ns.debug is switched on for the session
-- (/run is not needed by players; tests and development turn it on)
function ns.Debug(msg)
  if ns.debug then DEFAULT_CHAT_FRAME:AddMessage("|cff888888PartySync debug|r: " .. tostring(msg)) end
end

-- Text from other players (or the game) put into chat or a font string:
-- "|" starts a colour or link code, so it's doubled to show as itself.
function ns.Escape(text)
  return (tostring(text or ""):gsub("|", "||"))
end

-- true when the game hides a value from addons (newer clients' "secret"
-- values); such values can't be compared or stored, so they're skipped
function ns.IsSecret(v)
  return issecretvalue ~= nil and v ~= nil and issecretvalue(v) and true or false
end

------------------------------------------------------------------------
-- Timers. Every callback runs under pcall (see ns.Call).
------------------------------------------------------------------------
function ns.After(delay, fn)
  C_Timer.After(delay, function() ns.Call(fn) end)
end

-- A repeating timer. Returns the ticker, so it can be stopped with :Cancel().
function ns.NewTicker(interval, fn)
  return C_Timer.NewTicker(interval, function() ns.Call(fn) end)
end

-- Debounce: run fn once, `delay` seconds after the LAST call with this key,
-- but never later than `maxWait` seconds after the FIRST one. Calls in
-- between only move the time (and the newest fn wins). Used for "wait 1 s
-- for more changes, never more than 3 s".
local pending = {} -- [key] = { due, deadline, fn }
function ns.Debounce(key, delay, maxWait, fn)
  local now = GetTime()
  local p = pending[key]
  if p then
    p.fn = fn
    p.due = math.min(now + delay, p.deadline)
    return
  end
  p = { due = now + delay, deadline = now + math.max(delay, maxWait or delay), fn = fn }
  pending[key] = p
  local function Check()
    local left = p.due - GetTime()
    -- (moved later by another call: wait the rest)
    if left > 0.001 then C_Timer.After(left, Check) return end
    pending[key] = nil
    ns.Call(p.fn)
  end
  C_Timer.After(delay, Check)
end

-- Coalesce: the first call starts a `delay` timer; calls while it's waiting
-- are folded into that one run. Used for "rescan 0.5 s later".
function ns.Coalesce(key, delay, fn)
  ns.Debounce(key, delay, delay, fn)
end

-- is a Debounce / Coalesce with this key waiting to run?
function ns.IsPending(key)
  return pending[key] ~= nil
end

------------------------------------------------------------------------
-- Saved data
------------------------------------------------------------------------
local DB_VERSION = 2
ns.DB_VERSION = DB_VERSION
ns.MAX_COLLAPSED = 200 -- collapsed.quests keeps at most this many quests

-- The two windows' sizes, for turning an old saved spot into a top-left one
-- (the panel's height changes all the time, so a typical one is used)
ns.WINDOW_SIZE = { window = { 340, 300 }, popup = { 300, 96 } }

local DEFAULTS = {
  dbVersion = DB_VERSION,
  settings = {
    alertDone = true,       -- alert when everyone's done with a quest
    alertSound = true,      -- ...with a sound
    allowAsks = true,       -- let party members ask you to share a quest
    showSolo = false,       -- show quests only you have in "In progress"
    hideOtherClass = true,  -- hide quests for another class or race
    zoneFilter = "current", -- "current", "all" or a zone name
    autoOpen = true,        -- open the panel by itself when you're in a party
  },
  -- (always anchored by the top-left corner, so a change of height grows or
  -- shrinks the bottom and the top stays put; the panel starts near the
  -- top of the screen, in the middle)
  window = { point = "TOPLEFT", relPoint = "TOP", x = -170, y = -120, shown = false },
  popup = { point = "TOPLEFT", relPoint = "CENTER", x = -150, y = 228 },
  track = { questID = 0, forQuest = 0, owner = "" },
  collapsed = {
    sections = { missing = false, progress = false, ready = false },
    quests = {},
  },
  minimap = { angle = 200, hide = false }, -- the minimap button (UI/Minimap.lua)
}
ns.DEFAULTS = DEFAULTS

local function CopyTable(t)
  local out = {}
  for k, v in pairs(t) do out[k] = type(v) == "table" and CopyTable(v) or v end
  return out
end

-- Fill in anything missing, including new keys inside nested tables.
-- Existing values are never replaced here.
local function MergeDefaults(target, defaults)
  for k, v in pairs(defaults) do
    if target[k] == nil then
      target[k] = type(v) == "table" and CopyTable(v) or v
    elseif type(v) == "table" and type(target[k]) == "table" then
      MergeDefaults(target[k], v)
    end
  end
end

-- Put the default back for anything whose type doesn't match the default's
-- (an edited or damaged SavedVariables file), all the way down. Keys that
-- aren't in DEFAULTS are left alone.
local function FixTypes(target, defaults)
  for k, v in pairs(defaults) do
    if type(target[k]) ~= type(v) then
      target[k] = type(v) == "table" and CopyTable(v) or v
    elseif type(v) == "table" then
      FixTypes(target[k], v)
    end
  end
end

local function IsFinite(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local POINTS = {
  CENTER = true, TOP = true, BOTTOM = true, LEFT = true, RIGHT = true,
  TOPLEFT = true, TOPRIGHT = true, BOTTOMLEFT = true, BOTTOMRIGHT = true,
}

local function IsQuestID(id)
  return IsFinite(id) and id >= 1 and id <= 999999 and id == math.floor(id)
end

-- (the same check as Wire.ValidGUID, which loads after this file)
local function IsGUID(s)
  return type(s) == "string" and #s <= 40 and s:match("^Player%-[0-9A-Za-z%-]+$") ~= nil
end

-- Turn a spot saved by another corner ("CENTER", "TOP", ...) into the same
-- spot for the top-left corner, for a window of width x height. The
-- reference point on the screen (relPoint) stays the same.
function ns.ToTopLeft(w, width, height)
  local p = w.point
  if p == "TOPLEFT" or not POINTS[p] then return end
  local dx = p:find("LEFT") and 0 or (p:find("RIGHT") and width or width / 2)
  local dy = p:find("TOP") and 0 or (p:find("BOTTOM") and -height or -height / 2)
  w.point = "TOPLEFT"
  w.x = math.floor(w.x - dx + 0.5)
  w.y = math.floor(w.y - dy + 0.5)
end

-- Fix values that have the right type but make no sense. Runs after
-- MergeDefaults and FixTypes, so every table here exists.
local function Sanitize(db)
  local s = db.settings
  if s.zoneFilter == "" or #s.zoneFilter > 80 then s.zoneFilter = DEFAULTS.settings.zoneFilter end

  for _, key in ipairs({ "window", "popup" }) do
    local w, d = db[key], DEFAULTS[key]
    -- (an unknown corner is read as the top-left one; its numbers are kept)
    if not POINTS[w.point] then w.point = "TOPLEFT" end
    if not POINTS[w.relPoint] then w.relPoint = d.relPoint end
    -- (far beyond any screen, but keeps the numbers sane)
    w.x = IsFinite(w.x) and math.max(-10000, math.min(10000, w.x)) or d.x
    w.y = IsFinite(w.y) and math.max(-10000, math.min(10000, w.y)) or d.y
    -- always the top-left corner (see DEFAULTS)
    local size = ns.WINDOW_SIZE[key]
    ns.ToTopLeft(w, size[1], size[2])
  end

  -- the tracked next step: real quest IDs, or nothing at all, and the
  -- character who tracked it ("" when not known)
  local t = db.track
  if not IsQuestID(t.questID) then t.questID, t.forQuest = 0, 0 end
  if not IsQuestID(t.forQuest) then t.forQuest = 0 end
  if t.owner ~= "" and not IsGUID(t.owner) then t.owner = "" end

  -- the minimap button's angle: a real number of degrees, from 0 up to 360
  local mm = db.minimap
  mm.angle = IsFinite(mm.angle) and (mm.angle % 360) or DEFAULTS.minimap.angle

  -- folded quests: only real quest IDs set to true, at most MAX_COLLAPSED
  -- (the lowest IDs are kept when there are too many)
  local ids = {}
  for id, v in pairs(db.collapsed.quests) do
    if IsQuestID(id) and v == true then ids[#ids + 1] = id end
  end
  table.sort(ids)
  local quests = {}
  for i = 1, math.min(#ids, ns.MAX_COLLAPSED) do quests[ids[i]] = true end
  db.collapsed.quests = quests
end

-- Each step turns saved data of version n into version n + 1. A step runs
-- on the table as it was loaded, so it checks every type itself.
local MIGRATIONS = {}

-- 1 -> 2: the windows are kept by their top-left corner now (version 1 kept
-- whichever corner the game gave, so a change of height moved them). A
-- window still at version 1's starting spot moves to the new one; a dragged
-- one stays where it was.
local OLD_SPOTS = {
  window = { point = "CENTER", relPoint = "CENTER", x = 0, y = 0 },
  popup = { point = "CENTER", relPoint = "CENTER", x = 0, y = 180 },
}
MIGRATIONS[1] = function(db)
  for key, old in pairs(OLD_SPOTS) do
    local w = db[key]
    if type(w) == "table" then
      if w.point == old.point and w.relPoint == old.relPoint and w.x == old.x and w.y == old.y then
        local d = DEFAULTS[key]
        w.point, w.relPoint, w.x, w.y = d.point, d.relPoint, d.x, d.y
      elseif type(w.point) == "string" and IsFinite(w.x) and IsFinite(w.y) then
        local size = ns.WINDOW_SIZE[key]
        ns.ToTopLeft(w, size[1], size[2])
      end
    end
  end
end

-- Runs on the table as it was loaded, before defaults are filled in, so a
-- step can still see an old shape.
local function Migrate(db)
  local v = db.dbVersion
  -- a table without a version: there's no older shape than 1, so it's 1
  if not IsFinite(v) then v = 1 end
  v = math.max(0, math.floor(v))
  while v < DB_VERSION do
    local step = MIGRATIONS[v]
    if step then step(db) end
    v = v + 1
  end
  -- (a newer PartySync saved this: its number is kept, nothing is thrown away)
  db.dbVersion = v
end

local function InitDB()
  if type(PartySyncDB) ~= "table" then PartySyncDB = {} end
  local db = PartySyncDB
  Migrate(db)
  MergeDefaults(db, DEFAULTS)
  FixTypes(db, DEFAULTS)
  Sanitize(db)
  ns.db = db
end
ns.InitDB = InitDB -- (tests call it on purpose-made tables)

-- Fold or unfold a quest in the panel, keeping the saved list small.
function ns.SetQuestCollapsed(questID, collapsed)
  local quests = ns.db and ns.db.collapsed.quests
  if not quests or not IsQuestID(questID) then return end
  if not collapsed then quests[questID] = nil return end
  if quests[questID] then return end
  local count, lowest = 0, nil
  for id in pairs(quests) do
    count = count + 1
    if not lowest or id < lowest then lowest = id end
  end
  if count >= ns.MAX_COLLAPSED then quests[lowest] = nil end
  quests[questID] = true
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------
local frame = CreateFrame("Frame")
ns.eventFrame = frame
local handlers = {}

-- Register fn for a game event. Several files can register the same event;
-- each handler runs under pcall, so one failing doesn't stop the others.
-- Events this client doesn't have are skipped (Forever runs the modern
-- client, which dropped some classic-era events).
function ns.RegisterEvent(event, fn)
  if not handlers[event] then
    if C_EventUtils and C_EventUtils.IsEventValid and not C_EventUtils.IsEventValid(event) then
      ns.Debug("event not on this client: " .. event)
      return false
    end
    local ok = pcall(frame.RegisterEvent, frame, event)
    if not ok then
      ns.Debug("event not on this client: " .. event)
      return false
    end
    handlers[event] = {}
  end
  table.insert(handlers[event], fn)
  return true
end

frame:SetScript("OnEvent", function(_, event, ...)
  local list = handlers[event]
  if not list then return end
  for _, fn in ipairs(list) do
    local ok, err = pcall(fn, ...)
    if not ok then ns.ReportError(event .. ": " .. tostring(err)) end
  end
end)

ns.RegisterEvent("ADDON_LOADED", function(name)
  if name ~= ADDON then return end
  InitDB()
  ns.Fire("DB_READY")
end)

ns.RegisterEvent("ZONE_CHANGED_NEW_AREA", function()
  ns.Fire("ZONE_CHANGED")
  ns.Fire("CHANGED")
end)

ns.RegisterEvent("PLAYER_LEVEL_UP", function()
  ns.Fire("LEVEL_UP")
  ns.Fire("CHANGED")
end)

-- the zone the player is in now ("" before it's known)
function ns.CurrentZone()
  local zone = GetRealZoneText and GetRealZoneText()
  if type(zone) ~= "string" or ns.IsSecret(zone) then return "" end
  -- (cut like quest log headings and Questie's zone names, so long names still match)
  return (ns.Wire and ns.Wire.CleanLocal(zone, ns.Wire.MAX_ZONE)) or zone
end

------------------------------------------------------------------------
-- Slash command: /psync or /partysync
------------------------------------------------------------------------
local function Line(text) DEFAULT_CHAT_FRAME:AddMessage("  " .. text) end

local function AddonState(m)
  if m.hasAddon == true then
    return "has PartySync" .. (m.version and (" " .. ns.Escape(m.version)) or "")
  elseif m.hasAddon == false then
    return "no PartySync"
  end
  return "PartySync not checked yet"
end

local function ColoredName(m)
  local r, g, b = 0.8, 0.8, 0.8
  if ns.ClassColor then r, g, b = ns.ClassColor(m.class) end
  local function Hex(v) return math.floor(math.max(0, math.min(1, v)) * 255 + 0.5) end
  return ("|cff%02x%02x%02x%s|r"):format(Hex(r), Hex(g), Hex(b), ns.Escape(m.name or "?"))
end

local function QuestLine(q)
  local parts = {}
  for _, o in ipairs(q.obj or {}) do parts[#parts + 1] = o.have .. "/" .. o.need end
  local progress = q.complete and "done" or (#parts > 0 and table.concat(parts, ", ") or "in progress")
  local zone = (q.zone and q.zone ~= "") and (" - " .. ns.Escape(q.zone)) or ""
  return ("[%d] %s%s: %s"):format(q.level or 0, ns.Escape(q.title), zone, progress)
end

function ns.PrintStatus()
  ns.Print("version " .. ns.VERSION)
  local G = ns.Group
  local mode = G and G.Mode() or "solo"
  if mode == "raid" then
    ns.Print("PartySync works in parties. It's paused while you're in a raid.")
  elseif mode == "solo" then
    ns.Print("You're not in a party.")
  else
    local list = G.SortedMembers()
    ns.Print(("Party members (%d):"):format(#list))
    for _, m in ipairs(list) do
      local note = ns.Comm and ns.Comm.StatusNote(m)
      Line(ColoredName(m) .. " - " .. AddonState(m) .. (note and (", " .. note) or ""))
    end
    if ns.Comm then Line(("Messages waiting to send: %d"):format(ns.Comm.QueueLength())) end
  end
  local mine = ns.mine
  local ids = mine and mine.list or {}
  ns.Print(("My quests (%d):"):format(#ids))
  for _, id in ipairs(ids) do
    local q = mine.quests[id]
    if q then Line(QuestLine(q)) end
  end
  if ns.QuestLog and ns.QuestLog.available == false then
    Line("(couldn't read your quest log on this client)")
  end
end

local function PrintHelp()
  ns.Print("/psync - open or close the panel / /psync status - your party and your quests / /psync sync - sync with your party again / /psync reset - put the panel back at the top of the screen / /psync minimap - show or hide the minimap button / /psync questie - Questie connection / /psync debug - extra lines for reporting problems")
end

SLASH_PARTYSYNC1 = "/psync"
SLASH_PARTYSYNC2 = "/partysync"
ns.SlashHandlers = {} -- extra /psync commands from other files: [word] = function(rest)
SlashCmdList.PARTYSYNC = function(msg)
  -- (plain ASCII only: string.lower and "%s" follow the game's language
  -- setting, and could change or cut letters with accents)
  msg = (msg or ""):gsub("[A-Z]", string.lower):gsub("^[ \t]+", ""):gsub("[ \t]+$", "")
  local word, rest = msg:match("^([^ \t]+)[ \t]*(.*)$")
  if word and ns.SlashHandlers[word] then return ns.SlashHandlers[word](rest or "") end
  if msg == "" then
    if ns.TogglePanel then ns.TogglePanel() else ns.Print("The panel is coming soon. Try /psync status for now.") end
  elseif msg == "status" then
    ns.Call(ns.PrintStatus)
  elseif msg == "debug" then
    -- (for this session only: extra chat lines, such as how party members'
    -- names were matched; useful when reporting a problem)
    ns.debug = not ns.debug
    ns.Print(ns.debug and "Debug lines on until you log out or /reload. /psync debug again turns them off."
      or "Debug lines off.")
  elseif msg == "questie" then
    if ns.QDB and ns.QDB.PrintStatus then ns.QDB.PrintStatus() else ns.Print("The Questie connection isn't built yet.") end
  else
    PrintHelp()
  end
end
