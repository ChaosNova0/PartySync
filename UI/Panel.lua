-- Panel: the main window, PartySyncFrame. It draws mockup parts 1 (title
-- bar), 2 (zone filter), 3 (party strip) and 7 (footer), and hands the
-- middle (parts 4-6) to UI/Sections.lua. Everything it shows comes from
-- ns.Model.Build() (see Model.lua for that table's shape); it never reads
-- the party's data directly.
--
-- It's a plain frame with nothing secure in it, so it opens, closes, moves
-- and refreshes in combat too. Escape closes it (UISpecialFrames).
-- It's only built the first time it's needed: opened with /psync or the
-- minimap button, at login when it was left open, or when a party starts
-- (settings.autoOpen, see "Opening by itself" below).
--
-- Saved (PartySyncDB, see Core.lua):
--   window = { point, relPoint, x, y }   where it was dragged to (on drag stop),
--                                        always by its top-left corner
--   window.shown                         open or closed, so /reload keeps it
--   settings.zoneFilter                  the zone dropdown's choice
--   settings.alertDone ...               the gear menu's switches
--   settings.autoOpen                    open by itself when a party starts
--   minimap.hide                         the gear menu's "Show minimap button"
--   track = { questID, forQuest, owner } "Track next step" (IDs only, see Core.lua),
--                                        shown only to the character who tracked it
--
-- ns.UI (for the other UI files and the tests):
--   UI.Show(), UI.Hide(), ns.TogglePanel()
--   UI.OpenSettings(anchor)   the gear menu, under `anchor` (the gear when nil;
--                         the minimap button passes itself)
--   UI.Refresh()          rebuild now (only does anything while it's shown)
--   UI.RefreshSoon()      rebuild 0.2 s from now (several calls make one)
--   UI.Toast(text)        a short line above the panel; in chat when it's closed.
--                         `text` must already be escaped (ns.Escape).
--   UI.ResetPosition()
--   UI.SaveTopLeft(frame, spot), UI.PlaceTopLeft(frame, spot)   (the popup uses them too)
--   UI.MapToast(ok, how, giver)  the toast after Show on map
--   UI.frame, UI.view     the window, and the Model.Build() it last drew
--   UI.NameOf(guid)       a party member's name (for the share popup)
--   UI.Track(stepID, forQuest), UI.Untrack(), UI.TrackedID()
--                         "Track next step": a "Next: <quest> - <giver>, <zone>
--                         (<direction>)" line pinned under the title bar, plus a
--                         map pin when one can be placed. It clears itself when
--                         that quest turns up in your log (or you've handed it
--                         in), and its small X clears it too.
--   UI.TrackText()        that line's text, or nil when nothing is tracked

local _, ns = ...
local T = ns.Theme
local UI = {}
ns.UI = UI

UI.WIDTH = 340       -- the mockup's width
UI.MAX_HEIGHT = 520  -- taller than this and the middle scrolls
UI.TOAST_TIME = 2.2  -- seconds a toast stays (then it fades out)

local EDGE = 2       -- the window's edge, in pixels
local INNER = UI.WIDTH - 2 * EDGE  -- the width of everything inside
local TITLE_H, ZONE_H, FOOTER_H = 30, 26, 28
local NEXT_H = 20    -- the pinned "Next:" line, when something is tracked
local PAD = 8        -- the mockup's left and right padding

local f              -- PartySyncFrame, once built
local builtAt = 0    -- GetTime() of the last rebuild (for "synced Xs ago")
local ticker         -- the footer's 1 s timer, only while the panel is shown

------------------------------------------------------------------------
-- Position. Always kept by the top-left corner (see Core.lua), so when the
-- panel gets taller or shorter its top stays where it is.
------------------------------------------------------------------------
-- Where frame `fr` is now, saved into `spot` as its top-left corner from the
-- bottom-left of the screen, in UIParent's units (GetLeft / GetTop are in
-- the frame's own scale). Shared with the share popup.
function UI.SaveTopLeft(fr, spot)
  if not (fr and spot) then return end
  local left, top = fr:GetLeft(), fr:GetTop()
  if type(left) ~= "number" or type(top) ~= "number" then return end
  local s = (fr:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1)
  spot.point, spot.relPoint = "TOPLEFT", "BOTTOMLEFT"
  spot.x, spot.y = math.floor(left * s + 0.5), math.floor(top * s + 0.5)
end

-- Put frame `fr` at a saved spot (offsets turned back into its own scale)
function UI.PlaceTopLeft(fr, spot)
  local s = (fr:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1)
  if s <= 0 then s = 1 end
  fr:ClearAllPoints()
  fr:SetPoint("TOPLEFT", UIParent, spot.relPoint, spot.x / s, spot.y / s)
end

local function SavePosition()
  if ns.db then UI.SaveTopLeft(f, ns.db.window) end
end

local function Place()
  UI.PlaceTopLeft(f, ns.db.window)
end

function UI.ResetPosition()
  if not ns.db then return end
  local w, d = ns.db.window, ns.DEFAULTS.window
  w.point, w.relPoint, w.x, w.y = d.point, d.relPoint, d.x, d.y
  if f then Place() end
  ns.Print("The panel is back at the top of the screen.")
end

------------------------------------------------------------------------
-- The toast: a short line above the panel that fades away
------------------------------------------------------------------------
local toast
local function BuildToast()
  toast = CreateFrame("Frame", nil, f)
  toast:SetPoint("BOTTOM", f, "TOP", 0, 6)
  toast:SetHeight(22)
  T.Fill(toast, T.toastBg)
  T.Border(toast, T.gold)
  toast.text = T.Text(toast, 12, T.gold)
  toast.text:SetPoint("CENTER", 0, 0)
  toast.text:SetJustifyH("CENTER")
  toast.text:SetWordWrap(false)
  toast:Hide()
  -- The fade runs only while a toast is showing (the script is removed when
  -- it ends), and only every 0.05 s.
  local acc = 0
  local function Fade(self, elapsed)
    acc = acc + (elapsed or 0)
    if acc < 0.05 then return end
    acc = 0
    local left = self.untilTime - GetTime()
    if left <= 0 then
      self:SetScript("OnUpdate", nil)
      self:Hide()
      return
    end
    self:SetAlpha(math.min(1, left / 0.3)) -- the last 0.3 s fade out
  end
  toast.Fade = Fade
end

function UI.Toast(text)
  if not (f and f:IsShown()) then
    ns.Print(text)
    return
  end
  toast.text:SetText(text)
  toast:SetWidth(math.floor((toast.text:GetStringWidth() or 200) + 20))
  toast.untilTime = GetTime() + UI.TOAST_TIME
  toast.shownText = text -- (the tests read this)
  toast:SetAlpha(1)
  toast:Show()
  toast:SetScript("OnUpdate", toast.Fade)
end

-- The toast after Show on map (QDB.ShowOnMap's ok, how, giver)
function UI.MapToast(ok, how, g)
  if ok and how == "questie" then
    UI.Toast("Shown on your map by Questie: " .. ns.Escape(g.name))
  elseif ok then
    UI.Toast("Map pin added: " .. ns.Escape(g.name))
  elseif g then
    UI.Toast("Can't place a map pin. Head to " .. ns.Escape(g.name) .. (g.zone and (", " .. ns.Escape(g.zone)) or ""))
  else
    UI.Toast("Can't place a map pin: Questie doesn't say where this one starts.")
  end
end

------------------------------------------------------------------------
-- Part 1: the title bar and the gear menu
------------------------------------------------------------------------
local function Settings() return ns.db.settings end

local function SettingItem(text, key)
  return { text = text, checked = Settings()[key] and true or false, onClick = function()
    local s = Settings()
    s[key] = not s[key]
    UI.Refresh()
  end }
end

-- (it only needs the saved data, so the minimap button can open it even
-- before the panel has been built)
function UI.OpenSettings(anchor)
  if not ns.db then return end
  anchor = anchor or (f and f.gear)
  if not anchor then return end
  T.Menu(anchor, {
    SettingItem("Alert me when everyone's done", "alertDone"),
    SettingItem("Play a sound with the alert", "alertSound"),
    SettingItem("Let my party ask me to share", "allowAsks"),
    SettingItem("Show quests only I have", "showSolo"),
    SettingItem("Hide quests for other classes", "hideOtherClass"),
    SettingItem("Open when I'm in a party", "autoOpen"),
    { text = "Show minimap button", checked = not ns.db.minimap.hide,
      onClick = function() if ns.ToggleMinimapButton then ns.ToggleMinimapButton() end end },
    { text = "Reset position", onClick = UI.ResetPosition },
  }, 230)
end

local function BuildTitleBar()
  local bar = CreateFrame("Frame", nil, f)
  bar:SetPoint("TOPLEFT", EDGE, -EDGE)
  bar:SetPoint("TOPRIGHT", -EDGE, -EDGE)
  bar:SetHeight(TITLE_H)
  local tone = T.TwoTone(bar, T.titleTop, T.titleBot)
  tone:Fit(TITLE_H)
  T.Line(bar, T.edge, 0, true)
  -- drag to move; the spot is saved when you let go
  bar:EnableMouse(true)
  bar:RegisterForDrag("LeftButton")
  bar:SetScript("OnDragStart", function() f:StartMoving() end)
  -- (placed again by its top-left corner: the game may anchor a dragged
  -- frame by another one, and then a change of height would move it)
  bar:SetScript("OnDragStop", function() f:StopMovingOrSizing(); SavePosition(); Place() end)
  f.titleBar = bar

  local name = T.Text(bar, 14, T.gold)
  name:SetPoint("LEFT", PAD, 0)
  name:SetText("PartySync")

  local close = T.CloseButton(bar, function() UI.Hide() end)
  close:SetPoint("RIGHT", -PAD, 0)
  f.close = close

  local gear = CreateFrame("Button", nil, bar)
  gear:SetSize(18, 18)
  gear:SetPoint("RIGHT", close, "LEFT", -3, 0)
  T.Fill(gear, T.BUTTON.title.top)
  T.Border(gear, T.boxEdge)
  local icon = gear:CreateTexture(nil, "ARTWORK")
  icon:SetSize(14, 14)
  icon:SetPoint("CENTER")
  icon:SetTexture("Interface\\Buttons\\UI-OptionsButton")
  local c = T.BUTTON.title.text
  icon:SetVertexColor(c[1], c[2], c[3], 1)
  gear:SetScript("OnEnter", function(self)
    icon:SetVertexColor(T.gold[1], T.gold[2], T.gold[3], 1)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Settings")
    GameTooltip:Show()
  end)
  gear:SetScript("OnLeave", function()
    icon:SetVertexColor(c[1], c[2], c[3], 1)
    GameTooltip:Hide()
  end)
  gear:SetScript("OnClick", function() UI.OpenSettings() end)
  f.gear = gear
end

------------------------------------------------------------------------
-- The pinned "Next:" line ("Track next step"), under the title bar
------------------------------------------------------------------------
local function Track() return ns.db and ns.db.track end

-- The tracked step belongs to the character who tracked it (saved data is
-- per account): other characters don't see it, and it's kept for its owner.
-- A step saved before owners were kept goes to the first character to look.
local function MyGUID() return ns.Group and ns.Group.MyGUID() end

function UI.TrackedID()
  local t = Track()
  if not t or t.questID == 0 then return nil end
  local me = MyGUID()
  if not me then return nil end
  if t.owner == "" then t.owner = me end
  if t.owner ~= me then return nil end
  return t.questID
end

-- "Next: Note to William - Gramma Stonefield, Elwynn Forest (south-west)",
-- escaped. Names come from Questie each session (they're never saved), so
-- without it the line just says which quest.
function UI.TrackText()
  local id = UI.TrackedID()
  if not id then return nil end
  local QDB = ns.QDB
  local q = QDB and QDB.Quest(id)
  local text = "Next: " .. ns.Escape((q and q.name) or ("quest " .. id))
  local g = q and QDB.Giver(id)
  if g then
    local where = ns.Escape(g.name)
    if g.zone then where = where .. ", " .. ns.Escape(g.zone) end
    if g.dir then where = where .. " (" .. g.dir .. ")" end
    text = text .. " \226\128\147 " .. where -- (an en dash)
  end
  return text
end

function UI.Track(stepID, forQuest)
  local t = Track()
  local me = MyGUID()
  if not t or type(stepID) ~= "number" or not me then return end
  t.questID, t.forQuest, t.owner = stepID, type(forQuest) == "number" and forQuest or 0, me
  -- (a map pin too, when one can be placed; quietly skipped when not)
  if ns.QDB then ns.QDB.ShowOnMap(stepID) end
  UI.Refresh()
end

function UI.Untrack()
  local t = Track()
  -- (only the owner's step: another character's is left alone)
  if not t or not UI.TrackedID() then return end
  t.questID, t.forQuest, t.owner = 0, 0, ""
  UI.Refresh()
end

-- the tracked step is in our log now (or handed in): done with it
local function CheckTrack()
  local id = UI.TrackedID()
  if not id then return end
  if ns.mine.quests[id] or ns.QuestLog.IsDone(id) == true then UI.Untrack() end
end
UI.CheckTrack = CheckTrack

local function BuildNextRow()
  local row = CreateFrame("Button", nil, f)
  row:SetPoint("TOPLEFT", f.titleBar, "BOTTOMLEFT", 0, 0)
  row:SetPoint("TOPRIGHT", f.titleBar, "BOTTOMRIGHT", 0, 0)
  row:SetHeight(NEXT_H)
  T.Fill(row, T.boxBg)
  T.Line(row, T.line, 0, true)
  row.text = T.Text(row, 12, T.gold)
  row.text:SetPoint("LEFT", PAD, 0)
  row.text:SetWidth(INNER - 2 * PAD - 20)
  row.text:SetWordWrap(false)
  local close = T.CloseButton(row, function() UI.Untrack() end)
  close:SetSize(14, 14)
  close:SetPoint("RIGHT", -PAD, 0)
  row.close = close
  -- clicking the line shows the step on the map again
  row:SetScript("OnClick", function()
    local id = UI.TrackedID()
    if id and ns.QDB then UI.MapToast(ns.QDB.ShowOnMap(id)) end
  end)
  row:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Your next step")
    local d = T.dim
    GameTooltip:AddLine("Click to show it on the map. The X stops tracking it.", d[1], d[2], d[3], true)
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", function() GameTooltip:Hide() end)
  row:Hide()
  f.nextRow = row
end

-- shows or hides the line and hangs the zone row under whichever is last;
-- returns the line's height (0 when hidden)
local function PaintNext()
  local text = UI.TrackText()
  local row = f.nextRow
  f.zoneRow:ClearAllPoints()
  if text then
    row.text:SetText(text)
    row:Show()
    f.zoneRow:SetPoint("TOPLEFT", row, "BOTTOMLEFT", 0, 0)
    f.zoneRow:SetPoint("TOPRIGHT", row, "BOTTOMRIGHT", 0, 0)
    return NEXT_H
  end
  row:Hide()
  f.zoneRow:SetPoint("TOPLEFT", f.titleBar, "BOTTOMLEFT", 0, 0)
  f.zoneRow:SetPoint("TOPRIGHT", f.titleBar, "BOTTOMRIGHT", 0, 0)
  return 0
end

------------------------------------------------------------------------
-- Part 2: the zone filter
------------------------------------------------------------------------
local function PickZone(value)
  Settings().zoneFilter = value
  UI.Refresh()
end

function UI.OpenZoneMenu()
  local view = UI.view
  if not view then return end
  local items = {}
  for i, ch in ipairs(view.zone.choices) do
    local label = ns.Escape(ch.label)
    -- the choice in use is gold
    items[i] = { text = ch.value == view.zone.filter and T.Color(label, T.gold) or label,
                 value = ch.value, onClick = function() PickZone(ch.value) end }
  end
  T.Menu(f.zoneButton, items, 220)
end

local function BuildZoneRow()
  local row = CreateFrame("Frame", nil, f)
  row:SetPoint("TOPLEFT", f.titleBar, "BOTTOMLEFT", 0, 0)
  row:SetPoint("TOPRIGHT", f.titleBar, "BOTTOMRIGHT", 0, 0)
  row:SetHeight(ZONE_H)
  T.Line(row, T.line, 0, true)

  local dd = CreateFrame("Button", nil, row)
  dd:SetHeight(18)
  dd:SetPoint("LEFT", PAD, 0)
  T.Fill(dd, T.boxBg)
  T.Border(dd, T.boxEdge)
  dd.text = T.Text(dd, 13, T.gold)
  dd.text:SetPoint("LEFT", 6, 0)
  dd.text:SetWordWrap(false)
  dd.arrow = T.Chevron(dd, T.dim)
  dd.arrow:SetPoint("RIGHT", -5, 0)
  dd:SetScript("OnClick", function() UI.OpenZoneMenu() end)
  dd:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Zone filter")
    GameTooltip:Show()
  end)
  dd:SetScript("OnLeave", function() GameTooltip:Hide() end)
  f.zoneButton = dd

  f.sharedText = T.Text(row, 12, T.dim)
  f.sharedText:SetPoint("RIGHT", -PAD, 0)
  f.sharedText:SetJustifyH("RIGHT")
  f.zoneRow = row
end

local function PaintZone(view)
  local dd = f.zoneButton
  dd.text:SetText(ns.Escape(view.zone.label))
  -- the dropdown fits its text, but leaves room for the count on the right
  local w = math.min(INNER - 2 * PAD - 110, math.floor((dd.text:GetStringWidth() or 100) + 1))
  dd.text:SetWidth(w)
  dd:SetWidth(w + 22)
  local n = view.sharedCount or 0
  f.sharedText:SetText(n .. (n == 1 and " shared quest" or " shared quests"))
end

------------------------------------------------------------------------
-- Part 3: the party strip
------------------------------------------------------------------------
local DOT = 6
local memberPool = {} -- reusable name buttons
local function MemberTooltip(self)
  local p = self.person
  if not p then return end
  GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
  local r, g, b = ns.ClassColor(p.class)
  GameTooltip:AddLine(ns.Escape(p.name or "?"), r, g, b)
  local d = T.dim
  if p.isMe then
    GameTooltip:AddLine("You", d[1], d[2], d[3])
  elseif p.hasAddon == true then
    GameTooltip:AddLine(p.versionNote and ("Has PartySync, but " .. ns.Escape(p.versionNote)) or "Has PartySync",
      d[1], d[2], d[3], true)
  elseif p.hasAddon == false then
    GameTooltip:AddLine("Doesn't have PartySync, so we can't see their quests.", d[1], d[2], d[3], true)
  else
    GameTooltip:AddLine("Checking whether they have PartySync...", d[1], d[2], d[3], true)
  end
  if p.offline then GameTooltip:AddLine("Offline", d[1], d[2], d[3]) end
  GameTooltip:Show()
end

local function NewMember(parent)
  local b = CreateFrame("Button", nil, parent)
  b:SetHeight(16)
  -- filled dot: has PartySync. Hollow dot: doesn't (or not known yet).
  b.dot = CreateFrame("Frame", nil, b)
  b.dot:SetSize(DOT, DOT)
  b.dot:SetPoint("LEFT", 0, 0)
  b.dotFill = T.Fill(b.dot, { 1, 1, 1, 1 }, "ARTWORK")
  b.dotRing = T.Border(b.dot, { 1, 1, 1, 1 }, "ARTWORK")
  b.text = T.Text(b, 12)
  b.text:SetPoint("LEFT", b.dot, "RIGHT", 4, 0)
  b.text:SetWordWrap(false)
  b:SetScript("OnEnter", MemberTooltip)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return b
end

-- lays the names out left to right, wrapping like the mockup; returns the height
local function PaintParty(view)
  local strip = f.party
  local x, y, lineH = PAD, -5, 16
  local maxX = INNER - PAD
  for i, p in ipairs(view.party) do
    local b = memberPool[i]
    if not b then b = NewMember(strip) memberPool[i] = b end
    b.person = p
    local label = ns.Escape(p.name or "?")
    if p.isMe then label = label .. " (you)" end
    if p.offline then label = label .. " (offline)" end
    b.text:SetText(label)
    local r, g, bl = ns.ClassColor(p.class)
    b.text:SetTextColor(r, g, bl, 1)
    local filled = p.hasAddon == true
    b.dotFill:SetShown(filled)
    for _, e in ipairs(b.dotRing) do e:SetColorTexture(r, g, bl, filled and 0 or 1) end
    b.dotFill:SetColorTexture(r, g, bl, 1)
    b:SetAlpha(p.hasAddon == false and 0.55 or 1)
    local w = math.min(maxX - PAD, DOT + 4 + math.floor((b.text:GetStringWidth() or 60) + 1))
    b.text:SetWidth(w - DOT - 4)
    b:SetWidth(w)
    if x > PAD and x + w > maxX then x, y = PAD, y - lineH end
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", strip, "TOPLEFT", x, y)
    b:Show()
    x = x + w + 10
  end
  for i = #view.party + 1, #memberPool do memberPool[i]:Hide() end
  local h = -y + lineH + 5
  strip:SetHeight(h)
  return h
end

------------------------------------------------------------------------
-- Part 7: the footer
------------------------------------------------------------------------
local function SyncedText()
  local view = UI.view
  if not view or view.synced == nil then return "not synced yet" end
  local s = view.synced + math.max(0, math.floor(GetTime() - builtAt))
  if s < 60 then return ("synced %ds ago"):format(s) end
  if s < 3600 then return ("synced %dm ago"):format(math.floor(s / 60)) end
  return "synced over an hour ago"
end

function UI.UpdateFooter()
  if f then f.syncedText:SetText(SyncedText()) end
end

local function BuildFooter()
  local foot = CreateFrame("Frame", nil, f)
  foot:SetPoint("BOTTOMLEFT", EDGE, EDGE)
  foot:SetPoint("BOTTOMRIGHT", -EDGE, EDGE)
  foot:SetHeight(FOOTER_H)
  T.Line(foot, T.edge, 0)
  f.alertToggle = T.Toggle(foot, "Alert me when everyone's done", function(on)
    Settings().alertDone = on
  end)
  f.alertToggle:SetPoint("LEFT", PAD, 0)
  f.syncedText = T.Text(foot, 12, T.dim)
  f.syncedText:SetPoint("RIGHT", -PAD, 0)
  f.syncedText:SetJustifyH("RIGHT")
  f.footer = foot
end

------------------------------------------------------------------------
-- The middle: a scrolling area for parts 4-6 (an earlier addon's plain ScrollFrame
-- with the mouse wheel, no template)
------------------------------------------------------------------------
local function ScrollTo(v)
  local scroll, content = f.scroll, f.content
  -- (the height Refresh worked out: right after a resize the game may not
  -- have measured the scroll frame again yet)
  local viewH = f.viewH or 0
  local max = math.max(0, (content:GetHeight() or 0) - viewH)
  v = math.max(0, math.min(max, v or 0))
  scroll:SetVerticalScroll(v)
  -- a thin marker on the right shows where you are, only when it scrolls
  local view, total = viewH, content:GetHeight() or 0
  if max > 0 and total > 0 then
    local h = math.max(20, view * view / total)
    f.scrollMark:SetHeight(h)
    f.scrollMark:ClearAllPoints()
    f.scrollMark:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", -1, -(view - h) * (v / max))
    f.scrollMark:Show()
  else
    f.scrollMark:Hide()
  end
end
UI.ScrollTo = function(v) if f then ScrollTo(v) end end

local function BuildBody()
  f.party = CreateFrame("Frame", nil, f)
  f.party:SetPoint("TOPLEFT", f.zoneRow, "BOTTOMLEFT", 0, 0)
  f.party:SetPoint("TOPRIGHT", f.zoneRow, "BOTTOMRIGHT", 0, 0)
  f.party:SetHeight(26)
  T.Line(f.party, T.line, 0, true)

  local scroll = CreateFrame("ScrollFrame", nil, f)
  scroll:SetPoint("TOPLEFT", f.party, "BOTTOMLEFT", 0, 0)
  scroll:SetPoint("BOTTOMRIGHT", f.footer, "TOPRIGHT", 0, 0)
  if scroll.SetClipsChildren then scroll:SetClipsChildren(true) end
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(INNER, 10)
  scroll:SetScrollChild(content)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(self, delta) ScrollTo((self:GetVerticalScroll() or 0) - delta * 32) end)
  local mark = scroll:CreateTexture(nil, "OVERLAY")
  mark:SetWidth(2)
  mark:SetColorTexture(T.gold[1], T.gold[2], T.gold[3], 0.35)
  mark:Hide()
  f.scroll, f.content, f.scrollMark = scroll, content, mark
end

------------------------------------------------------------------------
-- Building and refreshing
------------------------------------------------------------------------
local function Build()
  f = CreateFrame("Frame", "PartySyncFrame", UIParent)
  UI.frame = f
  f:Hide()
  f:SetSize(UI.WIDTH, 200)
  f:SetFrameStrata("MEDIUM")
  f:SetToplevel(true)
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  table.insert(UISpecialFrames, "PartySyncFrame") -- Escape closes it

  -- the panel, a 2px brown edge and a thin black line around that
  T.Fill(f, T.panel)
  T.Border(f, T.edge)
  local inner = CreateFrame("Frame", nil, f)
  inner:SetPoint("TOPLEFT", 1, -1)
  inner:SetPoint("BOTTOMRIGHT", -1, 1)
  T.Border(inner, T.edge)
  local outline = CreateFrame("Frame", nil, f)
  outline:SetPoint("TOPLEFT", -1, 1)
  outline:SetPoint("BOTTOMRIGHT", 1, -1)
  T.Border(outline, { 0, 0, 0, 1 })

  BuildTitleBar()
  BuildNextRow()
  BuildZoneRow()
  BuildFooter()
  BuildBody()
  BuildToast()
  Place()

  f:SetScript("OnShow", function()
    ns.db.window.shown = true
    if ticker then ticker:Cancel() end
    ticker = ns.NewTicker(1, UI.UpdateFooter)
    UI.Refresh()
  end)
  f:SetScript("OnHide", function(self)
    -- (IsShown stays true when only the whole UI is hidden, e.g. Alt+Z, so
    -- that doesn't count as closing it)
    ns.db.window.shown = self:IsShown() and true or false
    if ticker then ticker:Cancel() ticker = nil end
    T.CloseMenu()
  end)
end

function UI.Refresh()
  if not (f and f:IsShown()) then return end
  local view = ns.Model.Build()
  UI.view = view
  builtAt = GetTime()

  local nextH = PaintNext()
  PaintZone(view)
  local partyH = PaintParty(view)
  f.alertToggle:SetChecked(view.alertDone)
  UI.UpdateFooter()

  local bodyH = ns.UI.Sections.Draw(f.content, view, INNER)
  f.content:SetHeight(math.max(1, bodyH))
  local fixed = 2 * EDGE + TITLE_H + nextH + ZONE_H + partyH + FOOTER_H
  local total = math.min(UI.MAX_HEIGHT, fixed + bodyH)
  f:SetHeight(total)
  f.viewH = total - fixed
  f.scroll:SetHeight(f.viewH)
  ScrollTo(f.scroll:GetVerticalScroll() or 0)
end

function UI.RefreshSoon()
  if f and f:IsShown() then ns.Coalesce("panel", 0.2, UI.Refresh) end
end

function UI.Show()
  if not ns.db then return end
  if not f then Build() end
  f:Show()
end

function UI.Hide()
  if f then f:Hide() end
end

function UI.IsShown() return f ~= nil and f:IsShown() end

function ns.TogglePanel()
  if UI.IsShown() then UI.Hide() else UI.Show() end
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------
ns.On("CHANGED", UI.RefreshSoon)
ns.On("ZONE_CHANGED", UI.RefreshSoon)
-- (fires after every scan of our log that changed something, login included)
ns.On("MINE_CHANGED", CheckTrack)

-- open again after /reload or logging in if it was open before
-- (on your own too; in a party, "Opening by itself" below opens it anyway)
ns.RegisterEvent("PLAYER_LOGIN", function()
  if ns.db and ns.db.window.shown then UI.Show() end
end)

------------------------------------------------------------------------
-- Opening by itself when you're in a party (settings.autoOpen)
------------------------------------------------------------------------
-- The panel opens at the moment a party starts for us:
--   - at login or /reload when we're already in one. Group.lua's first
--     roster build (at PLAYER_LOGIN, or a second later if the game hadn't
--     told us about the group yet) turns "solo" into "party", so waiting for
--     that ROSTER_CHANGED means the party is known before we open;
--   - when we join one, or a raid is turned into a party.
-- It never opens in a raid or on our own. Since it only opens when a party
-- starts, closing it keeps it closed for the rest of that party: it opens
-- again after leaving and joining a party, or the next login or /reload.
-- (Show doesn't take the keyboard or close anything, and nothing here is
-- protected, so this is fine in combat.)
local lastMode = "solo" -- Group.Mode() at the last roster change

ns.On("ROSTER_CHANGED", function()
  local mode = ns.Group and ns.Group.Mode() or "solo"
  local started = mode == "party" and lastMode ~= "party"
  lastMode = mode
  if started and ns.db and ns.db.settings.autoOpen and not UI.IsShown() then UI.Show() end
end)

-- the answer to one of our "Ask to share" requests
-- ("s" means they clicked Share; the game can still refuse the share itself,
-- for example when you can't take the quest, so it says "sharing")
local ANSWERS = {
  s = "%s is sharing it",
  n = "%s said not now",
  x = "%s can't share that one",
  o = "%s has share requests turned off",
}
local function NameOf(guid)
  local view = UI.view
  for pass = 1, 2 do
    if view then
      for _, p in ipairs(view.party) do
        if p.guid == guid then return p.name end
      end
    end
    -- (the panel may never have been opened: build the view once to find them)
    if pass == 1 then view = ns.Model.Build() end
  end
  return "Your party member"
end
UI.NameOf = NameOf

ns.On("SHARE_ANSWERED", function(fromGUID, _, code)
  local text = ANSWERS[code]
  if not text then return end
  UI.Toast(text:format(ns.Escape(NameOf(fromGUID))))
end)

ns.SlashHandlers.reset = function() UI.ResetPosition() end
