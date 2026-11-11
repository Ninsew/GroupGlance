local addonName, ns = ...

local defaults = {
	replaceBlizzard = true,   -- open GroupGlance instead of Blizzard's LFG window
	hideDelisted = true,
	category = nil,           -- categoryID
	activities = {},          -- [activityID] = true; empty means all
	sortKey = "age",
	sortAsc = true,
	typeFilter = "all",       -- all / groups / singles
	roleFilter = "any",       -- any / TANK / HEALER / DAMAGER
	styleFilter = "any",      -- any / playstyle text
	window = { width = 720, height = 460 },
	pos = nil,                -- { point, relPoint, x, y }
	whispered = {},           -- [lowercased name] = { sent = time(), replied = time() }
	blocked = {},             -- [lowercased name] = display name; hidden from the list
	myRoles = {},             -- { TANK, HEALER, DAMAGER } = true; empty uses Blizzard's LFG roles
	autoRefresh = true,       -- search again every 30 seconds while the window is open
	showMinimap = true,
	minimapAngle = 220,       -- degrees around the minimap
}

local WHISPER_MEMORY = 3 * 3600 -- forget whispers after 3 hours

local function WhisperKey(name)
	if not name or (issecretvalue and issecretvalue(name)) or type(name) ~= "string" then return nil end
	return Ambiguate(name, "none"):lower()
end

-- Returns { sent, replied } if we whispered this player recently.
function ns.WhisperState(name)
	local key = WhisperKey(name)
	local w = key and ns.db.whispered[key]
	if w and time() - w.sent < WHISPER_MEMORY then return w end
end

local function PruneWhispers()
	local now = time()
	for key, w in pairs(ns.db.whispered) do
		if type(w) ~= "table" or not w.sent or now - w.sent >= WHISPER_MEMORY then
			ns.db.whispered[key] = nil
		end
	end
end

function ns.CopyDefaults(src, dst)
	for k, v in pairs(src) do
		if type(v) == "table" then
			if type(dst[k]) ~= "table" then dst[k] = {} end
			ns.CopyDefaults(v, dst[k])
		elseif dst[k] == nil then
			dst[k] = v
		end
	end
end

function ns.Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffGroupGlance|r: " .. tostring(msg))
end

--------------------------------------------------------------------------------
-- Blizzard window replacement
--------------------------------------------------------------------------------

-- Frames that make up Blizzard's LFG browser on the Forever client.
local BLIZZARD_FRAMES = { "LFGParentFrame" }
local hooked = {}

local function HideBlizzard(frame)
	if HideUIPanel then pcall(HideUIPanel, frame) end
	if frame:IsShown() then frame:Hide() end
end

function ns.HookBlizzard()
	for _, name in ipairs(BLIZZARD_FRAMES) do
		local frame = _G[name]
		if frame and not hooked[frame] and frame.HookScript then
			hooked[frame] = true
			frame:HookScript("OnShow", function(self)
				if not ns.db.replaceBlizzard or ns.bypass then return end
				HideBlizzard(self)
				ns.ToggleWindow()
			end)
			frame:HookScript("OnHide", function()
				ns.bypass = false
			end)
		end
	end
end

-- Opens Blizzard's own window (needed for listing yourself).
function ns.OpenBlizzard()
	for _, name in ipairs(BLIZZARD_FRAMES) do
		local frame = _G[name]
		if frame then
			ns.bypass = true
			if ShowUIPanel then ShowUIPanel(frame) else frame:Show() end
			if not frame:IsShown() then frame:Show() end
			-- Tab 1 is the listing page (tab 2 is the browser we replace).
			if LFGParentFrameTab1 and LFGParentFrameTab1.Click then LFGParentFrameTab1:Click() end
			return true
		end
	end
	ns.Print("Could not find Blizzard's Looking For Group window.")
	return false
end

--------------------------------------------------------------------------------
-- Diagnostics: /gg dump saves what the client offers to SavedVariables.
--------------------------------------------------------------------------------

local function Safe(v)
	if issecretvalue and issecretvalue(v) then return "<secret>" end
	local t = type(v)
	if t == "string" or t == "number" or t == "boolean" or t == "nil" then return v end
	if t == "table" then
		local out = {}
		for k, val in pairs(v) do
			if type(k) == "string" or type(k) == "number" then
				local tv = type(val)
				out[k] = (tv == "table") and Safe(val) or (tv == "function" or tv == "userdata") and tv or Safe(val)
			end
		end
		return out
	end
	return t
end

local function Pack(ok, ...)
	local out = { ok = ok, n = select("#", ...) }
	for i = 1, out.n do out[i] = Safe((select(i, ...))) end
	return out
end

function ns.Dump()
	local d = { time = date("%Y-%m-%d %H:%M:%S"), frames = {}, api = {}, party = {}, globals = {}, results = {} }
	for k, v in pairs(_G) do
		if type(k) == "string" and (k:find("LFG") or k:find("GroupFinder") or k:find("PVEFrame")) then
			if type(v) == "table" and type(v.GetObjectType) == "function" then
				local ok, objType = pcall(v.GetObjectType, v)
				local shown = ok and v.IsShown and v:IsShown()
				d.frames[#d.frames + 1] = k .. " (" .. tostring(objType) .. (shown and ", shown" or "") .. ")"
			elseif type(v) == "function" then
				d.globals[#d.globals + 1] = k .. "()"
			end
		end
	end
	table.sort(d.frames)
	table.sort(d.globals)
	for k in pairs(C_LFGList or {}) do d.api[#d.api + 1] = k end
	table.sort(d.api)
	for k in pairs(C_PartyInfo or {}) do d.party[#d.party + 1] = k end
	table.sort(d.party)
	d.playstyles = {}
	for i = 0, 5 do
		d.playstyles[i + 1] = tostring(_G["GROUP_FINDER_GENERAL_PLAYSTYLE" .. i])
	end

	if C_LFGList then
		d.categories = Pack(pcall(C_LFGList.GetAvailableCategories))
		if C_LFGList.GetSearchResults then
			local ok, count, ids = pcall(C_LFGList.GetSearchResults)
			d.resultCount = Safe(count)
			if ok and type(count) == "table" then ids = count end
			for i, id in ipairs(type(ids) == "table" and ids or {}) do
				if i > 4 then break end
				local r = { id = id }
				r.info = Pack(pcall(C_LFGList.GetSearchResultInfo, id))
				if C_LFGList.GetSearchResultLeaderInfo then
					r.leader = Pack(pcall(C_LFGList.GetSearchResultLeaderInfo, id))
				end
				if C_LFGList.GetSearchResultMemberCounts then
					r.counts = Pack(pcall(C_LFGList.GetSearchResultMemberCounts, id))
				end
				r.members = {}
				for m = 1, 3 do
					if C_LFGList.GetSearchResultMemberInfo then
						r.members["memberInfo" .. m] = Pack(pcall(C_LFGList.GetSearchResultMemberInfo, id, m))
					end
					if C_LFGList.GetSearchResultPlayerInfo then
						r.members["playerInfo" .. m] = Pack(pcall(C_LFGList.GetSearchResultPlayerInfo, id, m))
					end
				end
				d.results[#d.results + 1] = r
			end
		end
	end
	d.lastSearch = ns.searchMode
	GroupGlanceDB.dump = d
	ns.Print("Saved diagnostics. Type /reload so they are written to disk.")
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local events = CreateFrame("Frame")
for _, event in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "LFG_LIST_SEARCH_RESULTS_RECEIVED",
	"LFG_LIST_SEARCH_RESULT_UPDATED", "LFG_LIST_SEARCH_FAILED", "CHAT_MSG_WHISPER_INFORM", "CHAT_MSG_WHISPER" }) do
	pcall(events.RegisterEvent, events, event)
end

local updatePending = false
local function QueueUpdate()
	if updatePending then return end
	updatePending = true
	C_Timer.After(0.25, function()
		updatePending = false
		if ns.RefreshResults then ns.RefreshResults() end
	end)
end

events:SetScript("OnEvent", function(_, event, arg1, arg2)
	if event == "CHAT_MSG_WHISPER_INFORM" or event == "CHAT_MSG_WHISPER" then
		local key = ns.db and WhisperKey(arg2)
		if not key then return end
		if event == "CHAT_MSG_WHISPER_INFORM" then
			local w = ns.db.whispered[key] or {}
			w.sent = time()
			ns.db.whispered[key] = w
		elseif ns.db.whispered[key] then
			ns.db.whispered[key].replied = time()
		else
			return
		end
		if ns.Render then ns.Render() end
	elseif event == "ADDON_LOADED" then
		if arg1 == addonName then
			GroupGlanceDB = GroupGlanceDB or {}
			ns.CopyDefaults(defaults, GroupGlanceDB)
			ns.db = GroupGlanceDB
			PruneWhispers()
		end
		if ns.db then ns.HookBlizzard() end
	elseif event == "PLAYER_LOGIN" then
		ns.HookBlizzard()
		if ns.InitMinimapButton then ns.InitMinimapButton() end
		-- Remember exactly what a listing was posted with (also from Blizzard's window),
		-- so the fields Forever expects can be checked in the saved variables.
		for _, fn in ipairs({ "CreateListing", "UpdateListing" }) do
			if C_LFGList and C_LFGList[fn] then
				hooksecurefunc(C_LFGList, fn, function(data)
					ns.db.lastListing = { call = fn, time = date("%H:%M:%S"), data = Safe(data) }
				end)
			end
		end
	elseif event == "LFG_LIST_SEARCH_RESULTS_RECEIVED" then
		ns.searching = false
		ns.lastSearchTime = GetTime()
		if ns.RefreshResults then ns.RefreshResults() end
	elseif event == "LFG_LIST_SEARCH_RESULT_UPDATED" then
		QueueUpdate()
	elseif event == "LFG_LIST_SEARCH_FAILED" then
		ns.searching = false
		if ns.SetStatus then ns.SetStatus("|cffff6060Search failed|r" .. (arg1 and (": " .. tostring(arg1)) or "")) end
	end
end)

SLASH_GROUPGLANCE1 = "/gg"
SLASH_GROUPGLANCE2 = "/groupglance"
SlashCmdList.GROUPGLANCE = function(msg)
	msg = (msg or ""):lower():match("^%s*(.-)%s*$")
	if msg == "dump" then
		ns.Dump()
	elseif msg == "blizzard" then
		ns.OpenBlizzard()
	elseif msg == "reset" then
		ns.db.pos = nil
		ns.db.window.width, ns.db.window.height = defaults.window.width, defaults.window.height
		if ns.ApplyPosition then ns.ApplyPosition() end
	else
		ns.ToggleWindow()
	end
end
