local addonName, ns = ...

-- The GroupGlance window, built from Blizzard's own templates so it looks native:
-- ButtonFrameTemplate, WowStyle1DropdownTemplate menus, SearchBoxTemplate, ScrollBox + MinimalScrollBar.

local ROW_H, HEADER_H, ICON = 22, 22, 17
local WHISPER_ICON = "Interface\\GossipFrame\\GossipGossipIcon"

local frame, box, headerFrame, statusText, searchBox
local catDD, actDD, typeDD, roleDD, styleDD
local headers = {}
local entries, visible = {}, {}
local Refilter, mineButton

local STYLE_COLORS = {
	Competitive = { 1, 0.55, 0.2 },
	Relaxed = { 0.4, 0.9, 0.4 },
	Learning = { 0.45, 0.75, 1 },
	["Carry Offered"] = { 1, 0.82, 0 },
}

local TYPE_CHOICES = {
	{ "all", "Groups & singles" },
	{ "groups", "Groups only" },
	{ "singles", "Singles only" },
}

-- Columns: fixed widths, "activity" takes the rest.
local COLUMNS = {
	{ key = "leader", title = "Leader", width = 135 },
	{ key = "level", title = "Lvl", width = 34 },
	{ key = "activity", title = "Activity", flex = true },
	{ key = "zone", title = "Zone", width = 110 },
	{ key = "size", title = "Members", width = 106 },
	{ key = "style", title = "Style", width = 88 },
	{ key = "age", title = "Age", width = 44 },
	{ key = nil, title = "", width = 96 },
}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function ClassColor(class)
	local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if c then return c.r, c.g, c.b end
	return 0.8, 0.8, 0.8
end

local function HasAtlas(name)
	return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
end

local function SetClassIcon(tex, class)
	local atlas = class and ("classicon-" .. class:lower())
	if atlas and HasAtlas(atlas) then
		tex:SetTexCoord(0, 1, 0, 1)
		tex:SetAtlas(atlas)
		return true
	end
	local coords = class and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
	if coords then
		tex:SetTexture("Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes")
		tex:SetTexCoord(unpack(coords))
		return true
	end
	return false
end

local ROLE_ATLAS = { TANK = "roleicon-tiny-tank", HEALER = "roleicon-tiny-healer", DAMAGER = "roleicon-tiny-dps" }
local ROLE_COORDS = {
	TANK = { 0, 19 / 64, 22 / 64, 41 / 64 },
	HEALER = { 20 / 64, 39 / 64, 1 / 64, 20 / 64 },
	DAMAGER = { 20 / 64, 39 / 64, 22 / 64, 41 / 64 },
}

local function SetRoleIcon(tex, role)
	if not ROLE_COORDS[role] then
		tex:Hide()
		return
	end
	if HasAtlas(ROLE_ATLAS[role]) then
		tex:SetTexCoord(0, 1, 0, 1)
		tex:SetAtlas(ROLE_ATLAS[role])
	else
		tex:SetTexture("Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES")
		tex:SetTexCoord(unpack(ROLE_COORDS[role]))
	end
	tex:Show()
end

local function RoleIconString(role)
	local c = ROLE_COORDS[role]
	if not c then return "" end
	return ("|TInterface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES:14:14:0:0:64:64:%d:%d:%d:%d|t"):format(c[1] * 64, c[2] * 64, c[3] * 64, c[4] * 64)
end

local function FormatAge(sec)
	sec = math.max(0, math.floor(sec))
	if sec < 60 then return sec .. "s" end
	if sec < 3600 then return math.floor(sec / 60) .. "m" end
	return math.floor(sec / 3600) .. "h"
end

local function CurrentAge(e)
	return e.age + (GetTime() - e.fetched)
end

-- Grey/green/yellow/orange/red compared to your own level, like quests.
local function LevelColor(level)
	if type(level) ~= "number" or not GetQuestDifficultyColor then return 1, 1, 1 end
	local c = GetQuestDifficultyColor(level)
	if c then return c.r, c.g, c.b end
	return 1, 1, 1
end

local function MyRolesIcons()
	local s = ""
	local mine = ns.MyRoles()
	for _, role in ipairs({ "TANK", "HEALER", "DAMAGER" }) do
		if mine[role] then s = s .. RoleIconString(role) end
	end
	return s
end

local function Tooltip(widget, text)
	widget:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(text, 1, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	widget:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

local function PanelButton(parent, text, width, height)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, height or 22)
	b:SetText(text or "")
	return b
end

local function Dropdown(parent, width)
	local d = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
	d:SetWidth(width)
	return d
end

local function RefreshDropdown(d)
	if d and d.GenerateMenu then d:GenerateMenu() end
end

--------------------------------------------------------------------------------
-- Filtering and sorting
--------------------------------------------------------------------------------

local SORT_VALUE = {
	leader = function(e) return ns.Lower(e.leader) end,
	level = function(e) return e.leaderLevel or 0 end,
	activity = function(e) return ns.Lower(e.activityText) end,
	zone = function(e) return ns.Lower(e.zone) end,
	size = function(e) return e.numMembers end,
	style = function(e) return e.styleText end,
	age = function(e) return CurrentAge(e) end,
}

local function Passes(e, db, text, selected)
	if db.hideDelisted and e.delisted then return false end
	if ns.IsBlocked(e.leader) then return false end
	if db.typeFilter == "groups" and not e.isGroup then return false end
	if db.typeFilter == "singles" and e.isGroup then return false end
	if db.roleFilter == "mine" then
		local roles = e.isGroup and e.needs or e.offers
		local ok = false
		for role, on in pairs(ns.MyRoles()) do
			if on and roles[role] then ok = true break end
		end
		if not ok then return false end
	elseif db.roleFilter ~= "any" then
		local ok = e.isGroup and e.needs[db.roleFilter] or (not e.isGroup and e.offers[db.roleFilter])
		if not ok then return false end
	end
	if db.styleFilter ~= "any" and e.styleText ~= db.styleFilter then return false end
	if selected then
		local hit = false
		for _, id in ipairs(e.activityIDs) do
			if db.activities[id] then hit = true break end
		end
		if not hit then return false end
	end
	if text ~= "" and not e.searchText:find(text, 1, true) then return false end
	return true
end

local function ApplyFilters()
	local db = ns.db
	local text = searchBox and ns.Lower(searchBox:GetText()) or ""
	local selected = ns.SelectedActivities()
	wipe(visible)
	local groups, singles = 0, 0
	for _, e in ipairs(entries) do
		if Passes(e, db, text, selected) then
			visible[#visible + 1] = e
			if e.isGroup then groups = groups + 1 else singles = singles + 1 end
		end
	end
	local get = SORT_VALUE[db.sortKey] or SORT_VALUE.age
	local asc = db.sortAsc
	table.sort(visible, function(a, b)
		local va, vb = get(a), get(b)
		if va == vb then return a.id < b.id end
		if asc then return va < vb end
		return va > vb
	end)
	for i, e in ipairs(visible) do e.index = i end
	local hidden = #entries - #visible
	local status = ("%d groups, %d singles"):format(groups, singles)
	if hidden > 0 then status = status .. (" |cff888888(%d filtered)|r"):format(hidden) end
	if ns.searching then status = status .. "  |cffffd100Searching...|r" end
	if statusText then statusText:SetText(status) end
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

local function ShowEntryTooltip(row)
	local e = row.entry
	if not e then return end
	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	local r, g, b = ClassColor(e.leaderClass)
	GameTooltip:AddLine(e.leader or "?", r, g, b)
	if e.title and e.title ~= "" then GameTooltip:AddLine(e.title, 1, 1, 1, true) end
	for _, id in ipairs(e.activityIDs) do
		GameTooltip:AddLine(ns.ActivityName(id), 1, 0.82, 0)
	end
	if e.styleText ~= "" then GameTooltip:AddLine(e.styleText, 0.7, 0.7, 0.7) end
	if e.zone ~= "" then GameTooltip:AddLine(e.zone, 0.7, 0.7, 0.7) end
	if e.isNew then GameTooltip:AddLine("New listing", 1, 0.82, 0) end
	local w = ns.WhisperState(e.leader)
	if w then
		GameTooltip:AddLine(("You whispered them %s ago"):format(FormatAge(time() - w.sent)), 0.6, 0.8, 1)
		if w.replied then
			GameTooltip:AddLine(("They replied %s ago"):format(FormatAge(time() - w.replied)), 0.4, 1, 0.4)
		end
	end
	if e.comment and e.comment ~= "" then
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine(e.comment, 0.9, 0.9, 0.9, true)
	end
	if e.isGroup then
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine(("Members (%d%s)"):format(e.numMembers, e.maxPlayers and ("/" .. e.maxPlayers) or ""), 1, 0.82, 0)
		for _, m in ipairs(e.members) do
			local mr, mg, mb = ClassColor(m.class)
			local left = RoleIconString(m.role) .. " " .. (m.name or m.className or "?")
			local right = m.className or ""
			if type(m.level) == "number" then
				local lr, lg, lb = LevelColor(m.level)
				right = ("|cff%02x%02x%02x%d|r "):format(lr * 255, lg * 255, lb * 255, m.level) .. right
			end
			GameTooltip:AddDoubleLine(left, right, mr, mg, mb, mr, mg, mb)
		end
	else
		local roles = ""
		for _, role in ipairs({ "TANK", "HEALER", "DAMAGER" }) do
			if e.offers[role] then roles = roles .. RoleIconString(role) .. " " end
		end
		if roles ~= "" then GameTooltip:AddLine("Can play: " .. roles, 1, 1, 1) end
	end
	if e.delisted then GameTooltip:AddLine("Delisted", 1, 0.3, 0.3) end
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("Right-click for more options", 0.5, 0.5, 0.5)
	GameTooltip:Show()
end

local function ShowRowMenu(row)
	local e = row.entry
	if not e or not MenuUtil then return end
	MenuUtil.CreateContextMenu(row, function(_, root)
		root:CreateTitle(e.leader or "?")
		root:CreateButton("Whisper", function() ns.Whisper(e.leader) end)
		if not e.isGroup then
			root:CreateButton("Invite to group", function() ns.Invite(e.leader) end)
		end
		root:CreateDivider()
		root:CreateButton("Hide this player", function()
			ns.Block(e.leader)
			ns.Print(("Hiding %s. Undo it in the settings menu."):format(Ambiguate(e.leader, "none")))
			Refilter()
		end)
	end)
end

local function CreateMemberSlot(parent)
	local s = CreateFrame("Frame", nil, parent)
	s:SetSize(ICON, ICON)
	s.bg = s:CreateTexture(nil, "BACKGROUND")
	s.bg:SetAllPoints()
	s.bg:SetColorTexture(0, 0, 0, 0.5)
	s.class = s:CreateTexture(nil, "ARTWORK")
	s.class:SetPoint("TOPLEFT", 1, -1)
	s.class:SetPoint("BOTTOMRIGHT", -1, 1)
	s.role = s:CreateTexture(nil, "OVERLAY")
	return s
end

local function BuildRow(row)
	row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	row.stripe = row:CreateTexture(nil, "BACKGROUND")
	row.stripe:SetAllPoints()
	row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
	-- Gold edge and glow on listings that showed up since the window opened.
	row.newBar = row:CreateTexture(nil, "ARTWORK")
	row.newBar:SetColorTexture(1, 0.82, 0, 0.9)
	row.newBar:SetPoint("TOPLEFT")
	row.newBar:SetPoint("BOTTOMLEFT")
	row.newBar:SetWidth(2)
	row.newGlow = row:CreateTexture(nil, "BACKGROUND", nil, 1)
	row.newGlow:SetAllPoints()
	row.newGlow:SetColorTexture(1, 0.82, 0, 0.08)

	local function FS(template)
		local fs = row:CreateFontString(nil, "ARTWORK", template or "GameFontHighlightSmall")
		fs:SetWordWrap(false)
		fs:SetJustifyH("LEFT")
		return fs
	end
	row.leader = FS("GameFontNormal")
	row.level = FS()
	row.activity = FS()
	row.zone = FS()
	row.zone:SetTextColor(0.75, 0.75, 0.75)
	row.style = FS()
	row.age = FS("GameFontDisableSmall")
	row.sizeText = FS()
	row.whisperMark = row:CreateTexture(nil, "ARTWORK")
	row.whisperMark:SetTexture(WHISPER_ICON)
	row.whisperMark:SetSize(14, 14)
	row.slots = {}
	for s = 1, 5 do row.slots[s] = CreateMemberSlot(row) end

	row.whisper = PanelButton(row, "", 28, 20)
	local icon = row.whisper:CreateTexture(nil, "OVERLAY")
	icon:SetTexture(WHISPER_ICON)
	icon:SetSize(14, 14)
	icon:SetPoint("CENTER")
	Tooltip(row.whisper, "Whisper the leader")
	row.whisper:SetScript("OnClick", function() if row.entry then ns.Whisper(row.entry.leader) end end)

	row.join = PanelButton(row, "Join", 62, 20)
	row.join:SetNormalFontObject("GameFontNormalSmall")
	row.join:SetHighlightFontObject("GameFontHighlightSmall")
	row.join:SetScript("OnClick", function() if row.entry then ns.PrimaryAction(row.entry) end end)
	row.join:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(row.entry and row.entry.isGroup and "Whisper the leader to join" or "Invite this player to your group", 1, 1, 1)
		GameTooltip:Show()
	end)
	row.join:HookScript("OnLeave", function() GameTooltip:Hide() end)

	row:SetScript("OnClick", function(self, button)
		if button == "RightButton" then ShowRowMenu(self) end
	end)
	row:SetScript("OnEnter", ShowEntryTooltip)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)
	row.built = true
end

-- Column x positions for the current width.
local function ColumnLayout(width)
	local fixed = 0
	for _, c in ipairs(COLUMNS) do
		if not c.flex then fixed = fixed + c.width end
	end
	local flex = math.max(80, width - fixed)
	local x, out = 0, {}
	for _, c in ipairs(COLUMNS) do
		local w = c.flex and flex or c.width
		out[#out + 1] = { x = x, w = w, col = c }
		x = x + w
	end
	return out
end

local function LayoutRow(row, cols)
	local function Place(fs, idx, pad)
		local c = cols[idx]
		fs:ClearAllPoints()
		fs:SetPoint("LEFT", row, "LEFT", c.x + 6 + (pad or 0), 0)
		fs:SetWidth(c.w - 10 - (pad or 0))
	end
	local mark = row.entry and ns.WhisperState(row.entry.leader)
	Place(row.leader, 1, mark and 16 or 0)
	row.whisperMark:ClearAllPoints()
	row.whisperMark:SetPoint("LEFT", row, "LEFT", cols[1].x + 4, 0)
	Place(row.level, 2)
	Place(row.activity, 3)
	Place(row.zone, 4)
	Place(row.sizeText, 5)
	Place(row.style, 6)
	Place(row.age, 7)
	for s, slot in ipairs(row.slots) do
		slot:ClearAllPoints()
		slot:SetPoint("LEFT", row, "LEFT", cols[5].x + 6 + (s - 1) * (ICON + 3), 0)
	end
	-- Groups: one wide Whisper button. Singles: whisper icon + Invite.
	local group = row.entry and row.entry.isGroup
	row.join:ClearAllPoints()
	row.join:SetPoint("RIGHT", row, "RIGHT", -2, 0)
	row.join:SetWidth(group and 92 or 62)
	row.whisper:ClearAllPoints()
	row.whisper:SetPoint("RIGHT", row.join, "LEFT", -2, 0)
	row.whisper:SetShown(not group)
end

local function ResetSlot(slot)
	slot.role:ClearAllPoints()
	slot.role:SetSize(11, 11)
	slot.role:SetPoint("BOTTOMRIGHT", 3, -3)
end

local function FillSlots(row, e)
	for _, slot in ipairs(row.slots) do slot:Hide() end
	row.sizeText:SetText("")
	if not e.isGroup then
		-- Single: class icon, then the roles they can fill.
		local slot = row.slots[1]
		ResetSlot(slot)
		if SetClassIcon(slot.class, e.leaderClass) then slot.class:Show() else slot.class:Hide() end
		slot.role:Hide()
		slot.bg:SetColorTexture(0, 0, 0, 0.5)
		slot:Show()
		local s = 2
		for _, role in ipairs({ "TANK", "HEALER", "DAMAGER" }) do
			if e.offers[role] then
				local o = row.slots[s]
				o.class:Hide()
				SetRoleIcon(o.role, role)
				o.role:ClearAllPoints()
				o.role:SetAllPoints()
				o.bg:SetColorTexture(0, 0, 0, 0)
				o:Show()
				s = s + 1
			end
		end
		return
	end
	local max = e.maxPlayers or 5
	if max > 5 or e.numMembers > 5 then
		row.sizeText:SetText(("%s%d %s%d %s%d  |cffaaaaaa%d/%s|r"):format(
			RoleIconString("TANK"), e.counts.TANK, RoleIconString("HEALER"), e.counts.HEALER,
			RoleIconString("DAMAGER"), e.counts.DAMAGER, e.numMembers, e.maxPlayers or "?"))
		return
	end
	-- Tank, healer, dps, rest; empty slots after.
	local order = { TANK = 1, HEALER = 2, DAMAGER = 3 }
	local members = {}
	for _, m in ipairs(e.members) do members[#members + 1] = m end
	table.sort(members, function(a, b) return (order[a.role] or 4) < (order[b.role] or 4) end)
	for s = 1, max do
		local slot = row.slots[s]
		local m = members[s]
		ResetSlot(slot)
		if m then
			if SetClassIcon(slot.class, m.class) then slot.class:Show() else slot.class:Hide() end
			SetRoleIcon(slot.role, m.role)
			slot.bg:SetColorTexture(0, 0, 0, 0.5)
		else
			slot.class:Hide()
			slot.role:Hide()
			slot.bg:SetColorTexture(1, 1, 1, s <= e.numMembers and 0.3 or 0.07)
		end
		slot:Show()
	end
end

local function InitRow(row, e)
	if not row.built then BuildRow(row) end
	row.entry = e
	LayoutRow(row, ColumnLayout(box:GetWidth()))
	row.stripe:SetColorTexture(1, 1, 1, (e.index or 0) % 2 == 0 and 0.04 or 0)

	local r, g, b = ClassColor(e.leaderClass)
	row.leader:SetText(e.leader or "?")
	row.leader:SetTextColor(r, g, b)
	local w = ns.WhisperState(e.leader)
	row.whisperMark:SetShown(w ~= nil)
	if w then
		if w.replied then row.whisperMark:SetVertexColor(0.4, 1, 0.4) else row.whisperMark:SetVertexColor(1, 1, 1) end
	end
	row.newBar:SetShown(e.isNew)
	row.newGlow:SetShown(e.isNew)
	row.level:SetText(e.leaderLevel or "")
	row.level:SetTextColor(LevelColor(e.leaderLevel))
	row.zone:SetText(e.zone)
	row.activity:SetText(e.activityText)
	local dim = e.delisted and 0.5 or 1
	row.activity:SetTextColor(dim, dim, dim)
	row.style:SetText(e.styleText)
	local sc = STYLE_COLORS[e.styleText] or { 0.8, 0.8, 0.8 }
	row.style:SetTextColor(sc[1], sc[2], sc[3])
	row.age:SetText(FormatAge(CurrentAge(e)))
	row.join:SetText(e.isGroup and "Whisper" or "Invite")
	FillSlots(row, e)
end

local function Render()
	if not frame or not frame:IsShown() then return end
	box:SetDataProvider(CreateDataProvider(visible), ScrollBoxConstants.RetainScrollPosition)
	local cols = ColumnLayout(box:GetWidth())
	for i, c in ipairs(cols) do
		local h = headers[i]
		h:ClearAllPoints()
		h:SetPoint("LEFT", headerFrame, "LEFT", c.x, 0)
		h:SetWidth(c.w)
		if h.middle then h.middle:SetWidth(math.max(1, c.w - 9)) end
		local mark = ""
		if c.col.key and c.col.key == ns.db.sortKey then
			mark = ns.db.sortAsc and " |TInterface\\Buttons\\Arrow-Up-Up:12:12|t" or " |TInterface\\Buttons\\Arrow-Down-Up:12:12|t"
		end
		h:SetText(c.col.title .. mark)
	end
end
ns.Render = Render

function ns.SetStatus(text)
	if statusText then statusText:SetText(text) end
end

function ns.RefreshResults()
	if not frame or not frame:IsShown() then return end
	entries = ns.CollectResults()
	ApplyFilters()
	Render()
end

Refilter = function()
	ApplyFilters()
	Render()
	if box.ScrollToBegin then box:ScrollToBegin() end
	if mineButton then
		if ns.db.roleFilter == "mine" then mineButton:LockHighlight() else mineButton:UnlockHighlight() end
		mineButton.icons:SetText(MyRolesIcons())
	end
	if roleDD then RefreshDropdown(roleDD) end
end

--------------------------------------------------------------------------------
-- Toolbar menus
--------------------------------------------------------------------------------

local function DoSearch()
	if ns.Search() then
		ApplyFilters()
	else
		ns.SetStatus("|cffff6060Could not start a search.|r")
	end
end

local searchQueued = false
local function QueueSearch()
	if searchQueued then return end
	searchQueued = true
	C_Timer.After(0.4, function()
		searchQueued = false
		DoSearch()
	end)
end

local function ActivityText()
	local sel = ns.SelectedActivities()
	if not sel then return "All activities" end
	if #sel == 1 then return ns.ActivityName(sel[1]) end
	return #sel .. " activities"
end

local function SetupMenus()
	catDD:SetupMenu(function(_, root)
		for _, c in ipairs(ns.GetCategories()) do
			root:CreateRadio(c.name, function() return ns.db.category == c.id end, function()
				if ns.db.category ~= c.id then
					ns.db.category = c.id
					wipe(ns.db.activities)
					RefreshDropdown(actDD)
					DoSearch()
				end
			end)
		end
	end)

	actDD:SetDefaultText("All activities")
	if actDD.SetSelectionText then actDD:SetSelectionText(ActivityText) end
	actDD:SetupMenu(function(_, root)
		root:CreateCheckbox("All activities", function() return ns.SelectedActivities() == nil end, function()
			wipe(ns.db.activities)
			Refilter()
			QueueSearch()
			return MenuResponse and MenuResponse.Refresh
		end)
		root:CreateDivider()
		local list = ns.GetActivities(ns.db.category)
		if root.SetScrollMode and #list > 20 then root:SetScrollMode(20 * 20) end
		for _, a in ipairs(list) do
			local label = a.name
			if a.level > 0 then label = label .. " |cff888888(" .. a.level .. ")|r" end
			root:CreateCheckbox(label, function() return ns.db.activities[a.id] == true end, function()
				ns.db.activities[a.id] = (not ns.db.activities[a.id]) or nil
				Refilter()
				QueueSearch()
				return MenuResponse and MenuResponse.Refresh
			end)
		end
	end)

	typeDD:SetupMenu(function(_, root)
		for _, c in ipairs(TYPE_CHOICES) do
			root:CreateRadio(c[2], function() return ns.db.typeFilter == c[1] end, function()
				ns.db.typeFilter = c[1]
				Refilter()
			end)
		end
	end)

	roleDD:SetupMenu(function(_, root)
		local roles = {
			{ "any", "Any role" },
			{ "mine", MyRolesIcons() .. " My roles" },
			{ "TANK", RoleIconString("TANK") .. " Needs tank" },
			{ "HEALER", RoleIconString("HEALER") .. " Needs healer" },
			{ "DAMAGER", RoleIconString("DAMAGER") .. " Needs DPS" },
		}
		for _, c in ipairs(roles) do
			root:CreateRadio(c[2], function() return ns.db.roleFilter == c[1] end, function()
				ns.db.roleFilter = c[1]
				Refilter()
			end)
		end
	end)

	styleDD:SetupMenu(function(_, root)
		local choices = { "Learning", "Relaxed", "Competitive", "Carry Offered" }
		local seen = {}
		for _, s in ipairs(choices) do seen[s] = true end
		for _, e in ipairs(entries) do
			if e.styleText ~= "" and not seen[e.styleText] then
				seen[e.styleText] = true
				choices[#choices + 1] = e.styleText
			end
		end
		root:CreateRadio("Any style", function() return ns.db.styleFilter == "any" end, function()
			ns.db.styleFilter = "any"
			Refilter()
		end)
		for _, s in ipairs(choices) do
			root:CreateRadio(s, function() return ns.db.styleFilter == s end, function()
				ns.db.styleFilter = s
				Refilter()
			end)
		end
	end)
end

local function SafeRefilter()
	if frame and frame:IsShown() then Refilter() end
end

function ns.ShowSettingsMenu(owner)
	MenuUtil.CreateContextMenu(owner, function(_, root)
		root:CreateTitle("GroupGlance")
		root:CreateCheckbox("Replace Blizzard's window", function() return ns.db.replaceBlizzard end, function()
			ns.db.replaceBlizzard = not ns.db.replaceBlizzard
		end)
		root:CreateCheckbox("Refresh every 30 seconds", function() return ns.db.autoRefresh end, function()
			ns.db.autoRefresh = not ns.db.autoRefresh
		end)
		root:CreateCheckbox("Hide delisted groups", function() return ns.db.hideDelisted end, function()
			ns.db.hideDelisted = not ns.db.hideDelisted
			SafeRefilter()
		end)
		root:CreateCheckbox("Show minimap button", function() return ns.db.showMinimap end, function()
			ns.db.showMinimap = not ns.db.showMinimap
			if ns.UpdateMinimapButton then ns.UpdateMinimapButton() end
		end)

		local roles = root:CreateButton("My roles")
		roles:CreateTitle("Used by the My roles filter")
		for _, r in ipairs({ { "TANK", "Tank" }, { "HEALER", "Healer" }, { "DAMAGER", "DPS" } }) do
			roles:CreateCheckbox(RoleIconString(r[1]) .. " " .. r[2], function() return ns.db.myRoles[r[1]] == true end, function()
				ns.db.myRoles[r[1]] = (not ns.db.myRoles[r[1]]) or nil
				SafeRefilter()
				return MenuResponse and MenuResponse.Refresh
			end)
		end

		local names = {}
		for key, name in pairs(ns.db.blocked) do names[#names + 1] = { key, name } end
		table.sort(names, function(a, b) return a[1] < b[1] end)
		local hidden = root:CreateButton(("Hidden players (%d)"):format(#names))
		if #names == 0 then
			hidden:CreateTitle("Right-click a row to hide a player")
		else
			hidden:CreateTitle("Click to show again")
			for _, n in ipairs(names) do
				hidden:CreateButton(n[2], function() ns.Unblock(n[1]) SafeRefilter() end)
			end
			hidden:CreateDivider()
			hidden:CreateButton("Show everyone again", function() wipe(ns.db.blocked) SafeRefilter() end)
		end

		root:CreateDivider()
		root:CreateButton("Open Blizzard's window", function() if frame then frame:Hide() end ns.OpenBlizzard() end)
		root:CreateButton("Reset window size and position", function() SlashCmdList.GROUPGLANCE("reset") end)
	end)
end

--------------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------------

function ns.ApplyPosition()
	if not frame then return end
	frame:SetSize(math.max(ns.db.window.width, 760), math.max(ns.db.window.height, 300))
	frame:ClearAllPoints()
	local p = ns.db.pos
	if p then
		frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
	else
		frame:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
	end
end

local function SavePosition()
	local point, _, relPoint, x, y = frame:GetPoint()
	ns.db.pos = { point, relPoint, x, y }
end

local function CreateHeader(i, col)
	local ok, h = pcall(CreateFrame, "Button", "GroupGlanceHeader" .. i, headerFrame, "WhoFrameColumnHeaderTemplate")
	if ok and h then
		h.middle = _G["GroupGlanceHeader" .. i .. "Middle"]
		h:SetScript("OnClick", nil)
	else
		h = CreateFrame("Button", nil, headerFrame)
		h:SetNormalFontObject("GameFontHighlightSmall")
		h:SetText(" ")
		local bg = h:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetColorTexture(1, 1, 1, 0.06)
		h:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
	end
	h:SetHeight(HEADER_H)
	local fs = h:GetFontString()
	if fs then
		fs:ClearAllPoints()
		fs:SetPoint("LEFT", 6, 0)
		fs:SetJustifyH("LEFT")
	end
	if col.key then
		h:SetScript("OnClick", function()
			if ns.db.sortKey == col.key then
				ns.db.sortAsc = not ns.db.sortAsc
			else
				ns.db.sortKey = col.key
				ns.db.sortAsc = (col.key ~= "size" and col.key ~= "level")
			end
			PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
			Refilter()
		end)
	else
		h:EnableMouse(false)
	end
	return h
end

local function Build()
	frame = CreateFrame("Frame", "GroupGlanceFrame", UIParent, "ButtonFrameTemplate")
	frame:Hide()
	frame:SetFrameStrata("HIGH")
	frame:SetToplevel(true)
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:SetResizable(true)
	if frame.SetResizeBounds then frame:SetResizeBounds(760, 300, 1500, 1100) end
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
	frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() SavePosition() end)
	if frame.SetTitle then frame:SetTitle("Looking For Group") end
	if frame.SetPortraitToAsset then
		pcall(frame.SetPortraitToAsset, frame, "Interface\\LFGFrame\\UI-LFG-PORTRAIT")
	end
	if frame.CloseButton then frame.CloseButton:SetScript("OnClick", function() frame:Hide() end) end
	tinsert(UISpecialFrames, "GroupGlanceFrame")

	local inset = frame.Inset
	inset:ClearAllPoints()
	inset:SetPoint("TOPLEFT", 4, -90)
	inset:SetPoint("BOTTOMRIGHT", -6, 26)

	-- Row 1: category, activities, refresh, settings
	catDD = Dropdown(frame, 140)
	catDD:SetPoint("TOPLEFT", 64, -31)
	actDD = Dropdown(frame, 210)
	actDD:SetPoint("LEFT", catDD, "RIGHT", 6, 0)

	local refresh = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	refresh:SetSize(26, 24)
	refresh:SetPoint("LEFT", actDD, "RIGHT", 6, 0)
	local refreshIcon = refresh:CreateTexture(nil, "OVERLAY")
	refreshIcon:SetTexture("Interface\\Buttons\\UI-RefreshButton")
	refreshIcon:SetSize(14, 14)
	refreshIcon:SetPoint("CENTER")
	Tooltip(refresh, "Search again")
	refresh:SetScript("OnClick", DoSearch)

	local gear = CreateFrame("Button", nil, frame)
	gear:SetSize(18, 18)
	gear:SetPoint("TOPRIGHT", -12, -34)
	gear:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
	gear:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
	Tooltip(gear, "Settings")
	gear:SetScript("OnClick", ns.ShowSettingsMenu)

	-- Row 2: filters and search box
	typeDD = Dropdown(frame, 140)
	typeDD:SetPoint("TOPLEFT", catDD, "BOTTOMLEFT", 0, -6)
	roleDD = Dropdown(frame, 140)
	roleDD:SetPoint("LEFT", typeDD, "RIGHT", 6, 0)
	Tooltip(roleDD, "Groups that still need this role, or singles who can play it")

	-- Quick toggle: only groups that need one of my roles.
	mineButton = PanelButton(frame, "", 44, 24)
	mineButton:SetPoint("LEFT", roleDD, "RIGHT", 4, 0)
	mineButton.icons = mineButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	mineButton.icons:SetPoint("CENTER")
	mineButton.icons:SetText(MyRolesIcons())
	mineButton:SetScript("OnClick", function()
		ns.db.roleFilter = (ns.db.roleFilter == "mine") and "any" or "mine"
		PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
		Refilter()
	end)
	mineButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("My roles " .. MyRolesIcons(), 1, 1, 1)
		GameTooltip:AddLine("Only show groups that need one of your roles. Click again to show all.", 0.8, 0.8, 0.8, true)
		GameTooltip:AddLine("Change your roles in the settings menu.", 0.5, 0.5, 0.5, true)
		GameTooltip:Show()
	end)
	mineButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

	styleDD = Dropdown(frame, 120)
	styleDD:SetPoint("LEFT", mineButton, "RIGHT", 4, 0)

	searchBox = CreateFrame("EditBox", nil, frame, "SearchBoxTemplate")
	searchBox:SetSize(150, 20)
	searchBox:SetPoint("RIGHT", frame, "RIGHT", -12, 0)
	searchBox:SetPoint("TOP", typeDD, "TOP", 0, -2)
	if searchBox.Instructions then searchBox.Instructions:SetText("Name or dungeon") end
	searchBox:HookScript("OnTextChanged", function() Refilter() end)

	-- Column headers
	headerFrame = CreateFrame("Frame", nil, inset)
	headerFrame:SetPoint("TOPLEFT", 4, -3)
	headerFrame:SetPoint("TOPRIGHT", -22, -3)
	headerFrame:SetHeight(HEADER_H)
	for i, c in ipairs(COLUMNS) do headers[i] = CreateHeader(i, c) end

	-- List
	box = CreateFrame("Frame", nil, inset, "WowScrollBoxList")
	box:SetPoint("TOPLEFT", headerFrame, "BOTTOMLEFT", 0, -1)
	box:SetPoint("BOTTOMRIGHT", inset, "BOTTOMRIGHT", -22, 4)
	local bar = CreateFrame("EventFrame", nil, inset, "MinimalScrollBar")
	bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 6, 0)
	bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 6, 0)
	local view = CreateScrollBoxListLinearView()
	view:SetElementExtent(ROW_H)
	view:SetElementInitializer("Button", InitRow)
	ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
	box:HookScript("OnSizeChanged", function() Render() end)

	-- Bottom bar: status, My Listing, resize grip
	statusText = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	statusText:SetPoint("BOTTOMLEFT", 12, 8)

	local listMe = PanelButton(frame, "My Listing", 110, 22)
	listMe:SetPoint("BOTTOMRIGHT", -22, 3)
	frame.listMe = listMe
	listMe:SetScript("OnClick", function()
		ns.SetMode(frame.mode == "listing" and "browse" or "listing")
	end)

	local grip = CreateFrame("Button", nil, frame)
	grip:SetSize(16, 16)
	grip:SetPoint("BOTTOMRIGHT", -3, 3)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
	grip:SetScript("OnMouseUp", function()
		frame:StopMovingOrSizing()
		ns.db.window.width, ns.db.window.height = math.floor(frame:GetWidth()), math.floor(frame:GetHeight())
		SavePosition()
	end)

	-- Keep ages ticking while open, and search again every 30 seconds.
	local elapsedSum = 0
	frame:SetScript("OnUpdate", function(_, elapsed)
		elapsedSum = elapsedSum + elapsed
		if elapsedSum < 5 then return end
		elapsedSum = 0
		if ns.db.autoRefresh and not ns.searching and ns.lastSearchTime and GetTime() - ns.lastSearchTime >= 30
			and not (MenuUtil and Menu and Menu.GetManager and Menu.GetManager():IsAnyMenuOpen()) then
			DoSearch()
		end
		box:ForEachFrame(function(row)
			if row.entry then row.age:SetText(FormatAge(CurrentAge(row.entry))) end
		end)
	end)

	frame:SetScript("OnShow", function()
		PlaySound(SOUNDKIT.IG_CHARACTER_INFO_OPEN)
		if not ns.db.category then
			local cats = ns.GetCategories()
			ns.db.category = cats[1] and cats[1].id
		end
		for _, d in ipairs({ catDD, actDD, typeDD, roleDD, styleDD }) do RefreshDropdown(d) end
		ns.RefreshResults()
		-- Search again if results are missing or old.
		if #entries == 0 or not ns.lastSearchTime or GetTime() - ns.lastSearchTime > 30 then
			DoSearch()
		end
	end)
	frame:SetScript("OnHide", function() PlaySound(SOUNDKIT.IG_CHARACTER_INFO_CLOSE) end)

	SetupMenus()
	ns.ApplyPosition()

	-- "My Listing" page: replaces the browse widgets while shown.
	frame.browseWidgets = { catDD, actDD, refresh, typeDD, roleDD, mineButton, styleDD, searchBox, inset, statusText }
	frame.listingPanel = ns.BuildListingPanel(frame)
	frame.mode = "browse"
end

function ns.SetMode(mode)
	if not frame then Build() end
	frame.mode = mode
	local listing = mode == "listing"
	for _, w in ipairs(frame.browseWidgets) do w:SetShown(not listing) end
	frame.listingPanel:SetShown(listing)
	frame.listMe:SetText(listing and "Browse Groups" or "My Listing")
	if frame.SetTitle then frame:SetTitle(listing and "Looking For Group - My Listing" or "Looking For Group") end
	if not listing then ns.RefreshResults() end
end

function ns.ShowWindow()
	if not frame then Build() end
	frame:Show()
end

function ns.ShowListing()
	ns.ShowWindow()
	ns.SetMode("listing")
end

function ns.ToggleWindow()
	if not frame then Build() end
	frame:SetShown(not frame:IsShown())
end
