local addonName, ns = ...

-- Wraps C_LFGList so the window doesn't care which client flavour of the API we got.

local L = C_LFGList or {}

local function IsSecret(v)
	return issecretvalue ~= nil and issecretvalue(v) or false
end
ns.IsSecret = IsSecret

-- Lowercased plain string, or "" for secret/missing values.
function ns.Lower(v)
	if v == nil or IsSecret(v) or type(v) ~= "string" then return "" end
	return v:lower()
end

local ROLES = { TANK = true, HEALER = true, DAMAGER = true, NONE = true }

--------------------------------------------------------------------------------
-- Categories and activities
--------------------------------------------------------------------------------

function ns.GetCategories()
	local out = {}
	local ok, ids = pcall(L.GetAvailableCategories)
	for _, id in ipairs(ok and type(ids) == "table" and ids or {}) do
		local name
		if L.GetLfgCategoryInfo then
			local info = L.GetLfgCategoryInfo(id)
			name = type(info) == "table" and info.name or info
		end
		if not name and L.GetCategoryInfo then name = L.GetCategoryInfo(id) end
		out[#out + 1] = { id = id, name = type(name) == "string" and name or ("Category " .. id) }
	end
	return out
end

function ns.CategoryName(id)
	for _, c in ipairs(ns.GetCategories()) do
		if c.id == id then return c.name end
	end
	return "Category"
end

local activityCache = {}
function ns.GetActivityInfo(id)
	if not id then return nil end
	if activityCache[id] then return activityCache[id] end
	local ok, info = pcall(L.GetActivityInfoTable, id)
	if ok and type(info) == "table" then
		activityCache[id] = info
		return info
	end
end

function ns.ActivityName(id)
	local info = ns.GetActivityInfo(id)
	return info and (info.fullName or info.shortName) or ("Activity " .. tostring(id))
end

function ns.GetActivities(categoryID)
	local list = {}
	local ok, ids = pcall(L.GetAvailableActivities, categoryID)
	for _, id in ipairs(ok and type(ids) == "table" and ids or {}) do
		local info = ns.GetActivityInfo(id) or {}
		list[#list + 1] = {
			id = id,
			name = ns.ActivityName(id),
			level = info.minLevelSuggestion or info.minLevel or 0,
		}
	end
	table.sort(list, function(a, b)
		if a.level ~= b.level then return a.level < b.level end
		return a.name < b.name
	end)
	return list
end

--------------------------------------------------------------------------------
-- Search
--------------------------------------------------------------------------------

local function SelectedActivities()
	local ids = {}
	for id, on in pairs(ns.db.activities) do
		if on then ids[#ids + 1] = id end
	end
	return #ids > 0 and ids or nil
end
ns.SelectedActivities = SelectedActivities

function ns.Search()
	if not L.Search then return false end
	local cat = ns.db.category
	if not cat then
		local cats = ns.GetCategories()
		cat = cats[1] and cats[1].id
		ns.db.category = cat
	end
	if not cat then return false end
	local acts = SelectedActivities()

	-- Classic-style signature first, then the retail one.
	local ok = pcall(L.Search, cat, acts)
	ns.searchMode = ok and "classic" or nil
	if not ok then
		local lang = L.GetLanguageSearchFilter and L.GetLanguageSearchFilter() or {}
		ok = pcall(L.Search, cat, 0, 0, lang, true, nil, acts)
		ns.searchMode = ok and "retail" or "failed"
	end
	ns.searching = ok
	return ok
end

--------------------------------------------------------------------------------
-- Results
--------------------------------------------------------------------------------

local function GetMember(id, i)
	if L.GetSearchResultPlayerInfo then
		local ok, t = pcall(L.GetSearchResultPlayerInfo, id, i)
		if ok and type(t) == "table" then
			local r = type(t.lfgRoles) == "table" and t.lfgRoles or {}
			return {
				name = t.name, role = t.assignedRole or t.role, class = t.classFilename,
				className = t.className, level = t.level, isLeader = t.isLeader, area = t.areaName,
				tank = r.tank, healer = r.healer, dps = r.dps,
			}
		end
	end
	if L.GetSearchResultMemberInfo then
		local ok, a, b, c, d, e, f, g, h, k = pcall(L.GetSearchResultMemberInfo, id, i)
		if ok then
			if ROLES[b] then
				-- name, role, classFile, className, level, areaName, soloTank, soloHealer, soloDPS
				return { name = a, role = b, class = c, className = d, level = e, area = f, tank = g, healer = h, dps = k }
			elseif ROLES[a] then
				-- role, classFile, className, specName, isLeader
				return { role = a, class = b, className = c, isLeader = e }
			end
		end
	end
end

local function GetLeader(id)
	if not L.GetSearchResultLeaderInfo then return nil end
	local ok, t = pcall(L.GetSearchResultLeaderInfo, id)
	if ok and type(t) == "table" then
		return {
			name = t.name, role = t.role or t.assignedRole, class = t.classFilename, className = t.className,
			level = t.level, area = t.areaName, isLeader = true,
			tank = t.soloRoleTank, healer = t.soloRoleHealer, dps = t.soloRoleDPS,
		}
	end
end

local STYLE_FALLBACK = { "Learning", "Relaxed", "Competitive", "Carry Offered" }

local function StyleText(info, activityInfo)
	local p = info.generalPlaystyle
	if type(p) == "number" and p > 0 then
		return _G["GROUP_FINDER_GENERAL_PLAYSTYLE" .. p] or STYLE_FALLBACK[p] or ""
	end
	p = info.playstyle
	if type(p) == "number" and p > 0 then
		if L.GetPlaystyleString and activityInfo then
			local ok, s = pcall(L.GetPlaystyleString, p, activityInfo)
			if ok and type(s) == "string" and s ~= "" then return s end
		end
		return STYLE_FALLBACK[p] or ""
	end
	return ""
end

local function BuildEntry(id)
	local ok, info = pcall(L.GetSearchResultInfo, id)
	if not ok or type(info) ~= "table" then return nil end

	local e = { id = id, info = info, fetched = GetTime() }
	e.delisted = info.isDelisted and true or false
	e.numMembers = info.numMembers or 1
	e.age = info.age or 0
	e.comment = info.comment
	e.title = info.name

	e.activityIDs = info.activityIDs or (info.activityID and { info.activityID }) or {}
	local firstInfo = ns.GetActivityInfo(e.activityIDs[1])
	if #e.activityIDs == 1 then
		e.activityText = ns.ActivityName(e.activityIDs[1])
	elseif #e.activityIDs > 1 then
		e.activityText = #e.activityIDs .. " activities"
	else
		e.activityText = "?"
	end
	e.searchText = ns.Lower(e.activityText)
	for _, aid in ipairs(e.activityIDs) do
		e.searchText = e.searchText .. " " .. ns.Lower(ns.ActivityName(aid))
	end
	e.maxPlayers = firstInfo and firstInfo.maxNumPlayers
	if not e.maxPlayers or e.maxPlayers <= 0 then e.maxPlayers = nil end
	e.styleText = StyleText(info, firstInfo)

	-- Members
	e.members = {}
	for i = 1, e.numMembers do
		local m = GetMember(id, i)
		if m then e.members[#e.members + 1] = m end
	end
	local leader = GetLeader(id)
	if not leader then
		for _, m in ipairs(e.members) do
			if m.isLeader then leader = m break end
		end
	end
	leader = leader or e.members[1] or {}
	e.leader = info.leaderName or leader.name
	e.leaderClass = leader.class
	e.leaderLevel = leader.level
	e.zone = type(leader.area) == "string" and not IsSecret(leader.area) and leader.area or ""
	e.key = (type(info.partyGUID) == "string" and not IsSecret(info.partyGUID) and info.partyGUID) or ns.Lower(e.leader)
	e.isGroup = e.numMembers > 1
	if not e.isGroup and #e.members == 0 and leader.class then
		e.members[1] = leader
	end
	local solo = e.members[1] or leader
	e.offers = { TANK = solo.tank and true, HEALER = solo.healer and true, DAMAGER = solo.dps and true }
	if not (e.offers.TANK or e.offers.HEALER or e.offers.DAMAGER) and solo.role and solo.role ~= "NONE" then
		e.offers[solo.role] = true
	end
	e.searchText = e.searchText .. " " .. ns.Lower(e.leader) .. " " .. ns.Lower(e.zone)

	-- Roles
	local counts = { TANK = 0, HEALER = 0, DAMAGER = 0 }
	for _, m in ipairs(e.members) do
		if counts[m.role] then counts[m.role] = counts[m.role] + 1 end
	end
	e.counts = counts
	e.needs = {}
	local remaining
	if L.GetSearchResultMemberCounts then
		local okc, c = pcall(L.GetSearchResultMemberCounts, id)
		if okc and type(c) == "table" and c.TANK_REMAINING then remaining = c end
	end
	if remaining then
		e.needs.TANK = (remaining.TANK_REMAINING or 0) > 0
		e.needs.HEALER = (remaining.HEALER_REMAINING or 0) > 0
		e.needs.DAMAGER = (remaining.DAMAGER_REMAINING or 0) > 0
	elseif e.maxPlayers == 5 then
		e.needs.TANK = counts.TANK < 1
		e.needs.HEALER = counts.HEALER < 1
		e.needs.DAMAGER = counts.DAMAGER < 3
	else
		local open = not e.maxPlayers or e.numMembers < e.maxPlayers
		e.needs.TANK, e.needs.HEALER, e.needs.DAMAGER = open, open, open
	end
	return e
end

-- When each listing was first seen this session; listings already there at the
-- first search are not "new".
local firstSeen, seenAny = {}, false
local NEW_FOR = 90 -- seconds a listing counts as new

function ns.CollectResults()
	local list = {}
	if not L.GetSearchResults then return list end
	local ok, count, ids = pcall(L.GetSearchResults)
	if not ok then return list end
	if type(count) == "table" then ids = count end
	local now = GetTime()
	for _, id in ipairs(type(ids) == "table" and ids or {}) do
		local e = BuildEntry(id)
		if e then
			if not firstSeen[e.key] then firstSeen[e.key] = seenAny and now or 0 end
			e.isNew = firstSeen[e.key] > 0 and now - firstSeen[e.key] < NEW_FOR
			list[#list + 1] = e
		end
	end
	if #list > 0 then seenAny = true end
	return list
end

--------------------------------------------------------------------------------
-- Hidden players and my roles
--------------------------------------------------------------------------------

function ns.PlayerKey(name)
	if not name or IsSecret(name) or type(name) ~= "string" then return nil end
	return Ambiguate(name, "none"):lower()
end

function ns.IsBlocked(name)
	local key = ns.PlayerKey(name)
	return key ~= nil and ns.db.blocked[key] ~= nil
end

function ns.Block(name)
	local key = ns.PlayerKey(name)
	if key then ns.db.blocked[key] = Ambiguate(name, "none") end
end

function ns.Unblock(key)
	ns.db.blocked[key] = nil
end

-- Roles chosen in the settings, or the ones picked in Blizzard's LFG role buttons.
function ns.MyRoles()
	local r = ns.db.myRoles
	if r.TANK or r.HEALER or r.DAMAGER then return r end
	if C_LFGListRoles and C_LFGListRoles.GetRoles then
		local ok, s = pcall(C_LFGListRoles.GetRoles)
		if ok and type(s) == "table" and (s.tank or s.healer or s.dps) then
			return { TANK = s.tank, HEALER = s.healer, DAMAGER = s.dps }
		end
	end
	local _, tank, healer, dps = GetLFGRoles()
	if tank or healer or dps then
		return { TANK = tank, HEALER = healer, DAMAGER = dps }
	end
	return { DAMAGER = true }
end

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

-- Never add a realm: Forever's internal realm name can't be whispered.
local function PlainName(name)
	if not name or IsSecret(name) then return nil end
	return Ambiguate(name, "none")
end

function ns.Whisper(name)
	name = PlainName(name)
	if not name then return end
	if ChatFrameUtil and ChatFrameUtil.SendTell then
		ChatFrameUtil.SendTell(name)
	elseif ChatFrame_SendTell then
		ChatFrame_SendTell(name)
	end
end

function ns.Invite(name)
	name = PlainName(name)
	if not name then return end
	if C_PartyInfo and C_PartyInfo.InviteUnit then
		C_PartyInfo.InviteUnit(name)
	elseif InviteUnit then
		InviteUnit(name)
	end
end

-- On Forever you join a group by whispering its leader; singles get invited.
function ns.PrimaryAction(e)
	if e.isGroup then ns.Whisper(e.leader) else ns.Invite(e.leader) end
end
