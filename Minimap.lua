local addonName, ns = ...

-- Minimap button: left-click opens GroupGlance, right-click the settings, drag to move.

local button

local function UpdatePosition()
	local angle = math.rad(ns.db.minimapAngle)
	local radius = Minimap:GetWidth() / 2 + 5
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function OnDragUpdate()
	local mx, my = Minimap:GetCenter()
	local scale = Minimap:GetEffectiveScale()
	local cx, cy = GetCursorPosition()
	cx, cy = cx / scale, cy / scale
	ns.db.minimapAngle = math.deg(math.atan2(cy - my, cx - mx)) % 360
	UpdatePosition()
end

local function ShowTooltip(self)
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	GameTooltip:AddLine("GroupGlance")
	if ns.HasListing and ns.HasListing() then
		GameTooltip:AddLine("You are listed", 0.4, 1, 0.4)
	end
	GameTooltip:AddLine("Left-click: Looking For Group", 0.8, 0.8, 0.8)
	GameTooltip:AddLine("Right-click: settings", 0.8, 0.8, 0.8)
	GameTooltip:AddLine("Drag: move button", 0.8, 0.8, 0.8)
	GameTooltip:Show()
end

function ns.InitMinimapButton()
	if button then return end
	button = CreateFrame("Button", "GroupGlanceMinimapButton", Minimap)
	button:SetSize(31, 31)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(8)
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:RegisterForDrag("LeftButton")
	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	local background = button:CreateTexture(nil, "BACKGROUND")
	background:SetSize(20, 20)
	background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	background:SetPoint("TOPLEFT", 7, -5)

	local icon = button:CreateTexture(nil, "ARTWORK")
	icon:SetSize(17, 17)
	icon:SetTexture("Interface\\Icons\\INV_Misc_Spyglass_03")
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	icon:SetPoint("TOPLEFT", 7, -6)

	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetSize(53, 53)
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetPoint("TOPLEFT")

	button:SetScript("OnClick", function(self, mouse)
		if mouse == "RightButton" then
			ns.ShowSettingsMenu(self)
		else
			ns.ToggleWindow()
		end
	end)
	button:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", OnDragUpdate)
		GameTooltip:Hide()
	end)
	button:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
	end)
	button:SetScript("OnEnter", ShowTooltip)
	button:SetScript("OnLeave", function() GameTooltip:Hide() end)

	UpdatePosition()
	ns.UpdateMinimapButton()
end

function ns.UpdateMinimapButton()
	if button then button:SetShown(ns.db.showMinimap) end
end
