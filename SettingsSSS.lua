local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")

-- ReplicatedStorage.Settings may be the ModuleScript itself, or a folder
-- with that ModuleScript inside it.
local function loadOrders()
	local found = ReplicatedStorage:WaitForChild("Settings", 20)
	if not found then
		warn("[Settings] Copy ReplicatedStorage.Settings into this place.")
		return nil
	end
	local moduleScript = found
	if not moduleScript:IsA("ModuleScript") then
		moduleScript = found:FindFirstChild("Settings") or found:FindFirstChildWhichIsA("ModuleScript")
		if not moduleScript then
			moduleScript = found:WaitForChild("Settings", 5)
		end
	end
	if not moduleScript or not moduleScript:IsA("ModuleScript") then
		warn("[Settings] ReplicatedStorage.Settings is a " .. found.ClassName .. ". Make it a ModuleScript and paste Settings.luau into it.")
		return nil
	end
	local ok, result = pcall(require, moduleScript)
	if not ok or type(result) ~= "table" or type(result.sanitize) ~= "function" then
		warn("[Settings] ReplicatedStorage.Settings did not load. Paste Settings.luau into that ModuleScript. " .. tostring(result))
		return nil
	end
	return result
end

local catalog = loadOrders()
if not catalog then
	return
end

local STORE_NAME = "SYW_GameSettings_v1"
local store = nil
local storeReady = false
local storeWarned = false
local storeOk, storeOrErr = pcall(function()
	return DataStoreService:GetDataStore(STORE_NAME)
end)
if storeOk then
	store = storeOrErr
	storeReady = true
else
	storeWarned = true
	warn("[Settings] DataStore is unavailable (" .. tostring(storeOrErr) .. "). Choices apply for this visit only. Enable Studio Access to API Services to keep them.")
end

local function warnStoreOnce(message)
	if storeWarned then
		return
	end
	storeWarned = true
	warn("[Settings] " .. message)
end

local remotes = ReplicatedStorage:FindFirstChild("SettingsRemotes")
if not remotes then
	remotes = Instance.new("Folder")
	remotes.Name = "SettingsRemotes"
	remotes.Parent = ReplicatedStorage
end

local function remote(name)
	local existing = remotes:FindFirstChild(name)
	if existing and existing:IsA("RemoteFunction") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local created = Instance.new("RemoteFunction")
	created.Name = name
	created.Parent = remotes
	return created
end

local getSettings = remote("GetSettings")
local setSettings = remote("SetSettings")

local memory = {}
local canPersist = {}
local saveToken = {}
local locks = {}

local function carriedSettings(player)
	local ok, joinData = pcall(function()
		return player:GetJoinData()
	end)
	if not ok or type(joinData) ~= "table" then
		return nil
	end
	local data = joinData.TeleportData
	if type(data) ~= "table" or type(data.settings) ~= "string" or data.settings == "" then
		return nil
	end
	local decodedOk, decoded = pcall(function()
		return HttpService:JSONDecode(data.settings)
	end)
	if not decodedOk then
		return nil
	end
	return catalog.sanitize(decoded)
end

local function loadSettings(player)
	if not storeReady then
		canPersist[player.UserId] = false
		return catalog.defaultSettings()
	end
	local ok, data = pcall(function()
		return store:GetAsync(tostring(player.UserId))
	end)
	if not ok then
		canPersist[player.UserId] = false
		warnStoreOnce("Could not read saved settings (" .. tostring(data) .. "). This visit uses the standing orders and will not overwrite a saved copy.")
		return catalog.defaultSettings()
	end
	canPersist[player.UserId] = true
	if data == nil then
		return catalog.defaultSettings()
	end
	return catalog.sanitize(data)
end

local function publishCarry(player, settings)
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(catalog.sanitize(settings))
	end)
	if not ok or type(encoded) ~= "string" then
		return
	end
	local tag = player:FindFirstChild("GameSettings")
	if not tag then
		tag = Instance.new("StringValue")
		tag.Name = "GameSettings"
		tag.Parent = player
	end
	tag.Value = encoded
end

local function flush(player)
	if not player then
		return
	end
	local settings = memory[player.UserId]
	if not settings or not canPersist[player.UserId] or not storeReady then
		return
	end
	local payload = catalog.sanitize(settings)
	local ok, err = pcall(function()
		store:SetAsync(tostring(player.UserId), payload)
	end)
	if not ok then
		warn("[Settings] Could not save settings for " .. player.Name .. ": " .. tostring(err))
	end
end

local function scheduleSave(player)
	local token = {}
	saveToken[player.UserId] = token
	task.delay(1, function()
		if saveToken[player.UserId] ~= token then
			return
		end
		if player.Parent ~= Players then
			return
		end
		flush(player)
	end)
end

local function ensureSettings(player)
	if memory[player.UserId] then
		return memory[player.UserId]
	end
	local carried = carriedSettings(player)
	if carried then
		memory[player.UserId] = carried
		canPersist[player.UserId] = storeReady
		publishCarry(player, carried)
		return carried
	end
	local settings = loadSettings(player)
	if memory[player.UserId] then
		return memory[player.UserId]
	end
	memory[player.UserId] = settings
	publishCarry(player, settings)
	return settings
end

local function withLock(player, callback)
	while locks[player.UserId] do
		task.wait()
	end
	locks[player.UserId] = true
	local ok, result = pcall(callback)
	locks[player.UserId] = nil
	if not ok then
		warn("[Settings] " .. tostring(result))
		return { ok = false, error = "Could not keep those orders." }
	end
	return result
end

getSettings.OnServerInvoke = function(player)
	return withLock(player, function()
		local settings = ensureSettings(player)
		return { ok = true, settings = catalog.sanitize(settings) }
	end)
end

setSettings.OnServerInvoke = function(player, raw)
	return withLock(player, function()
		if type(raw) ~= "table" then
			return { ok = false, error = "Could not keep those orders." }
		end
		local settings = catalog.sanitize(raw)
		memory[player.UserId] = settings
		if canPersist[player.UserId] == nil then
			canPersist[player.UserId] = storeReady
		end
		publishCarry(player, settings)
		scheduleSave(player)
		return { ok = true, settings = settings }
	end)
end

local function bind(player)
	task.spawn(ensureSettings, player)
end

Players.PlayerAdded:Connect(bind)
for _, player in ipairs(Players:GetPlayers()) do
	bind(player)
end

Players.PlayerRemoving:Connect(function(player)
	saveToken[player.UserId] = nil
	flush(player)
	memory[player.UserId] = nil
	canPersist[player.UserId] = nil
	locks[player.UserId] = nil
end)

game:BindToClose(function()
	for _, player in ipairs(Players:GetPlayers()) do
		saveToken[player.UserId] = nil
		flush(player)
	end
end)
