-- Theme: the mockup's colours and the few skinned widgets the panel is built
-- from. Trimmed from an earlier addon's theme file (Fill, Border, Text, Button,
-- Toggle, Menu, CloseButton) and recoloured to the mockup's Classic look:
-- gold text on a very dark warm panel, a brown edge, red and blue buttons.
--
-- Colours are { r, g, b, a } with values from 0 to 1. The mockup's CSS value
-- is in the comment next to each one.
-- Only plain textures and font strings are used, nothing secure, so every
-- widget here works in combat.

local _, ns = ...
local T = {}
ns.Theme = T

-- Questrial ships with PartySync (Media\Fonts, SIL Open Font License; see Questrial-OFL.txt).
-- It draws its letters smaller than most fonts at the same size, so we ask for it
-- about 10% bigger (the sizes in the code stay as they are).
-- If it can't be loaded, Arial Narrow is used instead, at the normal size.
T.FONT = "Interface\\AddOns\\PartySync\\Media\\Fonts\\Questrial-Regular.ttf"
T.FONT_SCALE = 1.1
T.FALLBACK_FONT = "Fonts\\ARIALN.TTF"

T.gold     = { 1, 0.82, 0 }                 -- #ffd100: titles, headers, button text
T.text     = { 0.91, 0.88, 0.78 }           -- #e8e0c8: normal text
T.dim      = { 0.54, 0.51, 0.44 }           -- #8a8270: counts, "have it", footer
T.objText  = { 0.81, 0.78, 0.68 }           -- #cfc6ad: objective and "why" text
T.good     = { 0.118, 1, 0 }                -- #1eff00: finished rows, "Everyone's done"
T.panel    = { 0.047, 0.039, 0.031, 0.92 }  -- rgba(12,10,8,.92): the window
T.edge     = { 0.353, 0.290, 0.165, 1 }     -- #5a4a2a: the window's edge and big lines
T.line     = { 0.173, 0.141, 0.086, 1 }     -- #2c2416: lines under the zone and party rows
T.questLine = { 0.122, 0.102, 0.063, 1 }    -- #1f1a10: the line above each quest
T.titleTop = { 0.165, 0.133, 0.086, 1 }     -- #2a2216: title bar, top half
T.titleBot = { 0.082, 0.067, 0.043, 1 }     -- #15110b: title bar, bottom half
T.barBg    = { 0.165, 0.141, 0.094, 1 }     -- #2a2418: progress bar background
T.barTop   = { 0.247, 0.639, 0.302, 1 }     -- #3fa34d: progress bar fill
T.barBot   = { 0.133, 0.400, 0.173, 1 }     -- #22662c
T.doneTop  = { 0.373, 0.890, 0.420, 1 }     -- #5fe36b: a finished row's bar
T.doneBot  = { 0.184, 0.604, 0.227, 1 }     -- #2f9a3a
T.boxEdge  = { 0.420, 0.333, 0.188, 1 }     -- #6b5530: dropdown and title-bar buttons
T.boxBg    = { 0.051, 0.043, 0.031, 1 }     -- #0d0b08: the dropdown
T.howtoBg  = { 0.157, 0.125, 0.071, 0.55 }  -- rgba(40,32,18,.55): "How to get it" panel
T.howtoEdge = { 0.227, 0.188, 0.125, 1 }    -- #3a3020
T.nudgeBg  = { 0.157, 0.235, 0.392, 0.25 }  -- rgba(40,60,100,.25): the QuestieDB nudge
T.nudgeBar = { 0.290, 0.416, 0.604, 1 }     -- #4a6a9a
T.nudgeText = { 0.81, 0.88, 1 }             -- #cfe0ff
T.toastBg  = { 0, 0, 0, 0.8 }               -- #000c

-- button styles: two-tone fill (top, bottom), edge and text colour
T.BUTTON = {
  red   = { top = { 0.541, 0.102, 0.063 }, bottom = { 0.290, 0.039, 0.024 },   -- #8a1a10 -> #4a0a06
            edge = { 0.541, 0.416, 0.165 }, text = T.gold },                    -- #8a6a2a
  info  = { top = { 0.165, 0.227, 0.353 }, bottom = { 0.071, 0.102, 0.173 },   -- #2a3a5a -> #121a2c
            edge = { 0.290, 0.416, 0.604 }, text = { 0.81, 0.88, 1 } },         -- #4a6a9a, #cfe0ff
  title = { top = { 0.227, 0.063, 0.063 }, bottom = { 0.227, 0.063, 0.063 },   -- #3a1010
            edge = T.boxEdge, text = { 0.788, 0.698, 0.478 } },                 -- #c9b27a
  -- a button that's resting (Ask to share, just after asking)
  grey  = { top = { 0.22, 0.21, 0.20 }, bottom = { 0.13, 0.12, 0.11 },
            edge = { 0.35, 0.33, 0.30 }, text = { 0.55, 0.53, 0.50 } },
}

-- "|cffrrggbb" for a colour, to colour part of a line of text
function T.Hex(c)
  local function B(v) return math.floor(math.max(0, math.min(1, v)) * 255 + 0.5) end
  return ("|cff%02x%02x%02x"):format(B(c[1]), B(c[2]), B(c[3]))
end

function T.Color(text, c) return T.Hex(c) .. text .. "|r" end

------------------------------------------------------------------------
-- Primitives
------------------------------------------------------------------------
-- a solid colour filling the whole frame
function T.Fill(frame, c, layer, sub)
  local t = frame:CreateTexture(nil, layer or "BACKGROUND", nil, sub)
  t:SetAllPoints()
  t:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
  return t
end

-- A two-tone fill: the top half one colour and the bottom half another.
-- It stands in for the mockup's soft gradients (the earlier addon has no gradient
-- helper, so this keeps to the APIs it already uses).
function T.TwoTone(frame, top, bottom, layer)
  local hi = frame:CreateTexture(nil, layer or "BACKGROUND")
  hi:SetPoint("TOPLEFT")
  hi:SetPoint("TOPRIGHT")
  local lo = frame:CreateTexture(nil, layer or "BACKGROUND")
  lo:SetPoint("TOPLEFT", hi, "BOTTOMLEFT")
  lo:SetPoint("BOTTOMRIGHT")
  local tone = { hi = hi, lo = lo }
  -- (the halves are re-measured whenever the frame's height is set again)
  function tone:Fit(height) hi:SetHeight(math.max(1, math.floor((height or 2) / 2))) end
  function tone:SetColors(t, b, alpha)
    hi:SetColorTexture(t[1], t[2], t[3], alpha or t[4] or 1)
    lo:SetColorTexture(b[1], b[2], b[3], alpha or b[4] or 1)
  end
  tone:SetColors(top, bottom)
  return tone
end

-- 1px border made of four textures (crisp at any UI scale), in colour c
function T.Border(frame, c, layer)
  local edges = {}
  local function Edge(p1, p2, horizontal)
    local t = frame:CreateTexture(nil, layer or "BORDER")
    t:SetPoint(p1)
    t:SetPoint(p2)
    if horizontal then t:SetHeight(1) else t:SetWidth(1) end
    edges[#edges + 1] = t
  end
  Edge("TOPLEFT", "TOPRIGHT", true)
  Edge("BOTTOMLEFT", "BOTTOMRIGHT", true)
  Edge("TOPLEFT", "BOTTOMLEFT", false)
  Edge("TOPRIGHT", "BOTTOMRIGHT", false)
  function frame:SetBorderColor(r, g, b, a) for _, e in ipairs(edges) do e:SetColorTexture(r, g, b, a or 1) end end
  frame:SetBorderColor(c[1], c[2], c[3], c[4])
  return edges
end

-- a horizontal 1px line across a frame, `y` pixels from its top (or its
-- bottom when fromBottom is set)
function T.Line(frame, c, y, fromBottom)
  local t = frame:CreateTexture(nil, "BORDER")
  t:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
  local p = fromBottom and "BOTTOM" or "TOP"
  t:SetPoint(p .. "LEFT", 0, y or 0)
  t:SetPoint(p .. "RIGHT", 0, y or 0)
  t:SetHeight(1)
  return t
end

-- Set our font, falling back to a built-in one if the file can't be loaded
function T.SetFont(obj, size, flags)
  size = size or 12
  if not obj:SetFont(T.FONT, math.floor(size * T.FONT_SCALE + 0.5), flags or "") then
    obj:SetFont(T.FALLBACK_FONT, size, flags or "")
  end
end

-- a font string: size in pixels, colour c (default the normal text colour)
function T.Text(parent, size, c, layer)
  local fs = parent:CreateFontString(nil, layer or "OVERLAY")
  T.SetFont(fs, size)
  fs:SetShadowColor(0, 0, 0, 0.8)
  fs:SetShadowOffset(1, -1)
  c = c or T.text
  fs:SetTextColor(c[1], c[2], c[3], c[4] or 1)
  fs:SetJustifyH("LEFT")
  return fs
end

-- A small chevron drawn from two rotated lines (the earlier addon's close-button
-- trick), for the dropdown and the fold arrows. :Point("down" | "right").
function T.Chevron(parent, c)
  local holder = CreateFrame("Frame", nil, parent)
  holder:SetSize(8, 8)
  local lines = {}
  for i = 1, 2 do
    local t = holder:CreateTexture(nil, "ARTWORK")
    t:SetSize(5, 1.5)
    t:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
    lines[i] = t
  end
  function holder:Point(dir)
    local a, b = lines[1], lines[2]
    a:ClearAllPoints()
    b:ClearAllPoints()
    if dir == "right" then
      -- ">" : "\" on top, "/" below
      a:SetPoint("CENTER", 0, 1.6)
      b:SetPoint("CENTER", 0, -1.6)
      if a.SetRotation then a:SetRotation(math.rad(-45)); b:SetRotation(math.rad(45)) end
    else
      -- "v" : "\" on the left, "/" on the right
      a:SetPoint("CENTER", -1.6, 0)
      b:SetPoint("CENTER", 1.6, 0)
      if a.SetRotation then a:SetRotation(math.rad(-45)); b:SetRotation(math.rad(45)) end
    end
  end
  holder:Point("down")
  return holder
end

------------------------------------------------------------------------
-- Widgets
------------------------------------------------------------------------
-- A small mockup button: style "red" (Ask to share), "info" (How to get
-- it) or "title" (the title bar's boxes). It sizes itself to its text.
--   b:SetLabel(text)   change the text (and width)
--   b:SetStyle(name)   change the colours ("grey" while it's resting)
function T.Button(parent, text, style, height)
  local b = CreateFrame("Button", nil, parent)
  height = height or 16
  b:SetHeight(height)
  local tone = T.TwoTone(b, T.BUTTON.red.top, T.BUTTON.red.bottom)
  tone:Fit(height)
  T.Border(b, T.BUTTON.red.edge)
  local fs = T.Text(b, 11)
  fs:SetPoint("CENTER", 0, 0)
  fs:SetJustifyH("CENTER")
  b.text = fs
  b.style = style or "red"
  local function Paint(hover)
    local s = T.BUTTON[b.style] or T.BUTTON.red
    -- hovering brightens it a little, like the mockup's brightness(1.25)
    local k = (hover and b.style ~= "grey") and 1.25 or 1
    local function Up(c) return { math.min(1, c[1] * k), math.min(1, c[2] * k), math.min(1, c[3] * k) } end
    tone:SetColors(Up(s.top), Up(s.bottom))
    b:SetBorderColor(s.edge[1], s.edge[2], s.edge[3], 1)
    fs:SetTextColor(s.text[1], s.text[2], s.text[3], 1)
  end
  b:SetScript("OnEnter", function() Paint(true) end)
  b:SetScript("OnLeave", function() Paint(false) end)
  function b:SetStyle(name) b.style = name; Paint(false) end
  function b:SetLabel(label)
    fs:SetText(label)
    b.label = label
    b:SetWidth(math.floor((fs:GetStringWidth() or 60) + 15))
  end
  b:SetLabel(text or "")
  Paint(false)
  return b
end

-- A tick box with a label, like the mockup's footer checkbox.
-- onChange(checked) runs when it's clicked; b:SetChecked(v) sets it quietly.
function T.Toggle(parent, label, onChange)
  local b = CreateFrame("Button", nil, parent)
  b:SetHeight(16)
  local box = CreateFrame("Frame", nil, b)
  box:SetSize(11, 11)
  box:SetPoint("LEFT", 0, 0)
  T.Fill(box, T.boxBg)
  T.Border(box, T.boxEdge)
  local tick = box:CreateTexture(nil, "OVERLAY")
  tick:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
  tick:SetSize(15, 15)
  tick:SetPoint("CENTER", 1, 0)
  local fs = T.Text(b, 12, T.dim)
  fs:SetPoint("LEFT", box, "RIGHT", 5, 0)
  fs:SetText(label)
  b:SetWidth(11 + 5 + math.floor(fs:GetStringWidth() or 120) + 4)
  b.label = fs
  b.checked = false
  local function Paint(hover)
    tick:SetShown(b.checked)
    local c = hover and T.text or T.dim
    fs:SetTextColor(c[1], c[2], c[3], 1)
  end
  b:SetScript("OnClick", function()
    b.checked = not b.checked
    Paint(true)
    onChange(b.checked)
  end)
  b:SetScript("OnEnter", function() Paint(true) end)
  b:SetScript("OnLeave", function() Paint(false) end)
  function b:SetChecked(v) b.checked = v and true or false; Paint(false) end
  Paint(false)
  return b
end

-- Flat "X" close button (two rotated lines), in the title bar's box style
function T.CloseButton(parent, onClick)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(18, 18)
  T.Fill(b, T.BUTTON.title.top)
  T.Border(b, T.boxEdge)
  local lines = {}
  local c = T.BUTTON.title.text
  for i, deg in ipairs({ 45, -45 }) do
    local t = b:CreateTexture(nil, "ARTWORK")
    t:SetColorTexture(c[1], c[2], c[3], 1)
    t:SetSize(10, 1.5)
    t:SetPoint("CENTER")
    if t.SetRotation then t:SetRotation(math.rad(deg)) end
    lines[i] = t
  end
  b:SetScript("OnEnter", function()
    for _, t in ipairs(lines) do t:SetColorTexture(T.gold[1], T.gold[2], T.gold[3], 1) end
  end)
  b:SetScript("OnLeave", function()
    for _, t in ipairs(lines) do t:SetColorTexture(c[1], c[2], c[3], 1) end
  end)
  b:SetScript("OnClick", onClick)
  return b
end

-- Dropdown-style popup menu at the mouse, closed by a click anywhere else.
--   items = { { text, onClick, checked = true | false | nil }, ... }
--   checked true/false draws a tick box in front of the text (nil: no box)
local menu, catcher
function T.CloseMenu()
  if menu then menu:Hide() end
  if catcher then catcher:Hide() end
end

function T.MenuShown() return menu ~= nil and menu:IsShown() end

function T.Menu(anchor, items, width)
  if not menu then
    catcher = CreateFrame("Button", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("FULLSCREEN")
    catcher:RegisterForClicks("AnyUp")
    catcher:SetScript("OnClick", T.CloseMenu)
    catcher:Hide()
    menu = CreateFrame("Frame", nil, UIParent)
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    T.Fill(menu, { 0.055, 0.047, 0.038, 0.98 })
    T.Border(menu, T.edge)
    menu.buttons = {}
    menu:Hide()
  end
  for _, b in ipairs(menu.buttons) do b:Hide() end
  width = width or 200
  local y = -4
  for i, item in ipairs(items) do
    local b = menu.buttons[i]
    if not b then
      b = CreateFrame("Button", nil, menu)
      b:SetHeight(20)
      local hl = b:CreateTexture(nil, "HIGHLIGHT")
      hl:SetAllPoints()
      hl:SetColorTexture(1, 1, 1, 0.06)
      local box = CreateFrame("Frame", nil, b)
      box:SetSize(11, 11)
      box:SetPoint("LEFT", 8, 0)
      T.Fill(box, T.boxBg)
      T.Border(box, T.boxEdge)
      b.box = box
      b.tick = box:CreateTexture(nil, "OVERLAY")
      b.tick:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
      b.tick:SetSize(15, 15)
      b.tick:SetPoint("CENTER", 1, 0)
      b.text = T.Text(b, 12, T.text)
      b.text:SetPoint("RIGHT", -8, 0)
      b.text:SetWordWrap(false)
      menu.buttons[i] = b
    end
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", 1, y)
    b:SetPoint("TOPRIGHT", -1, y)
    local hasBox = item.checked ~= nil
    b.box:SetShown(hasBox)
    b.tick:SetShown(item.checked == true)
    b.text:ClearAllPoints()
    b.text:SetPoint("LEFT", hasBox and 25 or 8, 0)
    b.text:SetPoint("RIGHT", -8, 0)
    b.text:SetText(item.text)
    b.item = item
    b:SetScript("OnClick", function(self) T.CloseMenu(); if self.item.onClick then self.item.onClick() end end)
    b:Show()
    y = y - 20
  end
  menu.items = items -- (the tests read what's in the open menu)
  menu:SetSize(width, -y + 4)
  menu:ClearAllPoints()
  -- open under the anchor; it's kept on the screen
  menu:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
  menu:SetClampedToScreen(true)
  catcher:Show()
  menu:Show()
  return menu
end
