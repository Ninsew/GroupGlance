local addonName, ns = ...

-- "My Listing": list yourself or your group from inside GroupGlance.
-- Uses the same calls as Blizzard's listing page: C_LFGList.CreateListing / UpdateListing /
-- RemoveListing with { activityIDs, newPlayerFriendly, generalPlaystyle }, and
-- C_LFGListRoles.SetRoles for solo roles. The comment can only be read by the client from
-- Blizzard's own comment box, so that box is borrowed into this panel while it is shown.

local L = C_LFGList or {}
local ROW_H = 22

local panel, box, categoryDD, styleDD, newPlayerCheck, statusText, postButton, removeButton
local roleChecks = {}
local commentHolder, commentNote
local state = { category = nil, activities = {}, style = 0, newPlayer = false }
local pendingUpdate = false

local function RoleIconString(role)
	local c = ({ TANK = { 0, 19, 22, 41 }, HEALER = { 20, 39, 1, 20 }, DAMAGER = { 20, 39, 22, 41 } })[role]
	return ("|TInterface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES:16:16:0:0:64:64:%d:%d:%d:%d|t"):format(c[1], c[2], c[3], c[4])
end

function ns.HasListing()
	return L.HasActiveEntryInfo and L.HasActiveEntryInfo() or false
end

local function SelectedIDs()
	local ids = {}
	for id, on in pairs(state.activities) do
		if on then ids[#ids + 1] = id end
	end
	table.sort(ids)
	return ids
end

local function CanList()
	if IsInGroup() and not UnitIsGroupLeader("player") then
		return false, "Only the group leader can list the group."
	end
	return true
end

local function GetSoloRoles()
	if C_LFGListRoles and C_LFGListRoles.GetRoles then
		local ok, r = pcall(C_LFGListRoles.GetRoles)
		if ok and type(r) == "table" then return r end
	end
	return {}
end

--------------------------------------------------------------------------------
-- Blizzard's comment box
--------------------------------------------------------------------------------

local borrowed -- { frame, parent, points }

local function EnsureBlizzardUI()
	if not LFGListingComment then
		if GroupFinderVanillaStyle_LoadUI then pcall(GroupFinderVanillaStyle_LoadUI) end
	end
	return LFGListingComment
end

local function BorrowComment()
	local comment = EnsureBlizzardUI()
	if not comment then
		commentNote:SetText("Comment box unavailable - use Blizzard's window to add a comment.")
		commentNote:Show()
		return
	end
	commentNote:Hide()
	if borrowed then return end
	borrowed = { frame = comment, parent = comment:GetParent(), points = {}, strata = comment:GetFrameStrata() }
	for i = 1, comment:GetNumPoints() do borrowed.points[i] = { comment:GetPoint(i) } end
	borrowed.width, borrowed.height = comment:GetSize()
	comment:SetParent(commentHolder)
	comment:ClearAllPoints()
	comment:SetPoint("TOPLEFT", 6, -6)
	comment:SetPoint("BOTTOMRIGHT", -26, 6)
	comment:SetFrameLevel(commentHolder:GetFrameLevel() + 2)
	comment:Show()
	if comment.EditBox then comment.EditBox:SetWidth(commentHolder:GetWidth() - 36) end
end

local function ReturnComment()
	if not borrowed then return end
	local comment = borrowed.frame
	comment:SetParent(borrowed.parent)
	comment:ClearAllPoints()
	for _, p in ipairs(borrowed.points) do comment:SetPoint(unpack(p)) end
	comment:SetSize(borrowed.width, borrowed.height)
	if comment.EditBox then comment.EditBox:ClearFocus() end
	borrowed = nil
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local function UpdateStatus()
	if not panel then return end
	local listed = ns.HasListing()
	local canList, why = CanList()
	local ids = SelectedIDs()
	if listed then
		local info = L.GetActiveEntryInfo and L.GetActiveEntryInfo()
		local names = {}
		for _, id in ipairs(info and info.activityIDs or {}) do names[#names + 1] = ns.ActivityName(id) end
		statusText:SetText("|cff40ff40You are listed:|r " .. (#names > 0 and table.concat(names, ", ") or "?"))
		postButton:SetText("Update Listing")
	else
		statusText:SetText(canList and (#ids == 0 and "Pick one or more activities to list for." or "Not listed yet.") or ("|cffff6060" .. why .. "|r"))
		postButton:SetText(IsInGroup() and "List My Group" or "List Myself")
	end
	postButton:SetEnabled(canList and #ids > 0)
	removeButton:SetEnabled(listed and canList)
	local solo = not IsInGroup()
	for _, c in pairs(roleChecks) do c:SetEnabled(solo) end
end

-- Copies the active listing (or sensible defaults) into the panel.
local function LoadState()
	wipe(state.activities)
	state.style, state.newPlayer = 0, false
	local info = ns.HasListing() and L.GetActiveEntryInfo and L.GetActiveEntryInfo()
	if type(info) == "table" then
		for _, id in ipairs(info.activityIDs or {}) do state.activities[id] = true end
		state.newPlayer = info.newPlayerFriendly and true or false
		state.style = info.generalPlaystyle or 0
		local first = ns.GetActivityInfo(info.activityIDs and info.activityIDs[1])
		if first and first.categoryID then state.category = first.categoryID end
	end
	state.category = state.category or ns.db.category
	if not state.category then
		local cats = ns.GetCategories()
		state.category = cats[1] and cats[1].id
	end
	local roles = GetSoloRoles()
	if roleChecks.TANK then
		roleChecks.TANK:SetChecked(roles.tank and true or false)
		roleChecks.HEALER:SetChecked(roles.healer and true or false)
		roleChecks.DAMAGER:SetChecked(roles.dps and true or false)
	end
	newPlayerCheck:SetChecked(state.newPlayer)
end

local function RenderActivities()
	if not panel or not panel:IsShown() then return end
	box:SetDataProvider(CreateDataProvider(ns.GetActivities(state.category)), ScrollBoxConstants.RetainScrollPosition)
	if categoryDD.GenerateMenu then categoryDD:GenerateMenu() end
	if styleDD.GenerateMenu then styleDD:GenerateMenu() end
	UpdateStatus()
end

local function SaveSoloRoles()
	if IsInGroup() or not (C_LFGListRoles and C_LFGListRoles.SetRoles) then return end
	pcall(C_LFGListRoles.SetRoles, {
		tank = roleChecks.TANK:GetChecked() and true or false,
		healer = roleChecks.HEALER:GetChecked() and true or false,
		dps = roleChecks.DAMAGER:GetChecked() and true or false,
	})
end

local function Post()
	local ids = SelectedIDs()
	if #ids == 0 then return end
	local data = { activityIDs = ids, newPlayerFriendly = newPlayerCheck:GetChecked() and true or false }
	if state.style > 0 then data.generalPlaystyle = state.style end
	local fn = ns.HasListing() and L.UpdateListing or L.CreateListing
	pendingUpdate = true
	local ok, err = pcall(fn, data)
	if not ok and data.generalPlaystyle then
		-- Unknown field on this client: try again without the playstyle.
		data.generalPlaystyle = nil
		ok, err = pcall(fn, data)
		if ok then ns.Print("Listed, but this client did not accept the playstyle.") end
	end
	if not ok then
		pendingUpdate = false
		ns.Print("|cffff6060Could not list:|r " .. tostring(err))
		return
	end
	SaveSoloRoles()
	PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
end

local function Remove()
	if L.RemoveListing then
		pendingUpdate = true
		L.RemoveListing()
	end
end

--------------------------------------------------------------------------------
-- Activity rows
--------------------------------------------------------------------------------

local function InitActivityRow(row, a)
	if not row.check then
		row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
		row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
		row.check:SetSize(22, 22)
		row.check:SetPoint("LEFT", 2, 0)
		row.check:EnableMouse(false)
		row.label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		row.label:SetPoint("LEFT", row.check, "RIGHT", 2, 0)
		row.label:SetPoint("RIGHT", -70, 0)
		row.label:SetJustifyH("LEFT")
		row.label:SetWordWrap(false)
		row.levels = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
		row.levels:SetPoint("RIGHT", -6, 0)
		row:SetScript("OnClick", function(self)
			local id = self.activityID
			state.activities[id] = (not state.activities[id]) or nil
			self.check:SetChecked(state.activities[id] == true)
			PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
			UpdateStatus()
		end)
	end
	row.activityID = a.id
	row.label:SetText(a.name)
	row.check:SetChecked(state.activities[a.id] == true)
	local info = ns.GetActivityInfo(a.id) or {}
	local lo, hi = info.minLevelSuggestion or info.minLevel, info.maxLevelSuggestion or info.maxLevel
	if lo and hi and lo > 0 and hi > 0 then
		row.levels:SetText(lo == hi and tostring(lo) or (lo .. "-" .. hi))
	else
		row.levels:SetText("")
	end
end

--------------------------------------------------------------------------------
-- Panel
--------------------------------------------------------------------------------

function ns.BuildListingPanel(parent)
	panel = CreateFrame("Frame", nil, parent)
	panel:SetPoint("TOPLEFT", 4, -28)
	panel:SetPoint("BOTTOMRIGHT", -6, 26)
	panel:Hide()

	-- Left: category + activities
	categoryDD = CreateFrame("DropdownButton", nil, panel, "WowStyle1DropdownTemplate")
	categoryDD:SetWidth(180)
	categoryDD:SetPoint("TOPLEFT", 60, -3)
	categoryDD:SetupMenu(function(_, root)
		for _, c in ipairs(ns.GetCategories()) do
			root:CreateRadio(c.name, function() return state.category == c.id end, function()
				if state.category ~= c.id then
					state.category = c.id
					wipe(state.activities)
					RenderActivities()
				end
			end)
		end
	end)

	local left = CreateFrame("Frame", nil, panel, "InsetFrameTemplate")
	left:SetPoint("TOPLEFT", 0, -62)
	left:SetPoint("BOTTOMLEFT", 0, 0)
	left:SetPoint("RIGHT", panel, "CENTER", 20, 0)
	local leftTitle = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	leftTitle:SetPoint("BOTTOMLEFT", left, "TOPLEFT", 6, 4)
	leftTitle:SetText("Activities")

	box = CreateFrame("Frame", nil, left, "WowScrollBoxList")
	box:SetPoint("TOPLEFT", 4, -4)
	box:SetPoint("BOTTOMRIGHT", -20, 4)
	local bar = CreateFrame("EventFrame", nil, left, "MinimalScrollBar")
	bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 4, 0)
	bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 4, 0)
	local view = CreateScrollBoxListLinearView()
	view:SetElementExtent(ROW_H)
	view:SetElementInitializer("Button", InitActivityRow)
	ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)

	-- Right: options, roles, comment, buttons
	local right = CreateFrame("Frame", nil, panel)
	right:SetPoint("TOPLEFT", left, "TOPRIGHT", 12, 0)
	right:SetPoint("BOTTOMRIGHT", -8, 0)

	local styleLabel = right:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	styleLabel:SetPoint("TOPLEFT", 0, -2)
	styleLabel:SetText("Playstyle")
	styleDD = CreateFrame("DropdownButton", nil, right, "WowStyle1DropdownTemplate")
	styleDD:SetWidth(160)
	styleDD:SetPoint("LEFT", styleLabel, "RIGHT", 10, 0)
	styleDD:SetupMenu(function(_, root)
		root:CreateRadio("None", function() return state.style == 0 end, function() state.style = 0 end)
		for i = 1, 4 do
			local text = _G["GROUP_FINDER_GENERAL_PLAYSTYLE" .. i]
			if text then
				root:CreateRadio(text, function() return state.style == i end, function() state.style = i end)
			end
		end
	end)

	newPlayerCheck = CreateFrame("CheckButton", nil, right, "UICheckButtonTemplate")
	newPlayerCheck:SetSize(24, 24)
	newPlayerCheck:SetPoint("TOPLEFT", styleLabel, "BOTTOMLEFT", -4, -12)
	local npText = right:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	npText:SetPoint("LEFT", newPlayerCheck, "RIGHT", 2, 0)
	npText:SetText("New player friendly")

	local rolesLabel = right:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	rolesLabel:SetPoint("TOPLEFT", newPlayerCheck, "BOTTOMLEFT", 4, -10)
	rolesLabel:SetText("My roles")
	local prev
	for _, r in ipairs({ { "TANK", "Tank" }, { "HEALER", "Healer" }, { "DAMAGER", "DPS" } }) do
		local c = CreateFrame("CheckButton", nil, right, "UICheckButtonTemplate")
		c:SetSize(24, 24)
		if prev then c:SetPoint("LEFT", prev.text, "RIGHT", 12, 0) else c:SetPoint("TOPLEFT", rolesLabel, "BOTTOMLEFT", -4, -4) end
		c.text = right:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		c.text:SetPoint("LEFT", c, "RIGHT", 0, 0)
		c.text:SetText(RoleIconString(r[1]) .. " " .. r[2])
		c:SetScript("OnClick", function() if ns.HasListing() then SaveSoloRoles() end end)
		roleChecks[r[1]] = c
		prev = c
	end

	local commentLabel = right:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	commentLabel:SetPoint("TOPLEFT", roleChecks.TANK, "BOTTOMLEFT", 4, -12)
	commentLabel:SetText("Comment")
	commentHolder = CreateFrame("Frame", nil, right, "InsetFrameTemplate")
	commentHolder:SetPoint("TOPLEFT", commentLabel, "BOTTOMLEFT", -4, -4)
	commentHolder:SetPoint("RIGHT", right, "RIGHT", 0, 0)
	commentHolder:SetHeight(90)
	commentNote = commentHolder:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	commentNote:SetPoint("TOPLEFT", 8, -8)
	commentNote:SetPoint("BOTTOMRIGHT", -8, 8)
	commentNote:SetJustifyH("LEFT")
	commentNote:Hide()

	statusText = right:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	statusText:SetPoint("TOPLEFT", commentHolder, "BOTTOMLEFT", 4, -10)
	statusText:SetPoint("RIGHT", right, "RIGHT", 0, 0)
	statusText:SetJustifyH("LEFT")

	postButton = CreateFrame("Button", nil, right, "UIPanelButtonTemplate")
	postButton:SetSize(140, 24)
	postButton:SetPoint("TOPLEFT", statusText, "BOTTOMLEFT", -4, -10)
	postButton:SetScript("OnClick", Post)
	removeButton = CreateFrame("Button", nil, right, "UIPanelButtonTemplate")
	removeButton:SetSize(120, 24)
	removeButton:SetPoint("LEFT", postButton, "RIGHT", 6, 0)
	removeButton:SetText("Remove Listing")
	removeButton:SetScript("OnClick", Remove)

	panel:SetScript("OnShow", function()
		LoadState()
		BorrowComment()
		RenderActivities()
	end)
	panel:SetScript("OnHide", ReturnComment)

	local events = CreateFrame("Frame", nil, panel)
	for _, ev in ipairs({ "LFG_LIST_ACTIVE_ENTRY_UPDATE", "GROUP_ROSTER_UPDATE", "PARTY_LEADER_CHANGED" }) do
		pcall(events.RegisterEvent, events, ev)
	end
	events:SetScript("OnEvent", function(_, event, createdNew)
		if event == "LFG_LIST_ACTIVE_ENTRY_UPDATE" then
			if ns.HasListing() and (createdNew or pendingUpdate) then
				PlaySound(SOUNDKIT.PVP_ENTER_QUEUE)
			elseif not ns.HasListing() and pendingUpdate then
				PlaySound(SOUNDKIT.LFG_DENIED)
			end
			pendingUpdate = false
		end
		if panel:IsShown() then UpdateStatus() end
	end)
	-- Keep running while the panel is hidden, so the sounds still play.
	events:SetParent(UIParent)
	return panel
end
