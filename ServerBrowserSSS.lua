local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local TextService = game:GetService("TextService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local LocalizationService = game:GetService("LocalizationService")
local AssetService = game:GetService("AssetService")
local TextChatService = game:GetService("TextChatService")
local GroupService = game:GetService("GroupService")

-- The menu looks for this folder immediately. Create it before any setup
-- that can fail, so a missing module does not look like the script never ran.
local bootError = "The server list is still starting."

local function ensureRemote(parent, className, name)
	local remote = parent:FindFirstChild(name)
	if remote and remote.ClassName ~= className then
		remote:Destroy()
		remote = nil
	end
	if not remote then
		remote = Instance.new(className)
		remote.Name = name
		remote.Parent = parent
	end
	return remote
end

local remotes = ReplicatedStorage:FindFirstChild("ServerBrowserRemotes")
if not remotes then
	remotes = Instance.new("Folder")
	remotes.Name = "ServerBrowserRemotes"
	remotes.Parent = ReplicatedStorage
end
remotes:SetAttribute("Version", 1)

local getServers = ensureRemote(remotes, "RemoteFunction", "GetServers")
local getPermission = ensureRemote(remotes, "RemoteFunction", "GetPermission")
local createServer = ensureRemote(remotes, "RemoteFunction", "CreateServer")
local joinServer = ensureRemote(remotes, "RemoteFunction", "JoinServer")
local quickPlay = ensureRemote(remotes, "RemoteFunction", "QuickPlay")

local function refuse()
	return { ok = false, error = bootError }
end

getServers.OnServerInvoke = function()
	return refuse()
end
getPermission.OnServerInvoke = function()
	return refuse()
end
createServer.OnServerInvoke = function()
	return refuse()
end
joinServer.OnServerInvoke = function()
	return refuse()
end
quickPlay.OnServerInvoke = function()
	return refuse()
end

local folder = ReplicatedStorage:FindFirstChild("ServerBrowser")
if not folder then
	folder = ReplicatedStorage:WaitForChild("ServerBrowser", 10)
end
if not folder then
	bootError = "ReplicatedStorage.ServerBrowser is missing, so the menu cannot list servers."
	warn("[ServerBrowser] " .. bootError)
	return
end

local configModule = folder:WaitForChild("Config", 10)
local listingModule = folder:WaitForChild("Listing", 10)
if not configModule or not listingModule then
	bootError = "ReplicatedStorage.ServerBrowser needs ModuleScripts named Config and Listing."
	warn("[ServerBrowser] " .. bootError)
	return
end
local loadedConfig, configOrErr = pcall(require, configModule)
local loadedListing, listingOrErr = pcall(require, listingModule)
if not loadedConfig or type(configOrErr) ~= "table" then
	bootError = "ServerBrowser Config did not load. " .. tostring(configOrErr)
	warn("[ServerBrowser] " .. bootError)
	return
end
if not loadedListing or type(listingOrErr) ~= "table" then
	bootError = "ServerBrowser Listing did not load. " .. tostring(listingOrErr)
	warn("[ServerBrowser] " .. bootError)
	return
end
local Config = configOrErr
local Listing = listingOrErr

local function isReservedServer()
	return game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0
end

local function placeIdForMap(mapName)
	local map = Listing.findMap(Config, mapName)
	if map and type(map.placeId) == "number" and map.placeId > 0 then
		return map.placeId
	end
	if type(Config.GamePlaceId) == "number" and Config.GamePlaceId > 0 then
		return Config.GamePlaceId
	end
	return game.PlaceId
end

local function safeRow(entry)
	local row = Listing.sanitize(entry)
	if row.password ~= nil or row.accessCode ~= nil or row.privateServerId ~= nil then
		error("[ServerBrowser] Refusing to send a secret to a player")
	end
	return row
end

local function safeTeleportData(entry)
	local data = Listing.teleportData(entry)
	if data.password ~= nil or data.accessCode ~= nil or data.privateServerId ~= nil then
		error("[ServerBrowser] Refusing to put a secret in teleport data")
	end
	return data
end

local function checkConfig()
	if #Listing.maps(Config) == 0 then
		bootError = "Config.Maps needs at least one map."
		warn("[ServerBrowser] " .. bootError)
		return false
	end
	if type(Config.Gamemodes) ~= "table" or #Config.Gamemodes == 0 then
		bootError = "Config.Gamemodes needs at least one gamemode."
		warn("[ServerBrowser] " .. bootError)
		return false
	end
	if type(Config.Regions) ~= "table" or #Config.Regions == 0 then
		bootError = "Config.Regions needs at least one region."
		warn("[ServerBrowser] " .. bootError)
		return false
	end
	if Config.MinPlayers > Config.DefaultMaxPlayers or Config.DefaultMaxPlayers > Config.MaxPlayersCap then
		bootError = "DefaultMaxPlayers must sit between MinPlayers and MaxPlayersCap."
		warn("[ServerBrowser] " .. bootError)
		return false
	end
	return true
end

if not checkConfig() then
	return
end

-- A reserved match must update the same list the lobby reads, even in Studio.
local usingMock = RunService:IsStudio() and Config.UseMockListInStudio == true and not isReservedServer()

local backend = {}

if usingMock then
	local store = {}

	function backend.get(id)
		return store[id]
	end

	function backend.set(id, value)
		store[id] = value
		return true
	end

	-- Returning nil from the transform cancels the write, matching MemoryStore.
	function backend.update(id, transform)
		local updated = transform(store[id])
		if updated == nil then
			return nil
		end
		store[id] = updated
		return updated
	end

	function backend.remove(id)
		store[id] = nil
		return true
	end

	function backend.list()
		local items = {}
		for key, value in pairs(store) do
			table.insert(items, { key = key, value = value })
		end
		return items
	end
else
	local store = MemoryStoreService:GetHashMap(Config.HashMapName)

	function backend.get(id)
		local ok, value = pcall(function()
			return store:GetAsync(id)
		end)
		if not ok then
			return nil, value
		end
		return value
	end

	function backend.set(id, value)
		-- SetAsync returns false when the key is new and true when it
		-- overwrites an old one. Both are successful saves. Only a pcall
		-- error means the list was not updated.
		local ok, result = pcall(function()
			return store:SetAsync(id, value, Config.ListingLifetime)
		end)
		if not ok then
			return false, result
		end
		return true
	end

	function backend.update(id, transform)
		local ok, value = pcall(function()
			return store:UpdateAsync(id, transform, Config.ListingLifetime)
		end)
		if not ok then
			return nil, value
		end
		return value
	end

	function backend.remove(id)
		local ok, err = pcall(function()
			store:RemoveAsync(id)
		end)
		if not ok then
			return false, err
		end
		return true
	end

	function backend.list()
		local ok, pages = pcall(function()
			return store:ListItemsAsync(100)
		end)
		if not ok then
			return nil, pages
		end

		local items = {}
		-- IsFinished is already true when the map fits on one page, so the
		-- current page has to be read before the loop decides to stop.
		while true do
			local pageOk, page = pcall(function()
				return pages:GetCurrentPage()
			end)
			if not pageOk then
				return nil, page
			end
			for _, entry in ipairs(page) do
				table.insert(items, entry)
			end
			if pages.IsFinished then
				break
			end
			local advanced, advanceErr = pcall(function()
				pages:AdvanceToNextPageAsync()
			end)
			if not advanced then
				return nil, advanceErr
			end
		end
		return items
	end
end

local function publishMatchInfo(data)
	ReplicatedStorage:SetAttribute("IsBattleServer", true)
	ReplicatedStorage:SetAttribute("ServerId", data.serverId)
	ReplicatedStorage:SetAttribute("ServerName", data.serverName)
	ReplicatedStorage:SetAttribute("Map", data.map)
	ReplicatedStorage:SetAttribute("Gamemode", data.gamemode)
	ReplicatedStorage:SetAttribute("Region", data.region)

	local info = ReplicatedStorage:FindFirstChild("MatchInfo")
	if not info then
		info = Instance.new("Folder")
		info.Name = "MatchInfo"
		info.Parent = ReplicatedStorage
	end

	local function setString(name, value)
		local object = info:FindFirstChild(name)
		if not object then
			object = Instance.new("StringValue")
			object.Name = name
			object.Parent = info
		end
		object.Value = tostring(value or "")
	end

	setString("ServerId", data.serverId)
	setString("ServerName", data.serverName)
	setString("Map", data.map)
	setString("Gamemode", data.gamemode)
	setString("HostName", data.hostName)
	setString("HostUserId", data.hostUserId)
	setString("Region", data.region)
end

local function readTeleportData(player)
	local ok, joinData = pcall(function()
		return player:GetJoinData()
	end)
	if not ok or type(joinData) ~= "table" then
		return nil
	end
	local data = joinData.TeleportData
	if type(data) ~= "table" or type(data.serverId) ~= "string" or data.serverId == "" then
		return nil
	end
	return data
end

local function startBattleServer()
	local serverId = nil
	local matchData = nil
	local startedAt = os.clock()

	local function consider(player)
		if serverId then
			return
		end
		local data = readTeleportData(player)
		if data then
			serverId = data.serverId
			matchData = data
		end
	end

	for _, player in ipairs(Players:GetPlayers()) do
		consider(player)
	end

	local connection = Players.PlayerAdded:Connect(consider)
	while not serverId and os.clock() - startedAt < 45 do
		task.wait(0.2)
	end
	connection:Disconnect()

	if not serverId or not matchData then
		warn("[ServerBrowser] This reserved server started without match teleport data, so it will not appear in the server list.")
		return
	end

	publishMatchInfo(matchData)
	print("[ServerBrowser] Battle server online:", matchData.serverName, matchData.map, matchData.gamemode)

	local function playerCount(exceptPlayer)
		local count = 0
		for _, player in ipairs(Players:GetPlayers()) do
			if player ~= exceptPlayer then
				count = count + 1
			end
		end
		return count
	end

	local function pushCount(count)
		if count <= 0 then
			backend.remove(serverId)
			return
		end
		local saved, err = backend.update(serverId, function(old)
			if type(old) ~= "table" then
				return nil
			end
			local nextValue = table.clone(old)
			nextValue.players = count
			nextValue.updatedAt = os.time()
			nextValue.joinResult = nil
			return nextValue
		end)
		if saved == nil then
			warn("[ServerBrowser] Player count was not saved. The listing may have expired.", err or "")
		end
	end

	pushCount(playerCount(nil))

	Players.PlayerAdded:Connect(function(player)
		local data = readTeleportData(player)
		if data and data.serverId == serverId then
			publishMatchInfo(data)
		end
		task.defer(function()
			pushCount(playerCount(nil))
		end)
	end)

	Players.PlayerRemoving:Connect(function(leaving)
		-- PlayerRemoving fires while the player is still in GetPlayers.
		pushCount(playerCount(leaving))
	end)

	task.spawn(function()
		while serverId do
			task.wait(Config.HeartbeatSeconds)
			pushCount(playerCount(nil))
		end
	end)

	game:BindToClose(function()
		backend.remove(serverId)
	end)
end

-- /lobby on a battle map. The Menu place allows one player per server, so a
-- public teleport opens a new lobby server when the current one has no room.
local lobbyPlaceIdCache = nil
local lobbyDeparting = {}

local function resolveLobbyPlaceId()
	if type(Config.LobbyPlaceId) == "number" and Config.LobbyPlaceId > 0 then
		return Config.LobbyPlaceId
	end
	if lobbyPlaceIdCache then
		return lobbyPlaceIdCache
	end

	local ok, pages = pcall(function()
		return AssetService:GetGamePlacesAsync()
	end)
	if not ok or not pages then
		warn("[ServerBrowser] Could not look up places. Set Config.LobbyPlaceId to the Menu place.")
		return nil
	end

	local wanted = string.lower(Listing.trim(Config.LobbyPlaceName or "Menu"))
	local found = nil
	local readOk, readErr = pcall(function()
		while true do
			for _, place in ipairs(pages:GetCurrentPage()) do
				local name = place.Name
				local placeId = place.PlaceId
				if type(name) == "string" and type(placeId) == "number" and string.lower(Listing.trim(name)) == wanted then
					found = placeId
				end
			end
			if pages.IsFinished then
				break
			end
			pages:AdvanceToNextPageAsync()
		end
	end)
	if not readOk then
		warn("[ServerBrowser] Could not read the place list:", readErr)
		return nil
	end
	if not found then
		warn("[ServerBrowser] No place named \"" .. wanted .. "\". Set Config.LobbyPlaceId to the Menu place.")
		return nil
	end
	lobbyPlaceIdCache = found
	print("[ServerBrowser] Lobby place id:", found)
	return found
end

local function tellLobby(player, text)
	warn("[ServerBrowser]", player.Name .. ": " .. text)
	pcall(function()
		local channels = TextChatService:FindFirstChild("TextChannels")
		local general = channels and channels:FindFirstChild("RBXGeneral")
		if general then
			general:DisplaySystemMessage(text)
		end
	end)
end

local function teleportToLobby(player)
	if lobbyDeparting[player.UserId] then
		return
	end
	lobbyDeparting[player.UserId] = true

	if RunService:IsStudio() then
		tellLobby(player, "Lobby teleport only works in the published game.")
		lobbyDeparting[player.UserId] = nil
		return
	end

	local placeId = resolveLobbyPlaceId()
	if not placeId then
		tellLobby(player, "The lobby place is not set.")
		lobbyDeparting[player.UserId] = nil
		return
	end
	if placeId == game.PlaceId and not isReservedServer() then
		tellLobby(player, "You are already in the lobby.")
		lobbyDeparting[player.UserId] = nil
		return
	end

	tellLobby(player, "Returning to the lobby...")
	local ok, err = pcall(function()
		TeleportService:TeleportAsync(placeId, { player })
	end)
	if not ok then
		warn("[ServerBrowser] Lobby teleport failed for " .. player.Name .. ": " .. tostring(err))
		tellLobby(player, "Could not return to the lobby. Try again.")
		lobbyDeparting[player.UserId] = nil
	end
end

local function isLobbyChat(message)
	local text = string.lower(Listing.trim(message or ""))
	return text == "/lobby" or text == "lobby"
end

local function bindLobbyCommand()
	local function onChat(player, message)
		if isLobbyChat(message) then
			teleportToLobby(player)
		end
	end

	local function hook(player)
		player.Chatted:Connect(function(message)
			onChat(player, message)
		end)
	end

	Players.PlayerAdded:Connect(hook)
	for _, player in ipairs(Players:GetPlayers()) do
		hook(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		lobbyDeparting[player.UserId] = nil
	end)

	pcall(function()
		local existing = TextChatService:FindFirstChild("LobbyCommand")
		if existing then
			existing:Destroy()
		end
		local command = Instance.new("TextChatCommand")
		command.Name = "LobbyCommand"
		command.PrimaryAlias = "/lobby"
		command.Triggered:Connect(function(origin, unfiltered)
			local player = Players:GetPlayerByUserId(origin.UserId)
			if player then
				onChat(player, unfiltered or "/lobby")
			end
		end)
		command.Parent = TextChatService
	end)
end

bindLobbyCommand()

if isReservedServer() then
	startBattleServer()
	return
end

local cache = {
	ok = false,
	at = 0,
	servers = {},
}

local function invalidateCache()
	cache.at = 0
end

local function publicServers()
	if cache.ok and os.clock() - cache.at < Config.ListCacheSeconds then
		return cache.servers
	end

	local items, err = backend.list()
	if not items then
		if cache.ok then
			warn("[ServerBrowser] Using the previous server list.", err)
			return cache.servers
		end
		return nil, err
	end

	local now = os.time()
	local rows = {}
	local seen = {}
	for _, item in ipairs(items) do
		local value = item.value
		-- ListItemsAsync can return the same key twice while a page is read.
		if type(value) == "table" and not seen[value.id] then
			if Listing.isListable(value, now, Config.StaleAfterSeconds) then
				seen[value.id] = true
				table.insert(rows, safeRow(value))
			elseif value.version == 1 and type(item.key) == "string" then
				local key = item.key
				task.spawn(function()
					backend.remove(key)
				end)
			end
		end
	end

	Listing.sortForDisplay(rows)
	Listing.capList(rows, Config.MaxListedServers)
	cache = {
		ok = true,
		at = os.clock(),
		servers = rows,
	}
	return rows
end

local function hostedCount(userId)
	local items, err = backend.list()
	if not items then
		return nil, err
	end
	local now = os.time()
	local count = 0
	for _, item in ipairs(items) do
		local value = item.value
		if Listing.isListable(value, now, Config.StaleAfterSeconds) and value.hostUserId == userId then
			count = count + 1
		end
	end
	return count
end

local function newEntry(fields)
	local now = os.time()
	return {
		version = 1,
		id = fields.id,
		name = fields.name,
		map = fields.map,
		gamemode = fields.gamemode,
		hostUserId = fields.hostUserId,
		hostName = fields.hostName,
		region = fields.region,
		players = 0,
		maxPlayers = fields.maxPlayers,
		password = fields.password,
		accessCode = fields.accessCode,
		privateServerId = fields.privateServerId,
		placeId = fields.placeId,
		createdAt = now,
		updatedAt = now,
	}
end

local function seedSamples()
	if not (usingMock and Config.SeedSampleServersInStudio) then
		return
	end
	local now = os.time()
	local samples = {
		{ id = "sample-100", players = 100, password = Config.SamplePassword, createdAt = now - 40 },
		{ id = "sample-75", players = 75, password = "", createdAt = now - 30 },
		{ id = "sample-50", players = 50, password = "", createdAt = now - 20 },
		{ id = "sample-10", players = 10, password = "", createdAt = now - 10 },
	}
	for _, sample in ipairs(samples) do
		if backend.get(sample.id) == nil then
			local sampleMap = Config.Maps[1]
			local sampleMapName = type(sampleMap) == "table" and sampleMap.name or sampleMap
			local entry = newEntry({
				id = sample.id,
				name = "France vs Britain",
				map = sampleMapName,
				gamemode = Config.Gamemodes[1],
				region = Config.Regions[1],
				hostUserId = 0,
				hostName = "Sample",
				maxPlayers = 150,
				password = sample.password,
				accessCode = "studio-sample",
				privateServerId = "studio-sample",
				placeId = placeIdForMap(sampleMapName),
			})
			entry.players = sample.players
			entry.createdAt = sample.createdAt
			entry.updatedAt = now
			backend.set(sample.id, entry)
		end
	end
	print("[ServerBrowser] Studio sample password for the 100-player row:", Config.SamplePassword)
end

seedSamples()

local rankCache = {}
local lastCreate = {}
local lastCreateFlood = {}
local lastJoin = {}

local function rememberRank(player, rank, roleName)
	rankCache[player.UserId] = {
		rank = rank,
		role = roleName,
		at = os.clock(),
	}
end

local function lookupGroup(player)
	local cached = rankCache[player.UserId]
	if cached and os.clock() - cached.at < 60 then
		return cached.rank, cached.role
	end

	if Config.GroupId == 0 then
		rememberRank(player, 0, "Guest")
		return 0, "Guest"
	end

	local rolesOk, result = pcall(function()
		return GroupService:GetRolesInGroupAsync(player.UserId, Config.GroupId)
	end)
	if rolesOk and type(result) == "table" and type(result.Roles) == "table" then
		local bestRank = nil
		local bestName = "Guest"
		for _, role in ipairs(result.Roles) do
			local rank = role.Rank
			if type(rank) == "number" and (bestRank == nil or rank > bestRank) then
				bestRank = rank
				if type(role.Name) == "string" and role.Name ~= "" then
					bestName = role.Name
				else
					bestName = "Guest"
				end
			end
		end
		if bestRank == nil then
			bestRank = 0
			bestName = "Guest"
		end
		rememberRank(player, bestRank, bestName)
		return bestRank, bestName
	end

	local rankOk, rank = pcall(function()
		return player:GetRankInGroupAsync(Config.GroupId)
	end)
	local roleOk, roleName = pcall(function()
		return player:GetRoleInGroupAsync(Config.GroupId)
	end)
	if not rankOk or type(rank) ~= "number" then
		return nil, nil
	end
	if not roleOk or type(roleName) ~= "string" or roleName == "" then
		roleName = "Guest"
	end
	rememberRank(player, rank, roleName)
	return rank, roleName
end

local function hostDecision(player)
	local inStudio = RunService:IsStudio()
	if Listing.isAlwaysAllowed(player.UserId, Config.AlwaysAllowUserIds) then
		return true, 0, ""
	end
	if inStudio and Config.BypassRankInStudio then
		local rank, roleName = lookupGroup(player)
		return true, rank or 0, roleName or ""
	end

	local rank, roleName = lookupGroup(player)
	if rank == nil then
		return false, 0, "Guest", "Could not check your group role. Try again."
	end
	local allowed = Listing.canHost(rank, player.UserId, Config, false)
	if allowed then
		return true, rank, roleName
	end
	return false, rank, roleName, Listing.denialMessage(rank, roleName, Config)
end

local function cooldownReady(bucket, userId, seconds)
	local now = os.clock()
	local previous = bucket[userId]
	if previous and now - previous < seconds then
		return false
	end
	bucket[userId] = now
	return true
end

local function filterServerName(player, name)
	local ok, result = pcall(function()
		return TextService:FilterStringAsync(name, player.UserId)
	end)
	if not ok then
		if RunService:IsStudio() then
			warn("[ServerBrowser] Text filter failed in Studio. The typed name was kept for this test.", result)
			return name, false
		end
		return nil, "Could not filter the server name. Try again."
	end

	local filteredOk, filtered = pcall(function()
		return result:GetNonChatStringForBroadcastAsync()
	end)
	if not filteredOk or type(filtered) ~= "string" then
		if RunService:IsStudio() then
			warn("[ServerBrowser] Text filter failed in Studio. The typed name was kept for this test.")
			return name, false
		end
		return nil, "Could not filter the server name. Try again."
	end

	filtered = Listing.trim(filtered)
	if filtered == "" then
		return nil, "That server name is not allowed."
	end
	return filtered, filtered ~= name
end

local function hostNameFor(player)
	local name = player.Name
	if type(name) ~= "string" or name == "" then
		name = "Host"
	end
	name = string.gsub(name, "%c", " ")
	return name
end

local function teleportDeniedMessage()
	if RunService:IsStudio() then
		return "Publish the place and test from the Roblox app."
	end
	return "Could not open the battle. Try again."
end

-- A new battle is a GUID. The first TeleportAsync that carries it creates
-- the reserved server. The same id sends the next soldier to that server.
local function openReservedServer()
	if usingMock then
		return "studio-mock", "studio-mock"
	end

	local ok, reservedId = pcall(function()
		return HttpService:GenerateGUID(false)
	end)
	if not ok or type(reservedId) ~= "string" or reservedId == "" then
		return nil, nil, reservedId
	end
	return reservedId, reservedId
end

local function callTeleport(placeId, player, options)
	local attempts = 1
	if not RunService:IsStudio() then
		attempts = 3
	end
	local attempt = 0
	local lastErr = nil
	while attempt < attempts do
		if player.Parent == nil then
			return false, "You left before the teleport finished."
		end
		attempt = attempt + 1
		local ok, result = pcall(function()
			return TeleportService:TeleportAsync(placeId, { player }, options)
		end)
		if ok then
			return true, result
		end
		lastErr = result
		if attempt < attempts then
			task.wait(1)
		end
	end
	return false, lastErr
end

local function teleportToBattle(player, entry)
	local data = safeTeleportData(entry)
	local carried = player:FindFirstChild("SoldierAppearance")
	if carried and carried:IsA("StringValue") and carried.Value ~= "" then
		data = table.clone(data)
		data.appearance = carried.Value
	end
	local settingsCarry = player:FindFirstChild("GameSettings")
	if settingsCarry and settingsCarry:IsA("StringValue") and settingsCarry.Value ~= "" then
		if data.appearance == nil then
			data = table.clone(data)
		end
		data.settings = settingsCarry.Value
	end
	if usingMock then
		return true, true
	end

	local options = Instance.new("TeleportOptions")
	local reservedId = entry.privateServerId
	if type(reservedId) == "string" and reservedId ~= "" then
		options.ReservedServerId = reservedId
	elseif type(entry.accessCode) == "string" and entry.accessCode ~= "" then
		-- A match listed before reserved ids. The old access code still routes.
		options.ReservedServerAccessCode = entry.accessCode
	else
		warn("[ServerBrowser] " .. player.Name .. " had no reserved server id.")
		return false, false
	end
	options:SetTeleportData(data)

	local ok, err = callTeleport(entry.placeId, player, options)
	if not ok then
		warn("[ServerBrowser] Teleport failed for " .. player.Name .. ": " .. tostring(err))
		return false, false
	end
	return true, false
end

local function failJoinClaim(entryId)
	backend.update(entryId, function(old)
		if type(old) ~= "table" then
			return nil
		end
		local nextValue = table.clone(old)
		nextValue.players = math.max(0, (nextValue.players or 1) - 1)
		nextValue.joinResult = nil
		return nextValue
	end)
end

local function claimAndTeleport(player, serverId, password)
	if type(serverId) ~= "string" or serverId == "" or #serverId > 64 then
		return { ok = false, error = "That server no longer exists." }
	end
	if type(password) ~= "string" then
		password = ""
	end
	if #password > Config.MaxPasswordLength * 4 then
		return { ok = false, error = "Wrong password." }
	end
	password = Listing.trim(password)

	local current, readErr = backend.get(serverId)
	if readErr and current == nil then
		return { ok = false, error = "Could not reach that server. Try again." }
	end
	if type(current) ~= "table" or not Listing.isFresh(current, os.time(), Config.StaleAfterSeconds) then
		if type(current) == "table" then
			backend.remove(serverId)
		end
		invalidateCache()
		return { ok = false, error = "That server no longer exists." }
	end
	if type(current.password) == "string" and current.password ~= "" and current.password ~= password then
		return { ok = false, error = "Wrong password." }
	end

	local saved, updateErr = backend.update(serverId, function(old)
		if type(old) ~= "table" then
			return nil
		end
		local nextValue = table.clone(old)
		if type(nextValue.password) == "string" and nextValue.password ~= "" and nextValue.password ~= password then
			nextValue.joinResult = "password"
			return nextValue
		end
		local players = nextValue.players or 0
		local maxPlayers = nextValue.maxPlayers or 0
		if players >= maxPlayers then
			nextValue.joinResult = "full"
			return nextValue
		end
		if not Listing.isFresh(nextValue, os.time(), Config.StaleAfterSeconds) then
			return nil
		end
		nextValue.players = players + 1
		nextValue.updatedAt = os.time()
		nextValue.joinResult = "ok"
		return nextValue
	end)

	if updateErr and saved == nil then
		return { ok = false, error = "Could not reach that server. Try again." }
	end
	if type(saved) ~= "table" then
		backend.remove(serverId)
		invalidateCache()
		return { ok = false, error = "That server no longer exists." }
	end
	if saved.joinResult == "password" then
		return { ok = false, error = "Wrong password." }
	end
	if saved.joinResult == "full" then
		return { ok = false, error = "That server is full." }
	end
	if saved.joinResult ~= "ok" then
		return { ok = false, error = "That server no longer exists." }
	end
	if type(saved.placeId) ~= "number" or type(saved.accessCode) ~= "string" or saved.accessCode == "" then
		failJoinClaim(serverId)
		return { ok = false, error = "That server cannot be joined." }
	end

	invalidateCache()
	local teleported, mocked = teleportToBattle(player, saved)
	if not teleported then
		failJoinClaim(serverId)
		invalidateCache()
		return {
			ok = false,
			error = teleportDeniedMessage(),
		}
	end

	if mocked then
		return {
			ok = true,
			mock = true,
			message = "Studio practice list accepted the join. This session does not teleport.",
		}
	end
	return { ok = true, mock = false }
end

local function guarded(player, handler)
	local ok, result = pcall(handler, player)
	if not ok then
		warn("[ServerBrowser] Request failed for " .. player.Name .. ": " .. tostring(result))
		return { ok = false, error = "Something went wrong. Try again." }
	end
	if type(result) ~= "table" then
		return { ok = false, error = "Something went wrong. Try again." }
	end
	return result
end

getServers.OnServerInvoke = function(player)
	return guarded(player, function()
		local servers, err = publicServers()
		if not servers then
			warn("[ServerBrowser] List failed:", err)
			return { ok = false, error = "Could not load servers." }
		end
		return {
			ok = true,
			servers = servers,
			mock = usingMock,
		}
	end)
end

getPermission.OnServerInvoke = function(player)
	return guarded(player, function()
		local allowed, rank, roleName, message = hostDecision(player)
		return {
			ok = true,
			canHost = allowed,
			rank = rank,
			role = roleName,
			message = message,
		}
	end)
end

-- The Host column is the host's region. The menu cannot pick it.
local function detectRegion(player)
	local fallback = Config.Regions[1]
	local ok, code = pcall(function()
		return LocalizationService:GetCountryRegionForPlayerAsync(player)
	end)
	if not ok or type(code) ~= "string" then
		warn("[ServerBrowser] Could not detect the host region. Using " .. tostring(fallback) .. ".")
		return fallback
	end
	local region = Listing.regionForCountry(code, Config.Regions)
	if not region then
		warn("[ServerBrowser] No region for country " .. code .. ". Using " .. tostring(fallback) .. ".")
		return fallback
	end
	return region
end

createServer.OnServerInvoke = function(player, payload)
	return guarded(player, function()
		if not cooldownReady(lastCreateFlood, player.UserId, 1) then
			return { ok = false, error = "Wait a moment before creating another server." }
		end

		local cleaned, problem = Listing.validateCreate(payload, Config)
		if not cleaned then
			return { ok = false, error = problem }
		end

		local allowed, _, _, message = hostDecision(player)
		if not allowed then
			return { ok = false, error = message }
		end

		if not cooldownReady(lastCreate, player.UserId, Config.CreateCooldown) then
			return { ok = false, error = "Wait a moment before creating another server." }
		end

		local count, countErr = hostedCount(player.UserId)
		if count == nil then
			warn("[ServerBrowser] Could not check existing servers:", countErr)
			return { ok = false, error = "Could not check your existing servers. Try again." }
		end
		if count >= Config.MaxServersPerPlayer then
			return { ok = false, error = "You already have a server open." }
		end

		local filteredName, nameWasFilteredOrErr = filterServerName(player, cleaned.name)
		if not filteredName then
			return { ok = false, error = nameWasFilteredOrErr }
		end
		local nameWasFiltered = nameWasFilteredOrErr == true

		local region = detectRegion(player)
		local placeId = placeIdForMap(cleaned.map)
		local accessCode, privateServerId, reserveErr = openReservedServer()
		if not accessCode then
			warn("[ServerBrowser] Could not open a reserved server:", reserveErr)
			return {
				ok = false,
				error = "Could not open a battle server. Try again.",
			}
		end

		if not player.Parent then
			return { ok = false, error = "You left before the server was created." }
		end

		local serverId = HttpService:GenerateGUID(false)
		local entry = newEntry({
			id = serverId,
			name = filteredName,
			map = cleaned.map,
			gamemode = cleaned.gamemode,
			hostUserId = player.UserId,
			hostName = hostNameFor(player),
			region = region,
			maxPlayers = cleaned.maxPlayers,
			password = cleaned.password,
			accessCode = accessCode,
			privateServerId = privateServerId or "",
			placeId = placeId,
		})

		local saved, saveErr = backend.set(serverId, entry)
		if not saved then
			warn("[ServerBrowser] Could not store the server:", saveErr)
			return { ok = false, error = "Could not save the server. Try again." }
		end

		invalidateCache()
		local teleported, mocked = teleportToBattle(player, entry)
		if not teleported then
			backend.remove(serverId)
			invalidateCache()
			return {
				ok = false,
				error = teleportDeniedMessage(),
			}
		end

		local response = {
			ok = true,
			mock = mocked,
			name = filteredName,
			filtered = nameWasFiltered,
		}
		if mocked then
			response.message = "Server listed. Studio does not teleport you into it."
		end
		return response
	end)
end

joinServer.OnServerInvoke = function(player, serverId, password)
	return guarded(player, function()
		if not cooldownReady(lastJoin, player.UserId, Config.JoinCooldown) then
			return { ok = false, error = "Wait a moment before joining again." }
		end
		return claimAndTeleport(player, serverId, password)
	end)
end

quickPlay.OnServerInvoke = function(player)
	return guarded(player, function()
		if not cooldownReady(lastJoin, player.UserId, Config.JoinCooldown) then
			return { ok = false, error = "Wait a moment before joining again." }
		end

		local servers, err = publicServers()
		if not servers then
			warn("[ServerBrowser] Quick play list failed:", err)
			return { ok = false, error = "Could not load servers." }
		end

		local attempts = 0
		for _, info in ipairs(servers) do
			if info.hasPassword ~= true and info.players < info.maxPlayers then
				attempts = attempts + 1
				local result = claimAndTeleport(player, info.id, "")
				if result.ok then
					return result
				end
				local softFailure = result.error == "Wrong password."
					or result.error == "That server is full."
					or result.error == "That server no longer exists."
				if not softFailure or attempts >= 3 then
					return result
				end
			end
		end

		return { ok = false, error = "No open servers to join." }
	end)
end

Players.PlayerRemoving:Connect(function(player)
	lastCreate[player.UserId] = nil
	lastCreateFlood[player.UserId] = nil
	lastJoin[player.UserId] = nil
	rankCache[player.UserId] = nil
end)

if Config.GroupId == 0 and not RunService:IsStudio() then
	warn("[ServerBrowser] GroupId is 0, so nobody can create a server. Set it in ReplicatedStorage.ServerBrowser.Config.")
end
if RunService:IsStudio() and Config.BypassRankInStudio then
	warn("[ServerBrowser] Studio is skipping the group rank check. Set BypassRankInStudio to false to test ranks.")
end
if usingMock then
	print("[ServerBrowser] Studio practice list is on. No reserved server will be created from this session.")
else
	print(string.format(
		"[ServerBrowser] Lobby ready. Group %d, minimum rank %d (%s).",
		Config.GroupId,
		Config.MinimumRank,
		Config.MinimumRankName
	))
end
