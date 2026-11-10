-- Wire: turning quests into addon messages and back, cleaning text, the size
-- limits and the checksum. Pure Lua with no WoW calls, so the tests can check
-- every line of it.
--
-- Every message is "<type><proto>^<payload>", proto = 1, at most 250 bytes:
--   H  "H1^<proto>^<version>"            I'm here (its layout never changes)
--   Q  "Q1^<quest>~<quest>~..."          whole quests only, never split
--        <quest> = id^level^flags^title^zone^h/n,h/n,...
--        flags: "c" complete, "p" can be shared ("cp", "c", "p" or "")
--   L  "L1^<sum>^<id36>,<id36>,..."      every quest I have now, plus the checksum
--   R  "R1^<targetGUID>"                 please resend everything
--   A  "A1^<questID>^<targetGUID>"       ask to share
--   a  "a1^<questID>^<askerGUID>^<code>" the answer: s shared, n not now,
--                                        x can't share, o requests turned off
-- Separators: fields "^", quests "~", objectives ",". "|" is never sent.
-- (The quest IDs in L are written in base 36, "lflr" for 999999, so 40 of
-- them always fit in one message; see DESIGN.md section 4 and the notes.)
--
-- A quest, as decoded here and as kept in ns.mine / ns.members (Group.lua):
--   { id = 33, level = 5, title = "Wolves Across the Border", zone = "Elwynn Forest",
--     complete = false, pushable = true,
--     obj = { { have = 3, need = 8 }, ... } }   -- at most 8 objectives
--   (our own quests also carry obj[i].text, which is never sent)
--
-- W.Decode(msg) returns kind, data, or nil, reason. data by kind:
--   H { proto, version }      Q { quests = { quest, ... } }   L { sum, ids = { id, ... } }
--   R { target }              A { questID, target }           a { questID, asker, code }

local _, ns = ...
local W = {}
ns.Wire = W

W.PROTO = 1
W.MAX_MSG = 250       -- bytes per message (the game allows 255)
W.MAX_TITLE = 60      -- bytes, cut on a whole UTF-8 character
W.MAX_ZONE = 40
W.MAX_OBJ = 8         -- objectives per quest
W.MAX_COUNT = 9999    -- objective counts 0 .. 9999
W.MAX_ID = 999999     -- quest IDs 1 .. 999999
W.MAX_LEVEL = 255     -- quest levels 0 .. 255
W.MAX_QUESTS = 40     -- quests per member
W.MAX_GUID = 40       -- bytes
W.CHECK_MOD = 16777213
W.ANSWERS = { s = true, n = true, x = true, o = true }

------------------------------------------------------------------------
-- Text
------------------------------------------------------------------------
-- control characters (bytes 0-31 and 127): never allowed in received text
function W.HasControl(s)
  return s:find("[%z\1-\31\127]") ~= nil
end

-- Cut s to at most maxBytes without splitting a character: a UTF-8 character
-- is one lead byte followed by "continuation" bytes (0x80-0xBF), so the cut
-- moves back until the next byte starts a new character.
function W.CutUTF8(s, maxBytes)
  if #s <= maxBytes then return s end
  local i = maxBytes
  while i > 0 do
    local b = s:byte(i + 1)
    if b < 0x80 or b >= 0xC0 then break end
    i = i - 1
  end
  return s:sub(1, i)
end

-- Only plain spaces are trimmed. ("%s" depends on the game's language
-- setting: in some it also matches byte 0xA0, the last byte of a-grave
-- (C3 A0) and of a no-break space (C2 A0), and trimming that byte leaves
-- broken text. Control characters, tabs included, are refused or made
-- spaces before any trimming.)
local function Trim(s) return (s:gsub("^ +", ""):gsub(" +$", "")) end

-- Is s well-formed UTF-8? Each character is one lead byte and the right
-- number of continuation bytes (0x80-0xBF); overlong forms, the UTF-16
-- surrogate range and anything past U+10FFFF don't count.
function W.ValidUTF8(s)
  local i, n = 1, #s
  while i <= n do
    local b = s:byte(i)
    local extra, lo, hi = 0, 0x80, 0xBF
    if b < 0x80 then extra = 0
    elseif b >= 0xC2 and b <= 0xDF then extra = 1
    elseif b >= 0xE0 and b <= 0xEF then
      extra = 2
      if b == 0xE0 then lo = 0xA0 elseif b == 0xED then hi = 0x9F end
    elseif b >= 0xF0 and b <= 0xF4 then
      extra = 3
      if b == 0xF0 then lo = 0x90 elseif b == 0xF4 then hi = 0x8F end
    else
      return false
    end
    for k = 1, extra do
      local c = s:byte(i + k)
      if not c then return false end
      if k == 1 then
        if c < lo or c > hi then return false end
      elseif c < 0x80 or c > 0xBF then
        return false
      end
    end
    i = i + extra + 1
  end
  return true
end

-- The same text with anything that isn't well-formed UTF-8 dropped, one bad
-- byte at a time (only for our own game text; a stranger's is refused instead)
function W.FixUTF8(s)
  if W.ValidUTF8(s) then return s end
  local out, i, n = {}, 1, #s
  while i <= n do
    local b = s:byte(i)
    local len = (b < 0x80 and 1) or (b >= 0xC2 and b <= 0xDF and 2) or (b >= 0xE0 and b <= 0xEF and 3)
      or (b >= 0xF0 and b <= 0xF4 and 4) or 0
    local piece = len > 0 and s:sub(i, i + len - 1) or ""
    if len > 0 and #piece == len and W.ValidUTF8(piece) then
      out[#out + 1] = piece
      i = i + len
    else
      i = i + 1
    end
  end
  return table.concat(out)
end

-- Invisible characters that can hide or reorder text: the zero-width ones
-- and the direction marks (U+200B-U+200F), the line and paragraph breaks and
-- the direction overrides (U+2028-U+202E), the word joiner, invisible maths
-- signs and direction isolates (U+2060-U+2069), and the byte order mark
-- (U+FEFF). They're never kept, in our own text or anyone else's.
local INVISIBLE_1 = "\226\128[\139-\143]" -- U+200B-U+200F
local INVISIBLE_2 = "\226\128[\168-\174]" -- U+2028-U+202E
local INVISIBLE_3 = "\226\129[\160-\169]" -- U+2060-U+2069
local INVISIBLE_4 = "\239\187\191"        -- U+FEFF
function W.StripInvisible(s)
  return (s:gsub(INVISIBLE_1, ""):gsub(INVISIBLE_2, ""):gsub(INVISIBLE_3, ""):gsub(INVISIBLE_4, ""))
end

-- Text that goes into a message: "|" (colour and link codes), our two
-- separators "^" and "~" and the invisible characters above are removed,
-- spaces trimmed, then cut to maxBytes. Returns nil for anything that isn't
-- a string, has control characters or isn't well-formed UTF-8.
-- Cleaning clean text changes nothing (both sides of the checksum rely on
-- that, and DecodeQuest refuses text that cleaning would change).
function W.CleanText(s, maxBytes)
  if type(s) ~= "string" or W.HasControl(s) or not W.ValidUTF8(s) then return nil end
  s = Trim(W.StripInvisible((s:gsub("[|%^~]", ""))))
  s = Trim(W.CutUTF8(s, maxBytes))
  -- (a last check: nothing above should ever break a character)
  if not W.ValidUTF8(s) then return nil end
  return s
end

-- The same for text from our own quest log: control characters become spaces
-- and broken UTF-8 is dropped, instead of failing (it's the game's text,
-- not a stranger's).
function W.CleanLocal(s, maxBytes)
  if type(s) ~= "string" then return nil end
  return W.CleanText(W.FixUTF8((s:gsub("[%z\1-\31\127]", " "))), maxBytes)
end

-- A quest log header that cleans to nothing (or a quest listed before any
-- header) gets this zone, because a sent quest's zone is never blank.
W.NO_ZONE = "Other quests"

-- "0.1.0" or "0.1.0-beta2": three numbers, then optionally "-" and 1 to 8
-- letters or digits; at most 20 bytes
function W.ValidVersion(v)
  if type(v) ~= "string" or #v > 20 then return false end
  local suffix = v:match("^%d+%.%d+%.%d+(.*)$")
  if not suffix then return false end
  if suffix == "" then return true end
  local tag = suffix:match("^%-([0-9A-Za-z]+)$")
  return tag ~= nil and #tag <= 8
end

------------------------------------------------------------------------
-- Numbers. Only one way to write each number is accepted ("7", never "07"),
-- so decoding and encoding again gives the same text (the checksum needs that).
------------------------------------------------------------------------
-- whole number from decimal text, within lo .. hi, or nil
function W.Int(s, lo, hi)
  if type(s) ~= "string" or #s > 8 or not s:match("^%d+$") then return nil end
  if #s > 1 and s:sub(1, 1) == "0" then return nil end
  local n = tonumber(s)
  if not n or n < lo or n > hi then return nil end
  return n
end

local DIGITS36 = "0123456789abcdefghijklmnopqrstuvwxyz"
function W.To36(n)
  if n == 0 then return "0" end
  local out = ""
  while n > 0 do
    local d = n % 36
    out = DIGITS36:sub(d + 1, d + 1) .. out
    n = (n - d) / 36
  end
  return out
end

-- whole number from base-36 text (lower case), within lo .. hi, or nil
function W.From36(s, lo, hi)
  if type(s) ~= "string" or #s > 6 or not s:match("^[0-9a-z]+$") then return nil end
  if #s > 1 and s:sub(1, 1) == "0" then return nil end
  local n = tonumber(s, 36)
  if not n or n < lo or n > hi then return nil end
  return n
end

local function IsInt(n, lo, hi)
  return type(n) == "number" and n == math.floor(n) and n >= lo and n <= hi
end

-- "a^b^^c" -> { "a", "b", "", "c" } (empty fields kept; sep is one plain character)
local function Split(s, sep)
  local out, start = {}, 1
  while true do
    local i = s:find(sep, start, true)
    if not i then out[#out + 1] = s:sub(start) return out end
    out[#out + 1] = s:sub(start, i - 1)
    start = i + 1
  end
end
W.Split = Split

-- GUIDs look like "Player-4372-0A1B2C3D". Only the start is checked, so a
-- small change in the format on Forever doesn't break everything.
function W.ValidGUID(s)
  return type(s) == "string" and #s <= W.MAX_GUID and s:match("^Player%-[0-9A-Za-z%-]+$") ~= nil
end

------------------------------------------------------------------------
-- Quests
------------------------------------------------------------------------
-- is a quest table one we can send? (all limits checked)
function W.ValidQuest(q)
  if type(q) ~= "table" then return false end
  if not IsInt(q.id, 1, W.MAX_ID) or not IsInt(q.level, 0, W.MAX_LEVEL) then return false end
  if type(q.title) ~= "string" or q.title == "" or W.CleanText(q.title, W.MAX_TITLE) ~= q.title then return false end
  if type(q.zone) ~= "string" or q.zone == "" or W.CleanText(q.zone, W.MAX_ZONE) ~= q.zone then return false end
  if type(q.obj) ~= "table" or #q.obj > W.MAX_OBJ then return false end
  for _, o in ipairs(q.obj) do
    if type(o) ~= "table" or not IsInt(o.have, 0, W.MAX_COUNT) or not IsInt(o.need, 0, W.MAX_COUNT) then return false end
  end
  return true
end

-- the canonical text of one quest (what's sent, and what the checksum reads),
-- or nil if the quest breaks a limit
function W.EncodeQuest(q)
  if not W.ValidQuest(q) then return nil end
  local objs = {}
  for i, o in ipairs(q.obj) do objs[i] = o.have .. "/" .. o.need end
  local flags = (q.complete and "c" or "") .. (q.pushable and "p" or "")
  return table.concat({ q.id, q.level, flags, q.title, q.zone, table.concat(objs, ",") }, "^")
end

-- one "<quest>" back into a table, or nil, reason
function W.DecodeQuest(s)
  local f = Split(s, "^")
  if #f ~= 6 then return nil, "fields" end
  local id = W.Int(f[1], 1, W.MAX_ID)
  local level = W.Int(f[2], 0, W.MAX_LEVEL)
  if not id or not level then return nil, "number" end
  local flags = f[3]
  if flags ~= "" and flags ~= "c" and flags ~= "p" and flags ~= "cp" then return nil, "flags" end
  -- (text exactly as our own cleaning leaves it: not blank, nothing cleaning
  -- would remove or cut, well-formed UTF-8, no invisible characters)
  local title, zone = f[4], f[5]
  if title == "" or zone == "" or W.CleanText(title, W.MAX_TITLE) ~= title
    or W.CleanText(zone, W.MAX_ZONE) ~= zone then return nil, "text" end
  local obj = {}
  if f[6] ~= "" then
    local parts = Split(f[6], ",")
    if #parts > W.MAX_OBJ then return nil, "objectives" end
    for i, p in ipairs(parts) do
      local h, n = p:match("^(%d+)/(%d+)$")
      h, n = W.Int(h, 0, W.MAX_COUNT), W.Int(n, 0, W.MAX_COUNT)
      if not h or not n then return nil, "count" end
      obj[i] = { have = h, need = n }
    end
  end
  return {
    id = id, level = level, title = title, zone = zone,
    complete = flags:find("c", 1, true) ~= nil, pushable = flags:find("p", 1, true) ~= nil,
    obj = obj,
  }
end

-- the IDs of a { [id] = quest } table, lowest first
function W.SortedIDs(quests)
  local ids = {}
  for id in pairs(quests) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end

-- Checksum of a { [id] = quest } table: each quest's canonical text, in ID
-- order, fed byte by byte into s = (s * 31 + byte) % 16777213. (The biggest
-- value along the way is about 5.2e8, well inside what a Lua number holds exactly.)
function W.Checksum(quests)
  local s = 0
  for _, id in ipairs(W.SortedIDs(quests)) do
    local text = W.EncodeQuest(quests[id]) or ""
    for i = 1, #text do s = (s * 31 + text:byte(i)) % W.CHECK_MOD end
  end
  return s
end

------------------------------------------------------------------------
-- Messages
------------------------------------------------------------------------
local function Frame(kind, payload)
  local msg = kind .. W.PROTO .. "^" .. payload
  if #msg > W.MAX_MSG then return nil end
  return msg
end

function W.EncodeHello(version)
  if not W.ValidVersion(version) then return nil end
  return Frame("H", W.PROTO .. "^" .. version)
end

-- sum: our checksum, ids: every quest ID we have (at most 40)
function W.EncodeList(sum, ids)
  if not IsInt(sum, 0, W.CHECK_MOD - 1) or #ids > W.MAX_QUESTS then return nil end
  local parts = {}
  for i, id in ipairs(ids) do
    if not IsInt(id, 1, W.MAX_ID) then return nil end
    parts[i] = W.To36(id)
  end
  return Frame("L", sum .. "^" .. table.concat(parts, ","))
end

-- Pack quests (an array of quest tables) into as few Q messages as fit,
-- whole quests only, lowest ID first. Quests that break a limit are left out.
function W.PackQuests(quests)
  local list = {}
  for _, q in ipairs(quests) do list[#list + 1] = q end
  table.sort(list, function(a, b) return (tonumber(a.id) or 0) < (tonumber(b.id) or 0) end)
  local head = "Q" .. W.PROTO .. "^"
  local msgs, cur = {}, nil
  for _, q in ipairs(list) do
    local text = W.EncodeQuest(q)
    if text then
      if cur and #cur + 1 + #text <= W.MAX_MSG then
        cur = cur .. "~" .. text
      else
        if cur then msgs[#msgs + 1] = cur end
        cur = head .. text -- (one quest is at most about 200 bytes, so it always fits)
      end
    end
  end
  if cur then msgs[#msgs + 1] = cur end
  return msgs
end

function W.EncodeResend(targetGUID)
  if not W.ValidGUID(targetGUID) then return nil end
  return Frame("R", targetGUID)
end

function W.EncodeAsk(questID, targetGUID)
  if not IsInt(questID, 1, W.MAX_ID) or not W.ValidGUID(targetGUID) then return nil end
  return Frame("A", questID .. "^" .. targetGUID)
end

function W.EncodeAnswer(questID, askerGUID, code)
  if not IsInt(questID, 1, W.MAX_ID) or not W.ValidGUID(askerGUID) or not W.ANSWERS[code] then return nil end
  return Frame("a", questID .. "^" .. askerGUID .. "^" .. code)
end

------------------------------------------------------------------------
-- Decoding. Everything received is a stranger's text: anything that doesn't
-- match exactly is dropped.
------------------------------------------------------------------------
local decoders = {}

decoders.H = function(p)
  local f = Split(p, "^")
  if #f ~= 2 then return nil, "fields" end
  local proto = W.Int(f[1], 1, 999)
  local version = f[2]
  if not proto or not W.ValidVersion(version) then return nil, "hello" end
  return { proto = proto, version = version }
end

-- Quests that break a limit are dropped one by one; the rest are kept.
decoders.Q = function(p)
  local quests, seen = {}, {}
  for _, s in ipairs(Split(p, "~")) do
    local q = W.DecodeQuest(s)
    if q and not seen[q.id] and #quests < W.MAX_QUESTS then
      seen[q.id] = true
      quests[#quests + 1] = q
    end
  end
  if #quests == 0 then return nil, "no quests" end
  return { quests = quests }
end

-- The list is all or nothing: a bad ID or a repeat drops the message.
-- More than 40 IDs: only the first 40 count.
decoders.L = function(p)
  local f = Split(p, "^")
  if #f ~= 2 then return nil, "fields" end
  local sum = W.Int(f[1], 0, W.CHECK_MOD - 1)
  if not sum then return nil, "sum" end
  local ids, seen = {}, {}
  if f[2] ~= "" then
    for _, s in ipairs(Split(f[2], ",")) do
      local id = W.From36(s, 1, W.MAX_ID)
      if not id or seen[id] then return nil, "id" end
      seen[id] = true
      if #ids < W.MAX_QUESTS then ids[#ids + 1] = id end
    end
  end
  return { sum = sum, ids = ids }
end

decoders.R = function(p)
  if not W.ValidGUID(p) then return nil, "guid" end
  return { target = p }
end

decoders.A = function(p)
  local f = Split(p, "^")
  if #f ~= 2 then return nil, "fields" end
  local id = W.Int(f[1], 1, W.MAX_ID)
  if not id or not W.ValidGUID(f[2]) then return nil, "ask" end
  return { questID = id, target = f[2] }
end

decoders.a = function(p)
  local f = Split(p, "^")
  if #f ~= 3 then return nil, "fields" end
  local id = W.Int(f[1], 1, W.MAX_ID)
  if not id or not W.ValidGUID(f[2]) or not W.ANSWERS[f[3]] then return nil, "answer" end
  return { questID = id, asker = f[2], code = f[3] }
end

-- One received message -> kind, data, or nil, reason.
-- Checks: a string of at most 250 bytes; every "|" removed; no control
-- characters; a known type; our protocol (H is read whatever its protocol).
function W.Decode(msg)
  if type(msg) ~= "string" then return nil, "type" end
  if #msg > W.MAX_MSG then return nil, "size" end
  msg = msg:gsub("|", "")
  if W.HasControl(msg) then return nil, "control" end
  local kind, proto, payload = msg:match("^([A-Za-z])(%d+)%^(.*)$")
  local decode = kind and decoders[kind]
  if not decode then return nil, "kind" end
  proto = W.Int(proto, 1, 999)
  if not proto then return nil, "proto" end
  if kind ~= "H" and proto ~= W.PROTO then return nil, "proto" end
  local data, why = decode(payload)
  if not data then return nil, why end
  return kind, data
end
