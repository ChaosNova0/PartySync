-- SharePopup: when a party member clicks "Ask to share" on one of your
-- quests, this small window asks you: "<Asker> asks you to share '<Quest>'"
-- with [Share] and [Not now]. Built the way an earlier addon's roll popup is:
-- DIALOG strata, drag to move, the spot saved when you let go.
--   Share     shares the quest with your party (C_QuestLog.SetSelectedQuest,
--             then QuestLogPushQuest, straight from the click) and answers "s".
--             It's grey for 0.75 s each time the popup opens, so a click meant
--             for something else doesn't share by accident. The quest log's
--             selection is checked before sharing and put back after.
--             If the quest is gone, can't be shared any more, or the quest log
--             won't select it, it answers "x".
--   Not now   answers "n". So do the X and waiting 30 s without clicking.
-- Hiding the whole interface (Alt-Z, or a cutscene) answers nothing: the ask
-- showing and the ones waiting are held, and come back when the interface
-- does, with a fresh 30 s (the waiting ones' 90 s is paused meanwhile). A
-- check once a second notices it's back, only while something is held.
-- Asks from someone who has left the party are dropped without an answer,
-- and all of them are when we're on our own or in a raid.
-- One popup at a time. Asks that come in while one is showing wait their turn
-- (at most 3 waiting, each for at most 90 s); past that they're answered "n".
-- Comm.lua has already dropped repeats and kept it to 5 asks a minute. On
-- top of that, each asker gets at most one popup per 90 s, and after two
-- "Not now"s (timeouts included) to the same asker, the rest of their asks
-- this session are answered "n" without a popup. Those answers say "not now"
-- so the asker isn't left waiting.
-- Nothing here is protected, so it works in combat too.
--
-- Saved: PartySyncDB.popup = { point = "TOPLEFT", relPoint, x, y } (where it
-- was dragged to; by its top-left corner, so a taller ask grows downwards).
--
-- ns.UI.SharePopup (for the tests):
--   SP.Current()   the ask showing now { asker, questID, at }, or nil
--   SP.Waiting()   the asks waiting their turn
--   SP.frame       PartySyncSharePopup, once built

local _, ns = ...
local T = ns.Theme
local UI = ns.UI
local SP = {}
UI.SharePopup = SP

SP.TIMEOUT = 30       -- seconds before it closes itself (as Not now)
SP.MAX_WAITING = 3    -- asks waiting behind the one showing
SP.WAIT_LIMIT = 90    -- seconds an ask may wait before it's answered "n"
SP.ASKER_GAP = 90     -- at most one popup per asker in this many seconds
SP.MAX_DECLINES = 2   -- "Not now"s to one asker before the rest are answered "n"
SP.SHARE_DELAY = 0.75 -- seconds Share stays grey after the popup opens
SP.WIDTH = 300

local f
local current        -- { asker, questID, at, token }
local waiting = {}   -- { { asker, questID, at }, ... }
local token = 0      -- which showing the timeout belongs to
local ticker         -- the countdown's 1 s timer, only while it's showing
local lastPopup = {} -- [askerGUID] = when we last took an ask of theirs for a popup
local declines = {}  -- [askerGUID] = "Not now"s answered to them this session
local held = false   -- the interface is hidden: the asks wait for it to come back
local heldAt         -- when that started
local holdTicker     -- the 1 s check for the interface coming back, only while held

function SP.Current() return current end
function SP.Waiting() return waiting end

------------------------------------------------------------------------
-- Position: by the top-left corner, like the panel (UI.SaveTopLeft)
------------------------------------------------------------------------
local function SavePosition()
  if ns.db then UI.SaveTopLeft(f, ns.db.popup) end
end

local function Place()
  UI.PlaceTopLeft(f, ns.db.popup)
end

------------------------------------------------------------------------
-- Answering
------------------------------------------------------------------------
local ShowNext, Open

-- is the whole interface hidden (Alt-Z, a cutscene)?
local function UIHidden()
  return UIParent ~= nil and not UIParent:IsShown()
end

local function StopHold()
  held, heldAt = false, nil
  if holdTicker then holdTicker:Cancel() holdTicker = nil end
end

-- the interface is back: show the held ask again (a fresh countdown), or the
-- next one waiting
local function CheckResume()
  if not held then StopHold() return end
  if UIHidden() then return end
  local pausedFor = GetTime() - heldAt
  StopHold()
  for _, w in ipairs(waiting) do w.at = w.at + pausedFor end
  local e = current
  current = nil
  if e then Open(e) else ShowNext() end
end

-- the interface was hidden while an ask was up: keep it, answer nothing
local function Hold()
  if held or not current then return end
  held, heldAt = true, GetTime()
  token = token + 1 -- (this showing's timeout and Share wake-up no longer count)
  if ticker then ticker:Cancel() ticker = nil end
  holdTicker = ns.NewTicker(1, CheckResume)
end

local function TitleOf(questID)
  local q = ns.mine.quests[questID]
  return (q and q.title) or ("quest " .. questID)
end

-- close the ask showing now with this answer, then show the next one
local function Finish(code)
  local e = current
  if not e then return end
  current = nil
  if ticker then ticker:Cancel() ticker = nil end
  if code == "n" then declines[e.asker] = (declines[e.asker] or 0) + 1 end
  if ns.Comm then ns.Comm.Answer(e.asker, e.questID, code) end
  if f and f:IsShown() then f:Hide() end
  ShowNext()
end

-- can we still share it? (the log may have changed since they asked)
local function StillPushable(questID)
  local q = ns.mine.quests[questID]
  if not (q and q.pushable) then return false end
  local fn = C_QuestLog and C_QuestLog.IsPushableQuest
  if type(fn) == "function" then
    local ok, v = pcall(fn, questID)
    if ok and not ns.IsSecret(v) then return v and true or false end
  end
  return true
end

-- the quest log's selected quest, or nil (when the client can't say)
local function SelectedQuest()
  local fn = C_QuestLog and C_QuestLog.GetSelectedQuest
  if type(fn) ~= "function" then return nil end
  local ok, v = pcall(fn)
  if not ok or ns.IsSecret(v) or type(v) ~= "number" then return nil end
  return v
end

local function OnShare()
  local e = current
  if not e then return end
  -- (still grey: too soon after it opened)
  if GetTime() - e.at < SP.SHARE_DELAY then return end
  local name, title = ns.Escape(UI.NameOf(e.asker)), ns.Escape(TitleOf(e.questID))
  if not StillPushable(e.questID) then
    Finish("x")
    UI.Toast(('You can\'t share "%s" any more.'):format(title))
    return
  end
  -- (both are listed for Forever on the wiki, but not checked in game yet)
  if not (C_QuestLog and type(C_QuestLog.SetSelectedQuest) == "function" and type(QuestLogPushQuest) == "function") then
    Finish("x")
    UI.Toast("Couldn't share it: this game client won't let addons share quests.")
    return
  end
  local canCheck = type(C_QuestLog.GetSelectedQuest) == "function"
  local before = SelectedQuest()
  local ok, res = pcall(function()
    C_QuestLog.SetSelectedQuest(e.questID)
    -- (QuestLogPushQuest shares whatever is selected: make sure it's this one)
    if canCheck and SelectedQuest() ~= e.questID then return "not selected" end
    QuestLogPushQuest()
  end)
  -- put back the quest the quest log had selected before
  if before and before > 0 and before ~= e.questID then
    local back, err = pcall(C_QuestLog.SetSelectedQuest, before)
    if not back then ns.Debug("selecting the quest again: " .. tostring(err)) end
  end
  if not ok then
    ns.ReportError("share: " .. tostring(res))
    Finish("x")
    UI.Toast("Couldn't share that quest right now.")
    return
  end
  if res == "not selected" then
    Finish("x")
    UI.Toast(('Couldn\'t pick "%s" in your quest log, so it wasn\'t shared.'):format(title))
    return
  end
  Finish("s")
  UI.Toast(('Shared "%s" with %s'):format(title, name))
end

------------------------------------------------------------------------
-- The window
------------------------------------------------------------------------
local function Build()
  f = CreateFrame("Frame", "PartySyncSharePopup", UIParent)
  SP.frame = f
  f:Hide()
  f:SetSize(SP.WIDTH, 96)
  f:SetFrameStrata("DIALOG")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function() f:StartMoving() end)
  -- (placed again by its top-left corner, as the panel is)
  f:SetScript("OnDragStop", function() f:StopMovingOrSizing(); SavePosition(); Place() end)
  -- the panel's look: dark fill, a brown edge and a black outline
  T.Fill(f, T.panel)
  T.Border(f, T.edge)
  local outline = CreateFrame("Frame", nil, f)
  outline:SetPoint("TOPLEFT", -1, 1)
  outline:SetPoint("BOTTOMRIGHT", 1, -1)
  T.Border(outline, { 0, 0, 0, 1 })

  f.heading = T.Text(f, 12, T.gold)
  f.heading:SetPoint("TOPLEFT", 10, -8)
  f.heading:SetText("PartySync")
  f.timeText = T.Text(f, 11, T.dim)
  f.timeText:SetPoint("TOPRIGHT", -30, -9)
  f.timeText:SetJustifyH("RIGHT")
  f.close = T.CloseButton(f, function() Finish("n") end)
  f.close:SetPoint("TOPRIGHT", -6, -5)

  f.text = T.Text(f, 13, T.text)
  f.text:SetPoint("TOPLEFT", 10, -28)
  f.text:SetWidth(SP.WIDTH - 20)
  f.text:SetWordWrap(true)

  f.share = T.Button(f, "Share", "red", 20)
  f.share:SetWidth(90)
  f.share:SetPoint("BOTTOMLEFT", 10, 10)
  f.share:SetScript("OnClick", OnShare)
  f.notNow = T.Button(f, "Not now", "title", 20)
  f.notNow:SetWidth(90)
  f.notNow:SetPoint("LEFT", f.share, "RIGHT", 8, 0)
  f.notNow:SetScript("OnClick", function() Finish("n") end)

  -- Hidden along with the whole interface (it's still "shown", just not
  -- visible): held, no answer. Anything else hiding it counts as Not now.
  f:SetScript("OnHide", function()
    if not current or held then return end
    if f:IsShown() or UIHidden() then Hold() else Finish("n") end
  end)
end

local function UpdateTime()
  if f and current then
    f.timeText:SetText(("%ds"):format(math.max(0, math.ceil(current.at + SP.TIMEOUT - GetTime()))))
  end
end

Open = function(e)
  if not f then Build() end
  token = token + 1
  local mine = token
  e.at = GetTime()
  current = e
  -- (nobody can see it now: it waits for the interface to come back)
  if UIHidden() then Hold() return end
  Place()
  f.text:SetText(('%s asks you to share "%s"'):format(
    T.Color(ns.Escape(UI.NameOf(e.asker)), T.gold), T.Color(ns.Escape(TitleOf(e.questID)), { 1, 1, 0 })))
  local h = math.ceil(f.text:GetStringHeight() or 14)
  f:SetHeight(28 + h + 10 + 20 + 10)
  UpdateTime()
  -- Share wakes up a moment after it opens
  f.share:SetStyle("grey")
  ns.After(SP.SHARE_DELAY, function()
    if f and current and token == mine then f.share:SetStyle("red") end
  end)
  f:Show()
  if ticker then ticker:Cancel() end
  ticker = ns.NewTicker(1, UpdateTime)
  -- (waiting it out counts as Not now, but only if it could be seen)
  ns.After(SP.TIMEOUT, function()
    if current and token == mine then
      if UIHidden() then Hold() else Finish("n") end
    end
  end)
end

-- the next waiting ask that's still worth showing
ShowNext = function()
  if held then return end -- (CheckResume shows it when the interface is back)
  while #waiting > 0 do
    local e = table.remove(waiting, 1)
    if GetTime() - e.at > SP.WAIT_LIMIT then
      if ns.Comm then ns.Comm.Answer(e.asker, e.questID, "n") end
    elseif not StillPushable(e.questID) then
      if ns.Comm then ns.Comm.Answer(e.asker, e.questID, "x") end
    else
      Open(e)
      return
    end
  end
end

local function Same(a, asker, questID) return a and a.asker == asker and a.questID == questID end

local function NotNow(asker, questID)
  if ns.Comm then ns.Comm.Answer(asker, questID, "n") end
end

ns.On("SHARE_ASKED", function(asker, questID)
  if not ns.db or type(questID) ~= "number" or type(asker) ~= "string" then return end
  if Same(current, asker, questID) then return end
  for _, w in ipairs(waiting) do if Same(w, asker, questID) then return end end
  local now = GetTime()
  -- you've said Not now to them twice: no more popups from them this session
  if (declines[asker] or 0) >= SP.MAX_DECLINES then return NotNow(asker, questID) end
  -- one popup per asker per 90 s
  if lastPopup[asker] and now - lastPopup[asker] < SP.ASKER_GAP then return NotNow(asker, questID) end
  if (current or held) and #waiting >= SP.MAX_WAITING then return NotNow(asker, questID) end
  lastPopup[asker] = now
  if current or held then
    waiting[#waiting + 1] = { asker = asker, questID = questID, at = now }
    return
  end
  Open({ asker = asker, questID = questID })
end)

-- Party changes: asks from anyone who has left are dropped, and all of them
-- are on our own or in a raid. No answer: they can't hear it any more.
local function DropAsks(keep)
  for i = #waiting, 1, -1 do
    if not keep(waiting[i].asker) then table.remove(waiting, i) end
  end
  if current and not keep(current.asker) then
    current = nil
    token = token + 1
    if ticker then ticker:Cancel() ticker = nil end
    if f and f:IsShown() then f:Hide() end
    ShowNext()
  end
  if held and not current then
    if #waiting == 0 then StopHold() end
  end
end

local function Nobody() return false end
local function StillHere(asker) return ns.members[asker] ~= nil end

ns.On("ROSTER_CHANGED", function()
  if ns.Group and ns.Group.Active() then DropAsks(StillHere) else DropAsks(Nobody) end
end)
