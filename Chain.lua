-- Chain: walks a quest's chain (the quests you need first, and what comes
-- after) and works out why you can't get a quest your party has.
-- Chain.Build is pure: it only uses the functions it's given, so the tests
-- can feed it anything. Chain.WhyNot is the part that asks the game, the
-- party data and the Questie bridge (QuestieBridge.lua), and Model.lua uses
-- it in place of its own two-rule version.
--
-- Chain.Build(targetID, Q, isDone, inMyLog, memberSteps) returns nil when Q
-- doesn't know the target, otherwise:
--   {
--     steps = { { id, name, done, mine (in my log), here = { "Bob", ... },
--                 target (the quest you asked about), next (the step to do now) }, ... },
--     targetIndex, nextIndex (nil when everything up to the target is done),
--     k = done steps before the target, n = #steps,
--     truncated = true when a cap cut the walk short,
--   }
--   Q(id)            -> a QDB.Quest record (see QuestieBridge.lua), false or nil
--   isDone(id)       -> handed in before?
--   inMyLog(id)      -> in my quest log now?
--   memberSteps(id)  -> names of party members who have it in their log, or nil
--
-- How the walk goes (DESIGN section 6):
--   Backward: every quest in preAll, then ONE quest from preAny (one you've
--   done, then one you have, then one a party member has, then the one whose
--   "next" is this quest, then the lowest ID), skipping choices an exclusive
--   quest has ruled out. Then the quest itself. Stops at quests already seen
--   (so loops end), at depth 25 and at 30 quests.
--   Forward: follows "next" from the target, at most 10 more steps.
--   Breadcrumbs are left out.
--
-- Chain.WhyNot(quest, holders, canAsk) -> { rule, text, hint, gold, needsDB, hide, chain }
--   rule 1  already handed in -> hide
--   rule 4  for another race or class -> hide (hideOtherClass), or say so
--   rule 3  level too low
--   rule 5  an exclusive quest is done or in my log
--   rule 6  earlier quests in the chain aren't done ("You're k of N steps in")
--   rule 2  nobody can share it
--   rule 7  "Ask to share" is the way
--   Without the database only rules 1, 2 and 7 can be told apart (as before).
--   `gold` is a part of `text` to show in gold; `chain` is the Build result.
--   Answers are cached per quest ID (see "The cache" at the end); treat them
--   as read-only. Chain.ClearCache() empties it.

local _, ns = ...
local Chain = {}
ns.Chain = Chain

Chain.MAX_DEPTH = 25
Chain.MAX_NODES = 30
Chain.MAX_FORWARD = 10

------------------------------------------------------------------------
-- The walk
------------------------------------------------------------------------
function Chain.Build(targetID, Q, isDone, inMyLog, memberSteps)
  local target = Q(targetID)
  if not target then return nil end
  local order, visited, truncated = {}, {}, false

  local function Here(id)
    local names = memberSteps(id)
    return type(names) == "table" and #names > 0
  end

  -- has an exclusive quest of this one been done or picked up? Then it's
  -- not on the table any more.
  local function RuledOut(id)
    if isDone(id) or inMyLog(id) then return false end
    local q = Q(id)
    if not q then return false end
    for _, x in ipairs(q.exclusive) do
      if x ~= id and (isDone(x) or inMyLog(x)) then return true end
    end
    return false
  end

  -- one of the "any one of these" quests (lower score wins)
  local function Pick(forID, list)
    local best, bestScore
    for pass = 1, 2 do
      for _, c in ipairs(list) do
        if pass == 2 or not RuledOut(c) then
          local q = Q(c)
          local score
          if isDone(c) then score = 1
          elseif inMyLog(c) then score = 2
          elseif Here(c) then score = 3
          elseif q and q.next == forID then score = 4
          else score = 5 end
          if not best or score < bestScore or (score == bestScore and c < best) then best, bestScore = c, score end
        end
      end
      -- (when every choice is ruled out, show the best of them anyway)
      if best then break end
    end
    return best
  end

  local function Visit(id, depth)
    if visited[id] then return end
    -- (room is always kept for the target itself)
    if depth > Chain.MAX_DEPTH or #order >= Chain.MAX_NODES - 1 then truncated = true return end
    visited[id] = true
    local q = Q(id)
    if not q then return end -- (an earlier quest Questie doesn't know: left out)
    for _, p in ipairs(q.preAll) do Visit(p, depth + 1) end
    if #q.preAny > 0 then
      local p = Pick(id, q.preAny)
      if p then Visit(p, depth + 1) end
    end
    if #order < Chain.MAX_NODES - 1 then order[#order + 1] = id else truncated = true end
  end

  visited[targetID] = true
  for _, p in ipairs(target.preAll) do Visit(p, 1) end
  if #target.preAny > 0 then
    local p = Pick(targetID, target.preAny)
    if p then Visit(p, 1) end
  end
  order[#order + 1] = targetID
  local targetIndex = #order

  -- forward along "next"
  local id, steps = target.next, 0
  while id and not visited[id] do
    if steps >= Chain.MAX_FORWARD then truncated = true break end
    local q = Q(id)
    if not q then break end
    visited[id] = true
    order[#order + 1] = id
    steps = steps + 1
    id = q.next
  end

  local out = { steps = {}, targetIndex = targetIndex, k = 0, n = #order, truncated = truncated }
  for i, sid in ipairs(order) do
    local q = Q(sid)
    local names = memberSteps(sid)
    local step = {
      id = sid, name = (q and q.name) or ("Quest " .. sid),
      done = isDone(sid) and true or false, mine = inMyLog(sid) and true or false,
      here = type(names) == "table" and names or {}, target = i == targetIndex,
    }
    out.steps[i] = step
    if i < targetIndex and step.done then out.k = out.k + 1 end
    if not out.nextIndex and i <= targetIndex and not step.done then
      out.nextIndex = i
      step.next = true
    end
  end
  return out
end

------------------------------------------------------------------------
-- Race and class
------------------------------------------------------------------------
-- Is `bitValue` (a single bit, like 64) set in `mask`? Done with arithmetic,
-- not bit.band: Forever's newest races use bits 32 and 33, which the game's
-- 32-bit bit library would cut off.
function Chain.HasBit(mask, bitValue)
  if type(mask) ~= "number" or type(bitValue) ~= "number" or bitValue <= 0 then return false end
  return math.floor(mask / bitValue) % 2 == 1
end

-- true when the quest is only for other races or other classes
function Chain.WrongRaceOrClass(q)
  local race, class = ns.QDB.MyRaceMask(), ns.QDB.MyClassMask()
  if race and q.races and q.races > 0 and not Chain.HasBit(q.races, race) then return true end
  if class and q.classes and q.classes > 0 and not Chain.HasBit(q.classes, class) then return true end
  return false
end

------------------------------------------------------------------------
-- Why can't I get it?
------------------------------------------------------------------------
local TEXT = {
  noShare = "This quest can't be shared, so you'll need to pick it up yourself.",
  otherClass = "This quest is for another race or class.",
  exclusive = "You've picked a different quest that rules this one out.",
  earlier = "You need the earlier quests in this chain first. You're %s steps in.",
  level = "You need to be level %d (you're %d).",
  loading = "Questie is still loading its quest data. Try again in a moment.",
  broken = "Couldn't read Questie's quest data right now.",
  unknown = "Questie doesn't know this quest yet.",
}
Chain.TEXT = TEXT

local function IsDone(id) return ns.QuestLog.IsDone(id) == true end
local function InMyLog(id) return ns.mine.quests[id] ~= nil end

-- names of party members (with PartySync) who have this quest in their log
-- (`members` is read once per WhyNot, not once per step)
local members = {}
local function MemberSteps(id)
  local names
  for _, m in ipairs(members) do
    if m.hasAddon == true and m.quests[id] then
      names = names or {}
      names[#names + 1] = m.name
    end
  end
  return names
end

local function PlayerLevel()
  local lvl = UnitLevel and UnitLevel("player")
  if type(lvl) ~= "number" or ns.IsSecret(lvl) then return nil end
  return lvl
end

-- rules 2 and 7 only (no database, or it doesn't know the quest);
-- `note` is what to say about the database instead of the chain
local function Basic(canAsk, note, needsDB)
  if not canAsk then
    return { rule = 2, text = TEXT.noShare, hint = note, needsDB = needsDB }
  end
  return { rule = 7, needsDB = needsDB }
end

local function Compute(id, first, canAsk, state, hideOther, level)
  if IsDone(id) then return { rule = 1, hide = true } end
  if state == "none" then return Basic(canAsk, "Ask " .. first .. " where it started.", true) end
  if state == "loading" then return Basic(canAsk, TEXT.loading, false) end
  -- (broken: no lookups at all, just say so; no nudge, it IS installed)
  if state ~= "ready" then return Basic(canAsk, TEXT.broken, false) end
  local q = ns.QDB.Quest(id)
  if q == false then return Basic(canAsk, TEXT.unknown, false) end
  if not q then return Basic(canAsk, TEXT.broken, false) end

  local wrong = Chain.WrongRaceOrClass(q)
  if wrong and hideOther then return { rule = 4, hide = true } end
  members = ns.Group.SortedMembers()
  local chain = Chain.Build(id, ns.QDB.Quest, IsDone, InMyLog, MemberSteps)
  -- (the database broke while we walked: say so, nothing else)
  if ns.QDB.state ~= "ready" then return Basic(canAsk, TEXT.broken, false) end

  local why = { chain = chain, needsDB = false }
  local blocked = false
  for _, x in ipairs(q.exclusive) do
    if x ~= id and (IsDone(x) or InMyLog(x)) then blocked = true end
  end
  if wrong then
    why.rule, why.text = 4, TEXT.otherClass
  elseif level and q.reqLevel > level then
    why.rule, why.text = 3, TEXT.level:format(q.reqLevel, level)
  elseif blocked then
    why.rule, why.text = 5, TEXT.exclusive
  elseif chain and chain.nextIndex and chain.nextIndex < chain.targetIndex then
    why.gold = chain.k .. " of " .. chain.n
    why.rule, why.text = 6, TEXT.earlier:format(why.gold)
  elseif not canAsk then
    why.rule, why.text = 2, TEXT.noShare
  else
    why.rule = 7
  end
  return why
end

------------------------------------------------------------------------
-- The cache: one answer per quest ID, so a panel refresh doesn't walk every
-- chain again. Cleared when my log, my level, the party or the party's quest
-- lists change, or the Questie connection changes; and an answer is only
-- reused for the same holder, share state, setting, level and connection.
------------------------------------------------------------------------
Chain.MAX_CACHE = 300
local cache, cacheCount = {}, 0 -- [questID] = { first, canAsk, state, hide, level, why }

function Chain.ClearCache()
  for k in pairs(cache) do cache[k] = nil end
  cacheCount = 0
end

function Chain.WhyNot(quest, holders, canAsk)
  local id = quest.id
  local first = holders[1] and holders[1].name or "them"
  local state = ns.QDB.State()
  local settings = (ns.db and ns.db.settings) or ns.DEFAULTS.settings
  local hideOther = settings.hideOtherClass and true or false
  local level = PlayerLevel()
  canAsk = canAsk and true or false
  local e = cache[id]
  if e and e.first == first and e.canAsk == canAsk and e.state == state and e.hide == hideOther and e.level == level then
    return e.why
  end
  local why = Compute(id, first, canAsk, state, hideOther, level)
  -- (an answer from a walk the database broke in the middle of isn't kept)
  if ns.QDB.state == state then
    if not e then
      if cacheCount >= Chain.MAX_CACHE then Chain.ClearCache() end
      cacheCount = cacheCount + 1
    end
    cache[id] = { first = first, canAsk = canAsk, state = state, hide = hideOther, level = level, why = why }
  end
  return why
end

for _, event in ipairs({ "MINE_CHANGED", "LEVEL_UP", "ROSTER_CHANGED", "PARTY_QUESTS_CHANGED", "QDB_CHANGED" }) do
  ns.On(event, Chain.ClearCache)
end
