-- Sections: the middle of the panel, mockup parts 4-6, drawn from the
-- Model.Build() table (see Model.lua) into the panel's scrolling area.
--   4. You're missing: quests party members have that you don't, with
--      "Ask to share" (red) or "How to get it" (blue, opens the reason)
--   5. In progress: quests you share, a row per person with a progress bar
--   6. Ready to turn in: quests everyone has finished
-- Section headers fold (saved in collapsed.sections), and so do quest titles
-- in "In progress" (saved with ns.SetQuestCollapsed).
--
-- Every row is a reusable frame from a pool: a refresh hides what it doesn't
-- need and never makes new frames unless the list got longer than ever before.
--
-- ns.UI.Sections:
--   S.Draw(content, view, width) -> height   draws everything (Panel.lua calls it)
--   S.drawn       what the last Draw showed: { headers, missing, progress, rows, ready }
--                 (arrays of frames; the tests read them)
--   S.PoolSizes() how many frames each pool has made
--   S.ASK_REST    seconds "Ask to share" stays greyed after asking (60)
--   S.HowToExtra(holder, quest, width) -> height   draws the quest chain (from
--                 quest.why.chain, see Chain.lua), "Show on map" and "Track next
--                 step" inside the open "How to get it" panel; 0 without a chain.
--                 Its rows are a pool kept on the holder (holder.steps), and
--                 holder.drawn lists the rows the last call showed (the tests read it).

local _, ns = ...
local T = ns.Theme
local S = {}
ns.UI.Sections = S

S.ASK_REST = 60
local PAD = 8          -- left and right padding
local QUEST_X = 14     -- quest titles, as in the mockup
local SUB_X = 24       -- rows and notes under a quest
local LINE = 16        -- one line of 13 px text
local ROW_H = 15       -- one holder row
local BAR_W, BAR_H = 54, 8

local askedAt = {}     -- [questID] = GetTime() of our last ask (this session)
local howtoOpen = {}   -- [questID] = true: its "How to get it" panel is open

S.drawn = { headers = {}, missing = {}, progress = {}, rows = {}, ready = {} }

------------------------------------------------------------------------
-- Pools
------------------------------------------------------------------------
local function NewPool(make) return { make = make, list = {}, used = 0 } end

local function Take(pool, parent)
  pool.used = pool.used + 1
  local fr = pool.list[pool.used]
  if not fr then
    fr = pool.make(parent)
    pool.list[pool.used] = fr
  end
  fr:ClearAllPoints()
  fr:Show()
  return fr
end

local function Finish(pool)
  for i = pool.used + 1, #pool.list do pool.list[i]:Hide() end
end

local function Wipe(t) for k in pairs(t) do t[k] = nil end end

-- text: wrap it to `width` and return how tall it came out
local function Wrapped(fs, width, text)
  fs:SetWidth(width)
  fs:SetText(text)
  return math.max(LINE - 2, math.ceil(fs:GetStringHeight() or LINE))
end

local function LevelRGB(color)
  local c = ns.Model.LEVEL_RGB[color] or ns.Model.LEVEL_RGB.yellow
  return { c[1], c[2], c[3] }
end

-- "Kobold Camp Cleanup [4]", escaped, in nothing but its own colour
local function TitleText(q)
  local lvl = (q.level and q.level > 0) and (" [" .. q.level .. "]") or ""
  return ns.Escape(q.title or "?") .. lvl
end

------------------------------------------------------------------------
-- Section headers
------------------------------------------------------------------------
local function OnHeaderClick(self)
  local sections = ns.db and ns.db.collapsed.sections
  if not sections or not self.key then return end
  sections[self.key] = not sections[self.key]
  ns.UI.Refresh()
end

local function NewHeader(parent)
  local b = CreateFrame("Button", nil, parent)
  b:SetHeight(21)
  b.arrow = T.Chevron(b, T.dim)
  b.arrow:SetPoint("LEFT", PAD, -1)
  b.text = T.Text(b, 12, T.gold)
  b.text:SetPoint("LEFT", PAD + 12, -1)
  b.text:SetWordWrap(false)
  b:SetScript("OnClick", OnHeaderClick)
  return b
end

------------------------------------------------------------------------
-- Part 4: You're missing
------------------------------------------------------------------------
local function HolderName(q, guid)
  for _, h in ipairs(q.holders or {}) do
    if h.guid == guid then return h.name end
  end
  return "them"
end

function S.Resting(questID)
  local at = askedAt[questID]
  return at ~= nil and GetTime() - at < S.ASK_REST
end

local function OnAsk(self)
  local q = self.card.quest
  if not q or not q.askable or not q.askTarget or S.Resting(q.id) then return end
  local ok = ns.Comm and ns.Comm.Ask(q.askTarget, q.id)
  if ok then
    askedAt[q.id] = GetTime()
    ns.UI.Toast(('Asked %s to share "%s"'):format(ns.Escape(HolderName(q, q.askTarget)), ns.Escape(q.title or "?")))
    -- wake the button up again when the rest is over
    ns.After(S.ASK_REST + 0.1, ns.UI.Refresh)
  else
    ns.UI.Toast("Couldn't send that request right now. Try again in a moment.")
  end
  ns.UI.Refresh()
end

local function OnHowTo(self)
  local q = self.card.quest
  if not q then return end
  howtoOpen[q.id] = not howtoOpen[q.id] or nil
  ns.UI.Refresh()
end

local function NewHowTo(card)
  local p = CreateFrame("Frame", nil, card)
  T.Fill(p, T.howtoBg)
  T.Border(p, T.howtoEdge)
  p.why = T.Text(p, 12, T.objText)
  p.why:SetWordWrap(true)
  -- the QuestieDB nudge: a blue box with a bar down its left side
  local n = CreateFrame("Frame", nil, p)
  T.Fill(n, T.nudgeBg)
  local bar = n:CreateTexture(nil, "BORDER")
  bar:SetColorTexture(T.nudgeBar[1], T.nudgeBar[2], T.nudgeBar[3], 1)
  bar:SetPoint("TOPLEFT")
  bar:SetPoint("BOTTOMLEFT")
  bar:SetWidth(3)
  n.text = T.Text(n, 11, T.nudgeText)
  n.text:SetPoint("TOPLEFT", 9, -4)
  n.text:SetWordWrap(true)
  p.nudge = n
  -- step 10 draws the chain list and its buttons in here (S.HowToExtra)
  p.extra = CreateFrame("Frame", nil, p)
  return p
end

local function NewMissing(parent)
  local card = CreateFrame("Frame", nil, parent)
  T.Line(card, T.questLine, 0)
  card.title = T.Text(card, 13)
  card.title:SetPoint("TOPLEFT", QUEST_X, -4)
  card.title:SetWordWrap(false)
  card.ask = T.Button(card, "Ask to share", "red")
  card.ask:SetPoint("TOPRIGHT", -PAD, -3)
  card.ask.card = card
  card.ask:SetScript("OnClick", OnAsk)
  card.info = T.Button(card, "How to get it", "info")
  card.info:SetPoint("TOPRIGHT", -PAD, -3)
  card.info.card = card
  card.info:SetScript("OnClick", OnHowTo)
  card.sub = T.Text(card, 11, T.dim)
  card.sub:SetPoint("TOPLEFT", SUB_X, -21)
  card.sub:SetWordWrap(true)
  card.howto = NewHowTo(card)
  return card
end

------------------------------------------------------------------------
-- The quest chain inside "How to get it" (mockup #open)
--   [tick]  Young Lovers                 done: green, struck through
--   [>]     Note to William              the step to do now: gold, with
--             Start here: Gramma Stonefield, Elwynn Forest (south-west)
--   [box]   Collecting Kelp  - Bob is here     the quest you asked about: yellow
--   [box]   The Escape                   later steps: grey
-- The mockup's check, arrow and circle characters may not be in the game's
-- font, so the marks are drawn: the game's tick, a chevron and a small box.
------------------------------------------------------------------------
local MARK_W = 16
local STEP_H = 15
local TARGET_RGB = { 1, 1, 0 }        -- #ffff00
local HERE_RGB = { 0.78, 0.61, 0.43 } -- #c79c6e
local WHITE = { 1, 1, 1 }
S.MAX_DONE_SHOWN = 4 -- more done steps than this before the next one fold into one line

local function NewStep(parent)
  local r = CreateFrame("Frame", nil, parent)
  r:SetHeight(STEP_H)
  r.tick = r:CreateTexture(nil, "ARTWORK")
  r.tick:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
  r.tick:SetSize(14, 14)
  r.tick:SetPoint("TOPLEFT", -1, 1)
  r.tick:SetVertexColor(T.good[1], T.good[2], T.good[3], 1)
  r.arrow = T.Chevron(r, T.gold)
  r.arrow:Point("right")
  r.arrow:SetPoint("TOPLEFT", 2, -3)
  r.box = CreateFrame("Frame", nil, r)
  r.box:SetSize(6, 6)
  r.box:SetPoint("TOPLEFT", 3, -4)
  r.boxEdges = T.Border(r.box, T.dim, "ARTWORK")
  r.name = T.Text(r, 12)
  r.name:SetPoint("TOPLEFT", MARK_W, 0)
  r.name:SetWordWrap(false)
  r.strike = r:CreateTexture(nil, "OVERLAY")
  r.strike:SetColorTexture(T.good[1], T.good[2], T.good[3], 0.4)
  r.strike:SetHeight(1)
  r.on = T.Text(r, 11, HERE_RGB)
  r.on:SetWordWrap(false)
  r.where = T.Text(r, 11, T.text)
  r.where:SetPoint("TOPLEFT", MARK_W, -STEP_H)
  r.where:SetWordWrap(true)
  return r
end

-- "Start here: Gramma Stonefield, Elwynn Forest (south-west)", escaped
local function WhereText(step)
  if step.mine then return "It's in your quest log." end
  local g = ns.QDB and ns.QDB.Giver(step.id)
  if not g then return "Questie doesn't say where it starts." end
  local text = "Start here: " .. T.Color(ns.Escape(g.name), WHITE)
  if g.kind == "item" then return text .. " (an item)" end
  if g.zone then text = text .. ", " .. ns.Escape(g.zone) end
  if g.dir then text = text .. " (" .. g.dir .. ")" end
  return text
end

local function HereText(names)
  if #names == 0 then return nil end
  local list = {}
  for i, n in ipairs(names) do list[i] = ns.Escape(n) end
  -- (a middle dot: the mockup's left arrow may not be in the font)
  return "\194\183 " .. table.concat(list, ", ") .. (#names == 1 and " is here" or " are here")
end

-- one row; returns its height. `summary` = N: "N earlier steps done" instead of a step.
local function PaintStep(r, step, width, summary)
  local state = summary and "done" or (step.done and "done") or (step.next and "next")
    or (step.target and "target") or "later"
  r.tick:SetShown(state == "done")
  r.arrow:SetShown(state == "next")
  r.box:SetShown(state == "target" or state == "later")
  local c = (state == "done" and T.good) or (state == "next" and T.gold)
    or (state == "target" and TARGET_RGB) or T.dim
  for _, e in ipairs(r.boxEdges) do e:SetColorTexture(c[1], c[2], c[3], 1) end
  r.name:SetTextColor(c[1], c[2], c[3], 1)
  r.state = state -- (the tests read this)

  local here = (not summary) and HereText(step.here or {}) or nil
  local onW = 0
  if here then
    r.on:SetText(here)
    onW = math.floor((r.on:GetStringWidth() or 0) + 1)
    r.on:Show()
  else
    r.on:SetText("")
    r.on:Hide()
  end
  r.name:SetText(summary and (summary .. " earlier steps done") or ns.Escape(step.name or "?"))
  local maxW = width - MARK_W - (here and (onW + 6) or 0)
  local nameW = math.max(20, math.min(maxW, math.floor((r.name:GetStringWidth() or 0) + 1)))
  r.name:SetWidth(nameW)
  if here then
    r.on:ClearAllPoints()
    r.on:SetPoint("TOPLEFT", MARK_W + nameW + 6, -1)
  end
  -- done steps are struck through (not the summary line)
  if state == "done" and not summary then
    r.strike:ClearAllPoints()
    r.strike:SetPoint("LEFT", r.name, "LEFT", 0, 0)
    r.strike:SetWidth(nameW)
    r.strike:Show()
  else
    r.strike:Hide()
  end

  local h = STEP_H
  if state == "next" then
    r.where:Show()
    h = h + Wrapped(r.where, width - MARK_W, WhereText(step)) + 2
  else
    r.where:SetText("")
    r.where:Hide()
  end
  r:SetHeight(h)
  return h
end

local function OnShowMap(self)
  local step = self.step
  if not step then return end
  ns.UI.MapToast(ns.QDB.ShowOnMap(step.id))
end

local function OnTrack(self)
  local step = self.step
  if not step then return end
  if ns.UI.TrackedID() == step.id then
    ns.UI.Untrack()
  else
    ns.UI.Track(step.id, self.forQuest)
    ns.UI.Toast("Next step pinned: " .. ns.Escape(step.name or "?"))
  end
end

function S.HowToExtra(holder, quest, width)
  local chain = quest.why and quest.why.chain
  if not chain or #chain.steps == 0 then
    holder:Hide()
    return 0
  end
  holder.steps = holder.steps or NewPool(NewStep)
  local pool = holder.steps
  pool.used = 0
  holder.drawn = holder.drawn or {}
  Wipe(holder.drawn)

  -- a long run of done steps folds into one line, plus the last two
  local first, doneRun = 1, 0
  for _, step in ipairs(chain.steps) do
    if step.done and not step.target then doneRun = doneRun + 1 else break end
  end
  local y = 0
  if doneRun > S.MAX_DONE_SHOWN then
    local r = Take(pool, holder)
    r:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, y)
    r:SetWidth(width)
    y = y - PaintStep(r, nil, width, doneRun - 2)
    r.step = nil
    holder.drawn[#holder.drawn + 1] = r
    first = doneRun - 1
  end
  for i = first, #chain.steps do
    local r = Take(pool, holder)
    r:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, y)
    r:SetWidth(width)
    y = y - PaintStep(r, chain.steps[i], width)
    r.step = chain.steps[i]
    holder.drawn[#holder.drawn + 1] = r
  end
  Finish(pool)

  -- the buttons, for the step to do now (unless it's already in your log)
  local step = chain.nextIndex and chain.steps[chain.nextIndex]
  if not holder.mapButton then
    holder.mapButton = T.Button(holder, "Show on map", "red")
    holder.mapButton:SetScript("OnClick", OnShowMap)
    holder.trackButton = T.Button(holder, "Track next step", "red")
    holder.trackButton:SetScript("OnClick", OnTrack)
  end
  local mapB, trackB = holder.mapButton, holder.trackButton
  if step and not step.mine then
    mapB.step, trackB.step, trackB.forQuest = step, step, quest.id
    mapB:ClearAllPoints()
    mapB:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, y - 6)
    mapB:Show()
    trackB:SetLabel(ns.UI.TrackedID() == step.id and "Stop tracking" or "Track next step")
    trackB:ClearAllPoints()
    trackB:SetPoint("LEFT", mapB, "RIGHT", 6, 0)
    trackB:Show()
    y = y - 6 - 16
  else
    mapB:Hide()
    trackB:Hide()
  end
  holder:Show()
  return -y + 2
end

-- fills the open "How to get it" panel; returns its height
local function PaintHowTo(p, q, width)
  local why = q.why or {}
  local inner = width - 16
  local text = ns.Escape(why.text or "")
  if why.gold then
    -- "2 of 5" in gold, like the mockup's bold
    local gold = ns.Escape(why.gold)
    local s, e = text:find(gold, 1, true)
    if s then text = text:sub(1, s - 1) .. T.Color(gold, T.gold) .. text:sub(e + 1) end
  end
  if why.hint then
    -- the holder's name in gold, like the mockup's bold name
    local hint = ns.Escape(why.hint)
    local first = q.holders and q.holders[1] and ns.Escape(q.holders[1].name or "")
    if first and first ~= "" then
      local s, e = hint:find(first, 1, true)
      if s then hint = hint:sub(1, s - 1) .. T.Color(first, T.gold) .. hint:sub(e + 1) end
    end
    text = (text ~= "" and (text .. " ") or "") .. hint
  end
  local y = -6
  p.why:ClearAllPoints()
  p.why:SetPoint("TOPLEFT", 8, y)
  y = y - Wrapped(p.why, inner, text)

  p.extra:ClearAllPoints()
  p.extra:SetPoint("TOPLEFT", 8, y - 4)
  p.extra:SetWidth(inner)
  p.extra:Show()
  local extraH = S.HowToExtra(p.extra, q, inner) or 0
  if extraH > 0 then
    p.extra:SetHeight(extraH)
    y = y - 4 - extraH
  end

  if why.needsDB then
    local n = p.nudge
    n:ClearAllPoints()
    n:SetPoint("TOPLEFT", 8, y - 5)
    n:SetWidth(inner)
    local h = Wrapped(n.text, inner - 15, "Install " .. T.Color("QuestieDB", { 1, 1, 1 })
      .. " to see the full quest chain and where to start.")
    n:SetHeight(h + 8)
    n:Show()
    y = y - 5 - (h + 8)
  else
    p.nudge:Hide()
  end
  return -y + 6
end

local function PaintMissing(card, q, width)
  card.quest = q
  local c = LevelRGB(q.color)
  card.title:SetTextColor(c[1], c[2], c[3], 1)
  card.title:SetText(TitleText(q))

  local button
  if q.askable then
    card.info:Hide()
    button = card.ask
    button:SetStyle(S.Resting(q.id) and "grey" or "red")
  else
    card.ask:Hide()
    button = card.info
    button:SetLabel(howtoOpen[q.id] and "Hide" or "How to get it")
  end
  button:Show()
  card.title:SetWidth(math.max(40, width - QUEST_X - PAD - (button:GetWidth() or 80) - 6))

  local names = ns.Escape(q.holderNames or "")
  local sub = names .. ((#(q.holders or {}) == 1) and " has it" or " have it")
  if not q.askable then sub = sub .. " \194\183 can't be shared to you yet" end -- (a middle dot)
  local y = -21 - Wrapped(card.sub, width - SUB_X - PAD, sub)

  if not q.askable and howtoOpen[q.id] then
    local p = card.howto
    p:ClearAllPoints()
    p:SetPoint("TOPLEFT", SUB_X, y - 5)
    p:SetWidth(width - SUB_X - PAD)
    local h = PaintHowTo(p, q, width - SUB_X - PAD)
    p:SetHeight(h)
    p:Show()
    y = y - 5 - h - 2
  else
    card.howto:Hide()
  end
  local h = -y + 5
  card:SetHeight(h)
  return h
end

------------------------------------------------------------------------
-- Part 5: In progress
------------------------------------------------------------------------
local function OnQuestClick(self)
  local q = self.quest
  if not q then return end
  ns.SetQuestCollapsed(q.id, not q.collapsed)
  ns.UI.Refresh()
end

local function NewProgress(parent)
  local b = CreateFrame("Button", nil, parent)
  b:SetHeight(LINE + 4)
  T.Line(b, T.questLine, 0)
  b.title = T.Text(b, 13)
  b.title:SetPoint("TOPLEFT", QUEST_X, -4)
  b.title:SetWordWrap(false)
  b:SetScript("OnClick", OnQuestClick)
  return b
end

local function NewRow(parent)
  local r = CreateFrame("Frame", nil, parent)
  r:SetHeight(ROW_H)
  r.who = T.Text(r, 12)
  r.who:SetPoint("LEFT", SUB_X, 0)
  r.who:SetWidth(92)
  r.who:SetWordWrap(false)
  r.obj = T.Text(r, 12, T.objText)
  r.obj:SetPoint("LEFT", SUB_X + 92 + 6, 0)
  r.obj:SetWordWrap(false)
  -- the progress bar: a dark background with a black edge, and the fill
  local bar = CreateFrame("Frame", nil, r)
  bar:SetSize(BAR_W, BAR_H)
  bar:SetPoint("RIGHT", -PAD, 0)
  T.Fill(bar, T.barBg)
  T.Border(bar, { 0, 0, 0, 1 })
  local fill = CreateFrame("Frame", nil, bar)
  fill:SetPoint("TOPLEFT", 1, -1)
  fill:SetHeight(BAR_H - 2)
  fill.tone = T.TwoTone(fill, T.barTop, T.barBot, "ARTWORK")
  fill.tone:Fit(BAR_H - 2)
  r.bar, r.fill = bar, fill
  return r
end

-- one row: name (only on a person's first row), "label have/need" and the bar
local function PaintRow(r, holder, o, showName, width)
  if showName then
    local cr, cg, cb = ns.ClassColor(holder.class)
    r.who:SetTextColor(cr, cg, cb, 1)
    r.who:SetText(ns.Escape(holder.name or "?"))
  else
    r.who:SetText("")
  end
  local done, frac, text
  if o then
    done = o.done
    frac = (o.need and o.need > 0) and math.min(1, (o.have or 0) / o.need) or (done and 1 or 0)
    text = ns.Escape(o.label or "") .. " " .. (o.have or 0) .. "/" .. (o.need or 1)
  else
    -- (a quest without objectives: just done or not)
    done = holder.complete
    frac = done and 1 or 0
    text = done and "Done" or "In progress"
  end
  local c = done and T.good or T.objText
  r.obj:SetTextColor(c[1], c[2], c[3], 1)
  r.obj:SetText(text)
  r.obj:SetWidth(width - (SUB_X + 92 + 6) - PAD - BAR_W - 6)
  r.done = done -- (the tests read this)
  local fillW = math.floor((BAR_W - 2) * frac + 0.5)
  if fillW > 0 then
    r.fill:SetWidth(fillW)
    if done then r.fill.tone:SetColors(T.doneTop, T.doneBot) else r.fill.tone:SetColors(T.barTop, T.barBot) end
    r.fill:Show()
  else
    r.fill:Hide()
  end
end

local function PaintProgress(b, q)
  b.quest = q
  local c = LevelRGB(q.color)
  b.title:SetTextColor(c[1], c[2], c[3], 1)
  local text = TitleText(q)
  if q.collapsed then
    local left = (q.left or 0) > 0 and ("\226\128\147 " .. q.left .. " left (click)") or "\226\128\147 done (click)" -- (an en dash)
    text = text .. " " .. T.Color(left, T.dim)
  end
  b.title:SetText(text)
end

------------------------------------------------------------------------
-- Part 6: Ready to turn in
------------------------------------------------------------------------
local function NewReady(parent)
  local card = CreateFrame("Frame", nil, parent)
  T.Line(card, T.questLine, 0)
  card.title = T.Text(card, 13)
  card.title:SetPoint("TOPLEFT", QUEST_X, -4)
  card.title:SetWordWrap(false)
  card.sub = T.Text(card, 11, T.good)
  card.sub:SetPoint("TOPLEFT", SUB_X, -21)
  card.sub:SetWordWrap(true)
  return card
end

local function PaintReady(card, q, width)
  card.quest = q
  local c = LevelRGB(q.color)
  card.title:SetTextColor(c[1], c[2], c[3], 1)
  card.title:SetWidth(width - QUEST_X - PAD)
  card.title:SetText(TitleText(q))
  local h = 21 + Wrapped(card.sub, width - SUB_X - PAD,
    "Everyone's done \226\128\148 " .. ns.Escape(q.namesText or "")) + 5 -- (an em dash)
  card:SetHeight(h)
  return h
end

------------------------------------------------------------------------
-- Drawing it all
------------------------------------------------------------------------
local pools = {
  headers = NewPool(NewHeader),
  missing = NewPool(NewMissing),
  progress = NewPool(NewProgress),
  rows = NewPool(NewRow),
  ready = NewPool(NewReady),
}
local message -- the solo / raid line

function S.PoolSizes()
  local out = {}
  for k, p in pairs(pools) do out[k] = #p.list end
  return out
end

local SECTIONS = {
  { key = "missing",  label = "You're missing" },
  { key = "progress", label = "In progress" },
  { key = "ready",    label = "Ready to turn in" },
}

function S.Draw(content, view, width)
  for _, p in pairs(pools) do p.used = 0 end
  for _, list in pairs(S.drawn) do Wipe(list) end
  local drawn = S.drawn
  local y = 0

  if view.message then
    -- on your own or in a raid: just the message
    if not message then
      message = T.Text(content, 12, T.text)
      message:SetWordWrap(true)
      S.message = message -- (the tests read it)
    end
    message:ClearAllPoints()
    message:SetPoint("TOPLEFT", PAD, -10)
    message:Show()
    y = -10 - Wrapped(message, width - 2 * PAD, ns.Escape(view.message)) - 10
  else
    if message then message:Hide() end
    local folded = ns.db and ns.db.collapsed.sections or {}
    for _, sec in ipairs(SECTIONS) do
      local list = view[sec.key] or {}
      local h = Take(pools.headers, content)
      h.key = sec.key
      h:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
      h:SetWidth(width)
      h.text:SetText(sec.label:upper() .. " " .. T.Color("(" .. #list .. ")", T.dim))
      h.arrow:Point(folded[sec.key] and "right" or "down")
      drawn.headers[#drawn.headers + 1] = h
      y = y - 21

      if not folded[sec.key] then
        for _, q in ipairs(list) do
          if sec.key == "missing" then
            local card = Take(pools.missing, content)
            card:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
            card:SetWidth(width)
            y = y - PaintMissing(card, q, width)
            drawn.missing[#drawn.missing + 1] = card

          elseif sec.key == "progress" then
            local b = Take(pools.progress, content)
            b:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
            b:SetWidth(width)
            PaintProgress(b, q)
            drawn.progress[#drawn.progress + 1] = b
            y = y - (LINE + 4)
            if not q.collapsed then
              for _, holder in ipairs(q.holders or {}) do
                local objs = holder.objectives or {}
                for i = 1, math.max(1, #objs) do
                  local r = Take(pools.rows, content)
                  r:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
                  r:SetWidth(width)
                  PaintRow(r, holder, objs[i], i == 1, width)
                  drawn.rows[#drawn.rows + 1] = r
                  y = y - ROW_H
                end
              end
            end
            y = y - 5

          else
            local card = Take(pools.ready, content)
            card:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
            card:SetWidth(width)
            y = y - PaintReady(card, q, width)
            drawn.ready[#drawn.ready + 1] = card
          end
        end
      end
    end
    y = y - 4
  end

  for _, p in pairs(pools) do Finish(p) end
  return -y
end
