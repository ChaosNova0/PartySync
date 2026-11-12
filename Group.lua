-- Group: who's in the party. Everyone is keyed by GUID (the game's fixed ID
-- for a character), never by name, because names can be spelled several ways.
--
--   ns.members[guid] = {            -- the OTHER party members (never us)
--     guid, unit = "party2", name = "Carol Stone", class = "MAGE",
--     hasAddon = nil | true | false,  -- nil: not known yet (Comm.lua decides)
--     proto, version, lastHeard,      -- from their hello (Comm.lua)
--     listSum, list = { id, ... },    -- their latest L message (Comm.lua)
--     quests = { [id] = quest },      -- quest shape: see Wire.lua
--   }
--   ns.mine = the same shape for us; QuestLog.lua fills in quests / list / listSum.
--   G.alias[spelling] = guid, or false when two people share that spelling.
--     Spellings come from UnitName: "n", "n-r", "n r", "n-MyRealm", "n r-MyRealm".
--     Addon messages name their sender one of these ways (which one Forever
--     uses needs an in-game check), so G.Lookup(sender) tries the exact text.
--     Our own spellings are in the table too, so a party member whose
--     spelling matches ours is ambiguous and never found.
--   G.lower[spelling:lower()] and G.first[first name, lower case] work the
--     same way, for when the exact text doesn't match (see G.Lookup).
--   G.Mode() = "solo" (not in a group), "party", or "raid". In a raid
--     PartySync pauses: ns.members is empty and nothing is sent.
--
-- Names are never split on spaces: Forever names can have a last name
-- ("Carol Stone"), which the game may give where the realm would go.

local _, ns = ...
local G = {}
ns.Group = G

ns.members = {}
G.alias = {}
G.lower = {}
G.first = {}
G.self = {}   -- [our spelling:lower()] = true (our own messages come back to us)
G.NAME_RETRY = 2     -- seconds between looks while a member's name is unknown
G.NAME_RETRIES = 30  -- ...for at most this many looks in a row
local mode = "solo"
local myGuid
local unknownName = false -- a member's name was unknown at the last rebuild
local nameRetries = 0

-- an empty member record (Comm.lua fills in the rest as messages arrive)
function G.NewMember(guid)
  return { guid = guid, quests = {}, list = {}, listSum = nil }
end

ns.mine = G.NewMember(nil)
ns.mine.listSum = 0

------------------------------------------------------------------------
-- Names and colours (from an earlier addon)
------------------------------------------------------------------------
function ns.MyRealm()
  local realm = GetNormalizedRealmName and GetNormalizedRealmName()
  if type(realm) ~= "string" or ns.IsSecret(realm) or realm == "" then
    -- (plain spaces and dashes: "%s" follows the language setting)
    realm = ((GetRealmName and GetRealmName()) or ""):gsub("[ \t%-]", "")
  end
  return realm
end

function ns.ClassColor(classFile)
  local c = classFile and ((C_ClassColor and C_ClassColor.GetClassColor(classFile))
    or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]))
  if c then return c.r, c.g, c.b end
  return 0.8, 0.8, 0.8
end

-- UnitName's two parts, or nil if the game won't tell us (yet)
local function NameParts(unit)
  local n, r = UnitName(unit)
  if ns.IsSecret(n) or ns.IsSecret(r) then return nil end
  if type(n) ~= "string" or n == "" or n == UNKNOWNOBJECT then return nil end
  if type(r) ~= "string" then r = nil end
  if r == "" then r = nil end
  return n, r
end

-- How to show a name: "n r" when the second part isn't our realm (Forever
-- puts a last name there; an earlier addon's logic), otherwise just "n".
function G.DisplayName(n, r)
  if r and r ~= ns.MyRealm() then return n .. " " .. r end
  return n
end

-- every spelling the game may use for this name
local function Spellings(n, r)
  local realm = ns.MyRealm()
  local list = { n }
  if r then
    list[#list + 1] = n .. "-" .. r
    list[#list + 1] = n .. " " .. r
    if realm ~= "" then list[#list + 1] = n .. " " .. r .. "-" .. realm end
  end
  if realm ~= "" then list[#list + 1] = n .. "-" .. realm end
  return list
end

-- The first name, in lower case: the text before any "-", then its first
-- word ("Carol Stone-Forever" -> "carol"). Only used to match a
-- sender to a party member when nothing exact does; names are never split
-- for anything else.
local function FirstName(s)
  local base = s:match("^([^%-]+)") or s
  return (base:match("^(%S+)") or base):lower()
end

-- t[key] = guid, or false once two people share the key
local function Claim(t, key, guid)
  local cur = t[key]
  if cur == nil then t[key] = guid
  elseif cur ~= guid then t[key] = false end
end

------------------------------------------------------------------------
-- Building the roster
------------------------------------------------------------------------
local function Wipe(t) for k in pairs(t) do t[k] = nil end end

-- (in place, so anything holding ns.members sees the change)
local function ClearMembers()
  local removed = {}
  for guid in pairs(ns.members) do removed[#removed + 1] = guid end
  Wipe(ns.members)
  Wipe(G.alias)
  Wipe(G.lower)
  Wipe(G.first)
  Wipe(G.self)
  return removed
end

-- our own GUID, name and class into ns.mine
local function UpdateMe()
  local guid = UnitGUID("player")
  if guid and not ns.IsSecret(guid) then myGuid = guid end
  ns.mine.guid = myGuid
  local n, r = NameParts("player")
  if n then ns.mine.name = G.DisplayName(n, r) end
  local _, classFile = UnitClass("player")
  if type(classFile) == "string" and not ns.IsSecret(classFile) then ns.mine.class = classFile end
  return n, r
end

-- Works out the party again from the game. Fires "ROSTER_CHANGED" (added,
-- removed: arrays of GUIDs) when anyone joined or left, or the mode changed.
function G.Rebuild()
  local myN, myR = UpdateMe()
  local oldMode = mode
  local added, removed = {}, {}
  local renamed = false -- a name or online/offline changed: redraw

  if IsInRaid() then
    mode = "raid"
    unknownName = false
    removed = ClearMembers()
  elseif not IsInGroup() then
    mode = "solo"
    unknownName = false
    removed = ClearMembers()
  else
    mode = "party"
    local seen, spellings = {}, {}
    unknownName = false
    for i = 1, 4 do
      local unit = "party" .. i
      local guid = UnitGUID(unit)
      if guid and not ns.IsSecret(guid) and guid ~= myGuid and not seen[guid] then
        seen[guid] = true
        local m = ns.members[guid]
        if not m then
          m = G.NewMember(guid)
          ns.members[guid] = m
          added[#added + 1] = guid
        end
        m.unit = unit
        local n, r = NameParts(unit)
        if n then
          local name = G.DisplayName(n, r)
          if m.name ~= name then renamed = true end
          m.name = name
          spellings[guid] = Spellings(n, r)
        else
          -- (the game hasn't told us their name yet: their messages can't be
          -- matched to them until it does, so we look again soon)
          unknownName = true
        end
        m.name = m.name or "?"
        local _, classFile = UnitClass(unit)
        if type(classFile) == "string" and not ns.IsSecret(classFile) then m.class = classFile end
        -- (Model.lua asks the game whether they're online when it draws;
        -- this only notices the change so the panel is drawn again)
        local on = UnitIsConnected and UnitIsConnected(unit)
        if not ns.IsSecret(on) then
          on = on ~= false
          if m.online ~= nil and m.online ~= on then renamed = true end
          m.online = on
        end
      end
    end
    for guid in pairs(ns.members) do
      if not seen[guid] then
        ns.members[guid] = nil
        removed[#removed + 1] = guid
      end
    end
    -- the alias table, from scratch: a spelling two people share points to
    -- neither (false). Our own spellings take part, then are forgotten.
    Wipe(G.alias)
    Wipe(G.lower)
    Wipe(G.first)
    Wipe(G.self)
    local me = myGuid or "player"
    if myN then
      spellings[me] = Spellings(myN, myR)
      for _, s in ipairs(spellings[me]) do G.self[s:lower()] = true end
    else
      unknownName = true -- (our own name: needed to rule ourselves out)
    end
    for guid, list in pairs(spellings) do
      for _, s in ipairs(list) do
        Claim(G.alias, s, guid)
        Claim(G.lower, s:lower(), guid)
      end
      Claim(G.first, FirstName(list[1]), guid)
    end
    for _, t in ipairs({ G.alias, G.lower, G.first }) do
      for s, guid in pairs(t) do
        if guid == me then t[s] = false end
      end
    end
  end

  table.sort(added)
  table.sort(removed)
  if #added > 0 or #removed > 0 or mode ~= oldMode then
    ns.Fire("ROSTER_CHANGED", added, removed)
    ns.Fire("CHANGED")
  elseif renamed then
    ns.Fire("CHANGED")
  end
  -- someone's name is still unknown: look again in a moment (UNIT_NAME_UPDATE
  -- usually comes first; this is in case it doesn't). At most a minute of
  -- tries, counted again from zero whenever someone joins (a newcomer gets
  -- their own minute, even if an earlier one used it all up).
  if #added > 0 then nameRetries = 0 end
  if unknownName and nameRetries < G.NAME_RETRIES then
    nameRetries = nameRetries + 1
    ns.Coalesce("rosterName", G.NAME_RETRY, G.Rebuild)
  elseif not unknownName then
    nameRetries = 0
  end
  return added, removed
end

------------------------------------------------------------------------
-- Looking people up
------------------------------------------------------------------------
-- "solo", "party" or "raid"
function G.Mode() return mode end

-- true while PartySync is paused (in a raid)
function G.IsPaused() return mode == "raid" end

-- true when there's a party to sync with
function G.Active() return mode == "party" end

function G.MyGUID() return myGuid end

-- an addon message's sender -> the GUID of exactly one party member who
-- isn't us, or nil (unknown, ambiguous, or us). Tried in order:
--   exact       one of the spellings above, letter for letter
--   any case    the same, ignoring capital letters
--   first name  the sender's first name belongs to exactly one person in
--               the party (us included). This covers the game naming the
--               sender in a way we didn't expect, e.g. "Carol-Forever"
--               when UnitName gave "Carol Stone" as one piece.
-- Only party members can send on the PARTY channel, so a loose match can
-- only pick between the people in the party, and so the loose steps are
-- only tried when we know everyone in it (see Settled). Whenever a step
-- finds a shared spelling (false), it stops there: we can't tell who it was.
-- Returns guid, how ("exact" / "case" / "first"); or nil, "self" for one of
-- our own spellings.
local function Settled()
  if mode ~= "party" or unknownName then return false end
  if ns.IsPending("roster") or ns.IsPending("rosterName") then return false end
  -- (someone the game already lists but our last rebuild didn't see yet)
  local n, members = 0, 0
  for i = 1, 4 do
    local guid = UnitGUID("party" .. i)
    if guid and not ns.IsSecret(guid) and guid ~= myGuid then n = n + 1 end
  end
  for _ in pairs(ns.members) do members = members + 1 end
  return n == members
end

function G.Lookup(sender)
  if type(sender) ~= "string" or ns.IsSecret(sender) or sender == "" then return nil end
  local guid, how = G.alias[sender], "exact"
  if guid == nil and Settled() then
    guid, how = G.lower[sender:lower()], "case"
    if guid == nil then guid, how = G.first[FirstName(sender)], "first" end
  end
  if not guid and G.self[sender:lower()] then return nil, "self" end
  if not guid or guid == myGuid then return nil end
  if not ns.members[guid] then return nil end
  return guid, how
end

-- the other members, sorted by name (for the party strip and /psync status)
function G.SortedMembers()
  local list = {}
  for _, m in pairs(ns.members) do list[#list + 1] = m end
  table.sort(list, function(a, b)
    local an, bn = a.name or "", b.name or ""
    if an ~= bn then return an < bn end
    return a.guid < b.guid
  end)
  return list
end

------------------------------------------------------------------------
-- Events: the roster settles 1 s after the last change
------------------------------------------------------------------------
local function Soon() ns.Coalesce("roster", 1, G.Rebuild) end

ns.RegisterEvent("PLAYER_LOGIN", G.Rebuild)
ns.RegisterEvent("PLAYER_ENTERING_WORLD", G.Rebuild)
ns.RegisterEvent("GROUP_ROSTER_UPDATE", Soon)
-- a party member's name arrived or changed (skipped if this client doesn't
-- have the event: the retry above still finds it)
ns.RegisterEvent("UNIT_NAME_UPDATE", function(unit)
  if type(unit) == "string" and not ns.IsSecret(unit) and unit:match("^party%d$") then Soon() end
end)
-- a party member went offline or came back (redraws the "(offline)" label;
-- skipped like the one above if this client doesn't have the event)
ns.RegisterEvent("UNIT_CONNECTION", function(unit)
  if type(unit) == "string" and not ns.IsSecret(unit) and unit:match("^party%d$") then Soon() end
end)
