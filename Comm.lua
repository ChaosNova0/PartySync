-- Comm: talking to the rest of the party over the hidden PARTY addon
-- channel. Sending (a queue with a throttle), deciding when to send, and
-- checking and storing everything we hear. Message formats are in Wire.lua.
--
-- The send queue holds *what needs sending*, not finished messages. Each
-- message is built from our quest log as it is at the moment it goes out:
--   directed      { { kind = "R" | "A" | "a", ... }, ... }   (at most 20)
--   helloPending  true: send H
--   fullPending   true: every quest we have needs sending
--   dirty         { [questID] = true }: these quests need sending
--   listPending   true: send L
-- Priority: directed, then H, then Q, then L. A token bucket (5 tokens, 1 more
-- each second, checked every 0.25 s) keeps us under the game's limits, and
-- nothing goes out during a boss fight (normal combat is fine).
--
-- What we keep about each party member (ns.members[guid], see Group.lua):
--   hasAddon  true once we hear anything valid from them; false when they
--             never answered within 10 s of our H; nil before that
--   proto, version   from their H
--   lastHeard        GetTime() of their last valid message
--   list, listSum    their latest L (quest IDs, checksum)
--   quests           { [id] = quest } from their Q messages; anything their
--                    L doesn't list is removed (so at most 40, but up to 80
--                    for a moment between a Q and the L after it)
--
-- When we send:
--   full sync (H + every Q + L): 4 s after logging in or /reload in a party
--     (other loading screens send just L), 2 s after someone joins, 2 s after
--     a member's H (not within 15 s of our last full sync, and full syncs
--     started by an H are at least 30 s apart)
--   changes: the changed Qs, then L, 1 s after the last change (never more than 3 s)
--   heartbeat: L every 60 s (every 240 s when nobody seems to have PartySync)
--   R ("please resend everything"): when their L doesn't match what we hold,
--     at most once per 30 s per member. Only the member it names answers,
--     and it answers each member's R at most once per 25 s.
-- In a raid, or on our own, nothing is sent and nothing is read.
--
-- Callback bus events fired here:
--   "CHANGED"                                   a member's data changed
--   "PARTY_QUESTS_CHANGED"                      a member's quest IDs changed
--   "SHARE_ASKED"    (askerGUID, questID)        someone asks us to share a quest
--   "SHARE_ANSWERED" (fromGUID, questID, code)   the answer to our ask
--                    code: "s" shared, "n" not now, "x" can't share, "o" asks turned off

local _, ns = ...
local C = {}
ns.Comm = C
local W, G = ns.Wire, ns.Group

C.PREFIX = "PartySync"
C.MAX_TOKENS = 5
C.REFILL = 1          -- tokens per second
C.PUMP = 0.25         -- seconds between queue checks
C.HEARTBEAT = 60      -- seconds between L heartbeats
C.SLOW_HEARTBEAT = 240 -- ...when nobody in the party seems to have PartySync
C.FULL_GAP = 5        -- seconds between any two full syncs
C.HELLO_GAP = 15      -- no full sync for an H within 15 s of our last full sync...
C.HELLO_FULL_GAP = 30 -- ...and full syncs started by an H are at least 30 s apart
C.NO_ADDON_WAIT = 10  -- seconds after our H before a silent member counts as "no PartySync"
C.RESEND_GAP = 30     -- seconds between two R messages to the same member
C.ANSWER_R_GAP = 10   -- seconds between two resends because of an R
C.ANSWER_R_EACH = 25  -- an R from the same member is answered at most once per 25 s
                      -- (under RESEND_GAP, so a real R that took longer to
                      -- arrive than the one before it is still answered)
C.FLOOD_COUNT = 30    -- more than 30 messages...
C.FLOOD_WINDOW = 10   -- ...in 10 s...
C.FLOOD_BLOCK = 30    -- ...and we ignore that sender for 30 s
C.ASK_REPEAT = 60     -- the same ask (asker + quest) is ignored for 60 s
C.ASK_MAX = 5         -- at most 5 asks a minute, from everyone together
C.MAX_DIRECTED = 20
C.MAX_HELD = 80       -- quests held per member for a moment (see handlers.Q)
C.SYNC_GAP = 30       -- /psync sync at most once per 30 s

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------
local function Wipe(t) for k in pairs(t) do t[k] = nil end end

local queue = { directed = {}, dirty = {}, helloPending = false, fullPending = false, listPending = false }
C.queue = queue -- (read by the tests and /psync status)

local tokens, lastRefill = C.MAX_TOKENS, 0
local retries = 0           -- the game said "too fast" this many times in a row
local ticker                -- the queue pump, running only while in a party
local lastFullAt            -- when our last full sync started
local fullDueAt             -- when the next planned full sync starts (nil: none planned)
local lastListAt = 0        -- when our last L went out
local lastAnswerRAt         -- when we last resent everything because of an R
local lastHelloFullAt       -- when a member's H last started a full sync
local answerRDue = false    -- a resend for an R is waiting for its turn
local lastSyncCommand       -- when /psync sync was last used
local changedIDs = {}       -- quest IDs changed since the last send (waiting for the 1 s debounce)

local flood = {}            -- [guid] = { start, count, blockedUntil }
local resendAskedAt = {}    -- [guid] = when we last sent them an R
local resendAnsweredAt = {} -- [guid] = when we last answered their R
local askSeen = {}          -- ["asker:questID"] = when that ask came in
local askTimes = {}         -- when each ask in the last minute came in (any asker)
local limitTimes = {}       -- when we answered "n" because of that limit (last minute)
local myAsks = {}           -- ["target:questID"] = when we asked them
local joinedAt = {}         -- [guid] = when they joined (as far as we know)

local function Now() return GetTime() end

-- when this member joined (as far as we know), or nil (Model.lua's alert uses it)
function C.JoinedAt(guid) return joinedAt[guid] end

local function ClearQueue()
  Wipe(queue.directed)
  Wipe(queue.dirty)
  Wipe(changedIDs)
  queue.helloPending, queue.fullPending, queue.listPending = false, false, false
  fullDueAt, answerRDue = nil, false
end

-- how many messages are waiting (about: one quest is counted as one message)
function C.QueueLength()
  local n = #queue.directed
  if queue.helloPending then n = n + 1 end
  if queue.fullPending then
    n = n + #ns.mine.list
  else
    for _ in pairs(queue.dirty) do n = n + 1 end
  end
  if queue.listPending then n = n + 1 end
  return n
end

------------------------------------------------------------------------
-- Sending one message (result handling from an earlier addon's SendRaw)
------------------------------------------------------------------------
-- returns "ok", "retry" (the game says too fast: try again later) or "drop"
local function SendRaw(msg)
  if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return "drop" end
  local ok, res = pcall(C_ChatInfo.SendAddonMessage, C.PREFIX, msg, "PARTY")
  if not ok then
    ns.Debug("send error: " .. tostring(res))
    return "drop"
  end
  if res == nil or res == true or res == 0 then return "ok" end
  if res == false then return "retry" end
  local E = Enum and Enum.SendAddonMessageResult
  if E and (res == E.AddonMessageThrottle or res == E.ChannelThrottle or res == E.GeneralError) then
    return "retry"
  end
  ns.Debug("send refused, code " .. tostring(res))
  return "drop"
end

-- a boss fight is going on: sending waits (normal combat doesn't count)
local function Paused()
  return IsEncounterInProgress ~= nil and IsEncounterInProgress() and true or false
end

------------------------------------------------------------------------
-- Building the next message from the queue
------------------------------------------------------------------------
local function BuildDirected(d)
  if d.kind == "R" then return W.EncodeResend(d.target) end
  if d.kind == "A" then return W.EncodeAsk(d.questID, d.target) end
  if d.kind == "a" then return W.EncodeAnswer(d.questID, d.asker, d.code) end
end

-- the quest IDs inside a Q message ("Q1^33^5^...~46^7^...")
local function IDsIn(msg)
  local ids = {}
  for _, part in ipairs(W.Split(msg:sub(4), "~")) do
    ids[#ids + 1] = tonumber(part:match("^(%d+)%^"))
  end
  return ids
end

-- the first Q message for the quests waiting to be sent, and the IDs in it
local function NextQuestMessage()
  if queue.fullPending then
    for _, id in ipairs(ns.mine.list) do queue.dirty[id] = true end
    queue.fullPending = false
  end
  local list = {}
  for id in pairs(queue.dirty) do
    local q = ns.mine.quests[id]
    -- (a quest we no longer have: the L that follows says so)
    if q and W.EncodeQuest(q) then list[#list + 1] = q else queue.dirty[id] = nil end
  end
  if #list == 0 then return nil end
  local msg = W.PackQuests(list)[1]
  return msg, IDsIn(msg)
end

-- The next message to send: kind, msg, and a function that takes it off the
-- queue once it's gone. nil when there's nothing to send now.
local function NextMessage()
  local d = queue.directed[1]
  if d then
    return d.kind, BuildDirected(d), function() table.remove(queue.directed, 1) end
  end
  if queue.helloPending then
    return "H", W.EncodeHello(ns.VERSION), function() queue.helloPending = false end
  end
  local msg, ids = NextQuestMessage()
  if msg then
    return "Q", msg, function() for _, id in ipairs(ids) do queue.dirty[id] = nil end end
  end
  -- (L waits while a change is still settling, so it never carries a
  -- checksum for quests the others haven't been sent yet)
  if queue.listPending and not ns.IsPending("send") then
    return "L", W.EncodeList(ns.mine.listSum, ns.mine.list), function() queue.listPending = false end
  end
end

------------------------------------------------------------------------
-- Members without PartySync
------------------------------------------------------------------------
-- (helloAt: when our H went out. Only members who were already there then
-- are judged; anyone who joined later gets our next H.)
local function CheckNoAddon(helloAt)
  local changed = false
  for guid, m in pairs(ns.members) do
    if m.hasAddon == nil and not m.lastHeard and (joinedAt[guid] or 0) <= helloAt then
      m.hasAddon = false
      changed = true
    end
  end
  if changed then ns.Fire("CHANGED") end
end

-- Our H went out, or the game wouldn't take it and we gave up: either way,
-- 10 s later anyone we still haven't heard from counts as having no
-- PartySync. (Otherwise one refused H left them "maybe" all session, and
-- the done alert waited for them.) Hearing anything from them later still
-- makes them count again.
local function HelloDone(at)
  ns.After(C.NO_ADDON_WAIT, function() CheckNoAddon(at) end)
end

-- is anyone in the party (possibly) running PartySync?
local function AnyListener()
  for _, m in pairs(ns.members) do
    if m.hasAddon ~= false then return true end
  end
  return false
end

------------------------------------------------------------------------
-- The pump: runs every 0.25 s while we're in a party
------------------------------------------------------------------------
local function Pump()
  if not G.Active() then ClearQueue() return end
  local now = Now()
  tokens = math.min(C.MAX_TOKENS, tokens + (now - lastRefill) * C.REFILL)
  lastRefill = now
  -- the heartbeat: our list again, so anyone who missed something notices.
  -- (Slower when nobody seems to have PartySync: someone we couldn't hear,
  -- say because the game hadn't told us their name yet, still finds us.)
  local beat = AnyListener() and C.HEARTBEAT or C.SLOW_HEARTBEAT
  if now - lastListAt >= beat then queue.listPending = true end
  if Paused() then return end
  while tokens >= 1 do
    local kind, msg, done = NextMessage()
    if not kind then break end
    if not msg then
      -- (can't be built, for example a GUID that isn't valid: just drop it)
      done()
    else
      local result = SendRaw(msg)
      -- (the heartbeat clock counts tries, not only successes: a list the game
      -- keeps refusing would otherwise be tried again every second)
      if kind == "L" then lastListAt = now end
      if result == "retry" then
        retries = retries + 1
        -- (the game keeps refusing: give up on this one)
        if retries > 10 then
          done()
          retries = 0
          if kind == "H" then HelloDone(now) end
        end
        tokens = 0
        return
      end
      retries = 0
      done()
      tokens = tokens - 1
      if kind == "H" then HelloDone(now) end
    end
  end
end

local function StartPump()
  if ticker then return end
  -- (the heartbeat clock starts again too: a list sent before our H would
  -- only make the others ask for a resend the full sync is about to give)
  tokens, lastRefill, lastListAt = C.MAX_TOKENS, Now(), Now()
  ticker = ns.NewTicker(C.PUMP, Pump)
end

local function StopPump()
  if ticker then ticker:Cancel() ticker = nil end
  ClearQueue()
end

------------------------------------------------------------------------
-- Deciding what to send
------------------------------------------------------------------------
-- a full sync, now: H, every quest, then L
local function StartFull()
  if not G.Active() then return end
  lastFullAt = Now()
  queue.helloPending, queue.fullPending, queue.listPending = true, true, true
  Wipe(changedIDs)
end

-- Plan a full sync `delay` seconds from now. Only one is ever planned: a
-- sooner one already planned covers this one. Full syncs are kept at least
-- FULL_GAP seconds apart.
local function ScheduleFull(delay)
  local now = Now()
  local at = now + delay
  if lastFullAt then at = math.max(at, lastFullAt + C.FULL_GAP) end
  if fullDueAt and fullDueAt <= at then return end
  fullDueAt = at
  ns.After(at - now, function()
    if fullDueAt ~= at then return end -- (replaced by a sooner one, or cleared)
    fullDueAt = nil
    StartFull()
  end)
end
C.ScheduleFull = ScheduleFull

-- is a full sync planned or still going out?
local function FullComing()
  return fullDueAt ~= nil or queue.fullPending or queue.helloPending
end

-- resend every quest and the list (no H), because someone sent us an R
local function AnswerResend()
  if not G.Active() or answerRDue then return end
  local now = Now()
  local wait = lastAnswerRAt and (lastAnswerRAt + C.ANSWER_R_GAP - now) or 0
  local function Go()
    answerRDue = false
    if not G.Active() then return end
    lastAnswerRAt = Now()
    queue.fullPending, queue.listPending = true, true
  end
  if wait <= 0 then Go() return end
  answerRDue = true
  ns.After(wait, Go)
end

-- send member `guid` an R, at most once per RESEND_GAP seconds (force: the
-- player asked with /psync sync)
local function RequestResend(guid, force)
  local now = Now()
  if not force and resendAskedAt[guid] and now - resendAskedAt[guid] < C.RESEND_GAP then return end
  resendAskedAt[guid] = now
  C.QueueDirected({ kind = "R", target = guid })
end

function C.QueueDirected(d)
  if not G.Active() then return false end
  if #queue.directed >= C.MAX_DIRECTED then table.remove(queue.directed, 1) end
  queue.directed[#queue.directed + 1] = d
  return true
end

-- our quest log changed: send the changed quests and the list, 1 s after the
-- last change (never more than 3 s)
local function Flush()
  if not G.Active() then Wipe(changedIDs) return end
  -- (a full sync on its way sends everything anyway)
  if not FullComing() then
    for id in pairs(changedIDs) do queue.dirty[id] = true end
    queue.listPending = true
  end
  Wipe(changedIDs)
end

ns.On("MINE_CHANGED", function(dirty, removed)
  if not G.Active() then return end
  for _, id in ipairs(dirty or {}) do changedIDs[id] = true end
  ns.Debounce("send", 1, 3, Flush)
end)

ns.On("ROSTER_CHANGED", function(added, removed)
  -- whoever left: forget everything about them
  for _, guid in ipairs(removed or {}) do
    flood[guid], resendAskedAt[guid], joinedAt[guid], resendAnsweredAt[guid] = nil, nil, nil, nil
  end
  if not G.Active() then
    StopPump()
    Wipe(flood)
    Wipe(resendAskedAt)
    Wipe(resendAnsweredAt)
    Wipe(myAsks)
    Wipe(joinedAt)
    return
  end
  for _, guid in ipairs(added or {}) do joinedAt[guid] = Now() end
  StartPump()
  if added and #added > 0 then ScheduleFull(2) end
end)

------------------------------------------------------------------------
-- Receiving
------------------------------------------------------------------------
-- the flood guard: true when this message should be ignored
local function Flooding(guid)
  local now = Now()
  local f = flood[guid]
  if not f then
    f = { start = now, count = 0, blockedUntil = 0 }
    flood[guid] = f
  end
  if now < f.blockedUntil then return true end
  if now - f.start > C.FLOOD_WINDOW then f.start, f.count = now, 0 end
  f.count = f.count + 1
  if f.count > C.FLOOD_COUNT then
    f.blockedUntil = now + C.FLOOD_BLOCK
    f.start, f.count = now, 0
    ns.Debug("ignoring a party member for " .. C.FLOOD_BLOCK .. " s: too many messages")
    return true
  end
  return false
end

local function CountQuests(quests)
  local n = 0
  for _ in pairs(quests) do n = n + 1 end
  return n
end

local handlers = {}

-- "I'm here": answer with a full sync, unless one is already on its way
-- (an H never gets an H back on its own: several Hs share one full sync)
handlers.H = function(m, data)
  local changed = m.proto ~= data.proto or m.version ~= data.version
  m.proto, m.version = data.proto, data.version
  if data.proto ~= W.PROTO then return changed end -- (they can't read ours)
  if FullComing() then return changed end
  local now = Now()
  if (lastFullAt and now - lastFullAt < C.HELLO_GAP)
    or (lastHelloFullAt and now - lastHelloFullAt < C.HELLO_FULL_GAP) then
    -- we sent everything not long ago: they most likely heard it. Our list
    -- lets them check, and ask with R if they didn't. (Someone sending H
    -- over and over gets no more than one full sync per 30 s. The list is
    -- one small message, so it always goes, even if one just went: that
    -- one may have gone out before they could hear it.)
    queue.listPending = true
  else
    lastHelloFullAt = now
    ScheduleFull(2)
  end
  return changed
end

-- Has a member's set of quest IDs changed? (not just their progress) The
-- chain cache in Chain.lua listens for this, because "X is here" uses it.
local function QuestSetChanged() ns.Fire("PARTY_QUESTS_CHANGED") end

-- Quest details: keep them. A member has at most 40 quests, but for a moment
-- we may hold up to 80: when they swap a quest at the cap, the new quest's Q
-- arrives before the L that drops the old one, and the L trims it back.
handlers.Q = function(m, data)
  local changed, added = false, false
  local count = CountQuests(m.quests)
  for _, q in ipairs(data.quests) do
    local old = m.quests[q.id]
    if old or count < C.MAX_HELD then
      if not old then count, added = count + 1, true end
      if not old or W.EncodeQuest(old) ~= W.EncodeQuest(q) then
        m.quests[q.id] = q
        changed = true
      end
    end
  end
  if added then QuestSetChanged() end
  return changed
end

-- the list of quests they have: anything else is gone. If what we hold
-- doesn't match their checksum, or they list a quest we have no details
-- for, we ask them to resend.
handlers.L = function(m, data)
  local changed = false
  local listed = {}
  for _, id in ipairs(data.ids) do listed[id] = true end
  for id in pairs(m.quests) do
    if not listed[id] then
      m.quests[id] = nil
      changed = true
    end
  end
  if changed then QuestSetChanged() end
  local unknown = false
  for _, id in ipairs(data.ids) do
    if not m.quests[id] then unknown = true end
  end
  if m.listSum ~= data.sum or #m.list ~= #data.ids then changed = true end
  m.list, m.listSum = data.ids, data.sum
  if unknown or W.Checksum(m.quests) ~= data.sum then RequestResend(m.guid) end
  return changed
end

-- "please resend everything": only the member it names answers, and each
-- member's R at most once per 30 s (their own R rule allows one per 30 s)
handlers.R = function(m, data)
  if data.target ~= G.MyGUID() then return false end
  local now = Now()
  local last = resendAnsweredAt[m.guid]
  if last and now - last < C.ANSWER_R_EACH then return false end
  resendAnsweredAt[m.guid] = now
  AnswerResend()
  return false
end

-- "please share this quest with me"
handlers.A = function(m, data)
  if data.target ~= G.MyGUID() then return false end
  local now = Now()
  local key = m.guid .. ":" .. data.questID
  if askSeen[key] and now - askSeen[key] < C.ASK_REPEAT then return false end
  for i = #askTimes, 1, -1 do
    if now - askTimes[i] >= 60 then table.remove(askTimes, i) end
  end
  for k, at in pairs(askSeen) do
    if now - at >= C.ASK_REPEAT then askSeen[k] = nil end
  end
  askSeen[key] = now
  -- too many asks this minute from everyone together: "not now", so the
  -- asker isn't left waiting (the same ask again is still ignored above).
  -- Those "not now"s are limited too, so a flood of asks can't fill our queue.
  if #askTimes >= C.ASK_MAX then
    for i = #limitTimes, 1, -1 do
      if now - limitTimes[i] >= 60 then table.remove(limitTimes, i) end
    end
    if #limitTimes < C.ASK_MAX then
      limitTimes[#limitTimes + 1] = now
      C.Answer(m.guid, data.questID, "n")
    end
    return false
  end
  askTimes[#askTimes + 1] = now
  local q = ns.mine.quests[data.questID]
  if not (ns.db and ns.db.settings.allowAsks) then
    C.Answer(m.guid, data.questID, "o")
  elseif not (q and q.pushable) then
    C.Answer(m.guid, data.questID, "x")
  else
    ns.Fire("SHARE_ASKED", m.guid, data.questID)
  end
  return false
end

-- the answer to an ask of ours (only for asks we really sent, in the last 2 minutes)
handlers.a = function(m, data)
  if data.asker ~= G.MyGUID() then return false end
  local key = m.guid .. ":" .. data.questID
  local at = myAsks[key]
  if not at or Now() - at > 120 then return false end
  myAsks[key] = nil
  ns.Fire("SHARE_ANSWERED", m.guid, data.questID, data.code)
  return false
end

-- CHAT_MSG_ADDON. Everything here comes from another player, so it's
-- checked step by step and anything odd is quietly dropped.
function C.OnMessage(prefix, msg, channel, sender)
  if ns.IsSecret(prefix) or ns.IsSecret(msg) or ns.IsSecret(channel) or ns.IsSecret(sender) then return end
  if prefix ~= C.PREFIX or channel ~= "PARTY" then return end
  if type(msg) ~= "string" or #msg > W.MAX_MSG then return end
  if not G.Active() then return end
  -- exactly one party member who isn't us
  local guid = G.Lookup(sender)
  local m = guid and ns.members[guid]
  if not m then return end
  if Flooding(guid) then return end
  -- (Decode removes "|", rejects control characters and checks every field)
  local kind, data = W.Decode(msg)
  if not kind then
    ns.Debug("dropped a message: " .. tostring(data))
    return
  end
  local changed = m.hasAddon ~= true
  m.hasAddon = true
  m.lastHeard = Now()
  if handlers[kind](m, data) then changed = true end
  if changed then ns.Fire("CHANGED") end
end

------------------------------------------------------------------------
-- Ask to share (the popup and buttons come later; this is the messages)
------------------------------------------------------------------------
-- Ask the member with this GUID to share a quest. Returns true if the ask
-- was queued (false: not in a party, unknown member, or asked them in the
-- last 60 s).
function C.Ask(targetGUID, questID)
  local m = targetGUID and ns.members[targetGUID]
  if not m or m.hasAddon == false or not W.EncodeAsk(questID, targetGUID) then return false end
  local key = targetGUID .. ":" .. questID
  local now = Now()
  if myAsks[key] and now - myAsks[key] < C.ASK_REPEAT then return false end
  if not C.QueueDirected({ kind = "A", questID = questID, target = targetGUID }) then return false end
  myAsks[key] = now
  return true
end

-- Answer an ask: code "s" shared, "n" not now, "x" can't share, "o" asks off.
function C.Answer(askerGUID, questID, code)
  if not W.EncodeAnswer(questID, askerGUID, code) then return false end
  return C.QueueDirected({ kind = "a", questID = questID, asker = askerGUID, code = code })
end

------------------------------------------------------------------------
-- /psync sync and /psync status
------------------------------------------------------------------------
ns.SlashHandlers.sync = function()
  if not G.Active() then
    if G.IsPaused() then
      ns.Print("PartySync works in parties. It's paused while you're in a raid.")
    else
      ns.Print("You're not in a party.")
    end
    return
  end
  local now = Now()
  if lastSyncCommand and now - lastSyncCommand < C.SYNC_GAP then
    ns.Print(("Synced a moment ago. Try again in %d s."):format(math.ceil(C.SYNC_GAP - (now - lastSyncCommand))))
    return
  end
  lastSyncCommand = now
  StartFull()
  for guid, m in pairs(ns.members) do
    if m.hasAddon ~= false then RequestResend(guid, true) end
  end
  ns.Print("Syncing with your party.")
end

-- an extra note for a member's line in /psync status
function C.StatusNote(m)
  if not m.lastHeard then return "not heard from yet" end
  return ("last heard %d s ago"):format(math.floor(Now() - m.lastHeard))
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------
ns.RegisterEvent("PLAYER_LOGIN", function()
  if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    local ok, err = pcall(C_ChatInfo.RegisterAddonMessagePrefix, C.PREFIX)
    if not ok then ns.ReportError("prefix: " .. tostring(err)) end
  end
  lastListAt = Now()
  if G.Active() then StartPump() end
end)

-- A full sync only after logging in or /reload (a party change has its own,
-- see ROSTER_CHANGED). Any other loading screen (a dungeon, a boat) changes
-- nothing for the others, so just our list goes out for them to check.
ns.RegisterEvent("PLAYER_ENTERING_WORLD", function(isInitialLogin, isReloadingUi)
  if G.Active() then
    StartPump()
    if isInitialLogin or isReloadingUi then
      ScheduleFull(4)
    elseif not FullComing() then
      queue.listPending = true
    end
  end
end)

ns.RegisterEvent("CHAT_MSG_ADDON", C.OnMessage)
