-- Minimap: a round PartySync button on the edge of the minimap (the same
-- hand-made button an earlier addon uses: no library). Left click opens or
-- closes the panel, right click opens the gear menu's settings, and dragging
-- slides it around the minimap's edge. /psync minimap hides it (and brings
-- it back), and so does "Show minimap button" in the gear menu.
--
-- It's a plain button with nothing secure in it, so it works in combat too.
-- It's built at PLAYER_LOGIN, when the game's Minimap frame exists.
--
-- Saved (PartySyncDB, see Core.lua):
--   minimap = { angle, hide }   where it sits around the edge, in degrees
--                               (0 = right, 90 = top), and whether it's hidden
--
-- ns.Minimap (for the tests):
--   Minimap.button        the button, once built
--   Minimap.Place()       put it at the saved angle
-- ns.ToggleMinimapButton()   hide it, or show it again (with a chat line)

local ADDON, ns = ...
local T = ns.Theme
local MM = {}
ns.Minimap = MM

-- (built from the folder name, so it still works if the folder was renamed)
MM.ICON = "Interface\\AddOns\\" .. ADDON .. "\\Media\\logo.tga"
MM.SIZE = 30  -- the button's width and height, in pixels
MM.GAP = 8    -- how far its centre sits outside the minimap's edge

local button

local function Saved() return ns.db.minimap end

-- Put the button on the minimap's edge at the saved angle. cos and sin turn
-- the angle into a spot on a circle around the minimap's centre.
function MM.Place()
  if not button or not Minimap then return end
  local angle = math.rad(Saved().angle)
  local radius = (Minimap:GetWidth() or 140) / 2 + MM.GAP
  button:ClearAllPoints()
  button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

-- While dragging (and only then), every frame: the angle from the minimap's
-- centre to the mouse becomes the button's new angle. The mouse position is
-- in screen pixels, so it's divided by the minimap's scale first.
local function OnDragUpdate()
  local mx, my = Minimap:GetCenter()
  local cx, cy = GetCursorPosition()
  if type(mx) ~= "number" or type(my) ~= "number" or type(cx) ~= "number" or type(cy) ~= "number" then return end
  local scale = Minimap:GetEffectiveScale() or 1
  if scale <= 0 then scale = 1 end
  local dx, dy = cx / scale - mx, cy / scale - my
  -- (the mouse right on the centre gives no real angle: keep the old one)
  if dx == 0 and dy == 0 then return end
  local deg = math.deg(math.atan2(dy, dx)) % 360
  -- (deg ~= deg is only true for "not a number": never save one)
  if deg ~= deg then return end
  Saved().angle = deg
  MM.Place()
end

local function Tooltip(self)
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:AddLine("PartySync", T.gold[1], T.gold[2], T.gold[3])
  GameTooltip:AddLine("Click to open or close.", 1, 1, 1)
  GameTooltip:AddLine("Drag to move.", 1, 1, 1)
  GameTooltip:AddLine("Right-click for settings.", 1, 1, 1)
  local d = T.dim
  GameTooltip:AddLine("/psync minimap hides this button.", d[1], d[2], d[3])
  GameTooltip:Show()
end

local function OnClick(self, mouse)
  if mouse == "RightButton" and ns.UI and ns.UI.OpenSettings then
    GameTooltip:Hide()
    ns.UI.OpenSettings(self)
  else
    ns.TogglePanel()
  end
end

local function Create()
  if button or not Minimap or not ns.db then return end
  button = CreateFrame("Button", "PartySyncMinimapButton", Minimap)
  MM.button = button
  button:SetSize(MM.SIZE, MM.SIZE)
  button:SetFrameStrata("MEDIUM")
  button:SetFrameLevel((Minimap:GetFrameLevel() or 1) + 8)
  button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  button:RegisterForDrag("LeftButton")

  -- the logo is already a round framed badge, so it fills the button with
  -- no ring or mask around it
  local icon = button:CreateTexture(nil, "ARTWORK")
  icon:SetTexture(MM.ICON)
  icon:SetAllPoints()
  button.icon = icon
  icon:SetAlpha(0.9)

  button:SetScript("OnEnter", function(self) icon:SetAlpha(1); Tooltip(self) end)
  button:SetScript("OnLeave", function() icon:SetAlpha(0.9); GameTooltip:Hide() end)
  button:SetScript("OnClick", OnClick)
  button:SetScript("OnDragStart", function(self)
    GameTooltip:Hide()
    self:SetScript("OnUpdate", OnDragUpdate)
  end)
  button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  -- (hidden in the middle of a drag: stop following the mouse)
  button:SetScript("OnHide", function(self) self:SetScript("OnUpdate", nil) end)

  MM.Place()
  button:SetShown(not Saved().hide)
end
MM.Create = Create

function ns.ToggleMinimapButton()
  if not ns.db then return end
  local s = Saved()
  s.hide = not s.hide
  if not button then Create() end
  if button then button:SetShown(not s.hide) end
  ns.Print(s.hide and "Minimap button hidden. Type /psync minimap to bring it back." or "Minimap button shown.")
end

ns.RegisterEvent("PLAYER_LOGIN", Create)
ns.SlashHandlers.minimap = function() ns.ToggleMinimapButton() end
