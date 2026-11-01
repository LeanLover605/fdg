local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local InsertService = game:GetService("InsertService")
local HttpService = game:GetService("HttpService")
local StarterGui = game:GetService("StarterGui")

local function inStarterGui(name)
	return StarterGui:FindFirstChild(name, true) ~= nil
end

local reservedBattle = game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0
local menuPlace = not reservedBattle and (inStarterGui("Customise UI") or inStarterGui("Main Menu"))

-- Clients wait on this folder. Create it before setup can fail, including
-- when the barracks model is not in Workspace yet.
local startingError = "Customisation is still starting."
local getAppearance = nil
local setAppearance = nil

local function ensureRemote(parent, name)
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("RemoteFunction") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local created = Instance.new("RemoteFunction")
	created.Name = name
	created.Parent = parent
	return created
end

if menuPlace then
	local remotes = ReplicatedStorage:FindFirstChild("CustomiseRemotes")
	if not remotes then
		remotes = Instance.new("Folder")
		remotes.Name = "CustomiseRemotes"
		remotes.Parent = ReplicatedStorage
	end
	getAppearance = ensureRemote(remotes, "GetAppearance")
	setAppearance = ensureRemote(remotes, "SetAppearance")
	local function starting()
		return { ok = false, error = startingError }
	end
	getAppearance.OnServerInvoke = function()
		return starting()
	end
	setAppearance.OnServerInvoke = function()
		return starting()
	end
end

local catalogFolder = ReplicatedStorage:WaitForChild("Customise", 20)
if not catalogFolder then
	startingError = "ReplicatedStorage.Customise is missing, so the barracks cannot load."
	warn("[Customise] " .. startingError)
	return
end
local catalog = require(catalogFolder:WaitForChild("Catalog"))

local STORE_NAME = "SYW_SoldierCustomise_v1"
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
	warn("[Customise] DataStore is unavailable (" .. tostring(storeOrErr) .. "). Choices preview in this server only. Enable Studio Access to API Services to keep them.")
end

local memory = {}
local canPersist = {}
local saveToken = {}
local locks = {}
local missingWarned = {}

local SKIN_PARTS = {
	"Head",
	"Left Arm",
	"Right Arm",
	"LeftHand",
	"RightHand",
	"LeftLowerArm",
	"RightLowerArm",
	"LeftUpperArm",
	"RightUpperArm",
}

local function warnStoreOnce(message)
	if storeWarned then
		return
	end
	storeWarned = true
	warn("[Customise] " .. message)
end

local function displayModel()
	local named = workspace:FindFirstChild("Character", true)
	if named and named:IsA("Model") then
		return named
	end
	for _, inst in ipairs(workspace:GetDescendants()) do
		if inst:IsA("Model") and string.lower(inst.Name) == "character" then
			return inst
		end
	end
	return nil
end

local function clearSlot(model, slot)
	local removing = {}
	for _, child in ipairs(model:GetChildren()) do
		if child:GetAttribute("CustomiseSlot") == slot then
			table.insert(removing, child)
		end
	end
	for _, child in ipairs(removing) do
		child:Destroy()
	end
end

local function warnMissing(key, message)
	if missingWarned[key] then
		return
	end
	missingWarned[key] = true
	warn("[Customise] " .. message)
end

local function clonedRig(source)
	if source:IsA("Model") then
		return source:Clone()
	end
	local model = Instance.new("Model")
	model.Name = source.Name
	for _, child in ipairs(source:GetChildren()) do
		child:Clone().Parent = model
	end
	return model
end

local function applyRig(model, slot, item)
	local wanted = item and item.id or ""
	local attribute = "CustomiseApplied_" .. slot
	if model:GetAttribute(attribute) == wanted then
		local stillThere = wanted == ""
		for _, child in ipairs(model:GetChildren()) do
			if child:GetAttribute("CustomiseSlot") == slot then
				stillThere = true
			end
		end
		if stillThere then
			return
		end
	end

	clearSlot(model, slot)
	model:SetAttribute(attribute, wanted)
	if not item then
		return
	end

	local source = catalog.sourceFor(slot, item.id)
	if not source then
		warnMissing(slot .. ":" .. item.id, "\"" .. item.name .. "\" is no longer in the customisation models.")
		return
	end

	local anchorName = catalog.anchorName(slot)
	local characterAnchor = model:FindFirstChild(anchorName)
	if not characterAnchor or not characterAnchor:IsA("BasePart") then
		warnMissing(slot .. ":anchor", "The soldier needs a part named " .. tostring(anchorName) .. ".")
		return
	end
	local templateAnchor = source:FindFirstChild(anchorName, true)
	if not templateAnchor or not templateAnchor:IsA("BasePart") then
		warnMissing(slot .. ":" .. item.id .. ":anchor", "\"" .. item.name .. "\" needs a part named " .. anchorName .. " so it can be placed.")
		return
	end

	local clone = clonedRig(source)
	clone.Name = item.name
	clone:SetAttribute("CustomiseSlot", slot)
	local anchor = clone:FindFirstChild(anchorName, true)
	clone:PivotTo(characterAnchor.CFrame * anchor.CFrame:Inverse() * clone:GetPivot())
	for _, part in ipairs(clone:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = false
			part.CanCollide = false
			part.Massless = true
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = characterAnchor
			weld.Part1 = part
			weld.Parent = part
		end
	end
	-- The grouped Head or Torso is only the morph guide. The character's
	-- own body part stays the one that is visible.
	anchor.Transparency = 1
	anchor.CastShadow = false
	pcall(function()
		anchor.CanQuery = false
		anchor.CanTouch = false
	end)
	for _, child in ipairs(anchor:GetDescendants()) do
		if child:IsA("Decal") or child:IsA("Texture") then
			child:Destroy()
		elseif child:IsA("SpecialMesh") then
			pcall(function()
				child.TextureId = ""
			end)
		end
	end
	anchor.Name = "CustomiseGuide"
	clone.Parent = model
end

local function applySkin(model, item)
	if not item or type(item.brickColor) ~= "string" then
		return
	end
	local color = BrickColor.new(item.brickColor)
	local bodyColors = model:FindFirstChildOfClass("BodyColors")
	if not bodyColors then
		bodyColors = Instance.new("BodyColors")
		bodyColors.Parent = model
	end
	bodyColors.HeadColor = color
	bodyColors.LeftArmColor = color
	bodyColors.RightArmColor = color
	for _, partName in ipairs(SKIN_PARTS) do
		local part = model:FindFirstChild(partName)
		if part and part:IsA("BasePart") then
			part.Color = color.Color
		end
	end
end

local faceTemplates = {}

local function readTexture(instance)
	local ok, value = pcall(function()
		return instance.Texture
	end)
	if ok and type(value) == "string" and value ~= "" then
		return value
	end
	return nil
end

-- A Face folder value is a decal asset id. ImageLabels accept that id
-- directly. The head decal needs the image inside the decal, so load
-- the asset and copy its texture. A plain image id still works.
local function faceTemplate(assetId)
	local id = catalog.parseAssetId(assetId)
	if not id then
		return nil
	end
	if faceTemplates[id] then
		return faceTemplates[id]
	end
	local template = Instance.new("Decal")
	template.Name = "FaceTemplate"
	template.Face = Enum.NormalId.Front
	template.Color3 = Color3.new(1, 1, 1)
	template.Texture = "rbxassetid://" .. tostring(id)
	pcall(function()
		template.TextureContent = Content.fromAssetId(id)
	end)
	local ok, loaded = pcall(function()
		return InsertService:LoadAsset(id)
	end)
	if ok and loaded then
		local source = loaded:FindFirstChildWhichIsA("Decal", true) or loaded:FindFirstChildWhichIsA("Texture", true)
		if source then
			local texture = readTexture(source)
			if texture then
				template.Texture = texture
			end
			pcall(function()
				template.TextureContent = source.TextureContent
			end)
		end
		loaded:Destroy()
	end
	template.Parent = script
	faceTemplates[id] = template
	return template
end

local function applyFace(model, item)
	if not item then
		return
	end
	local template = faceTemplate(item.texture)
	if not template then
		return
	end
	local head = model:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		warnMissing("face:head", "The soldier needs a Head part with a face decal.")
		return
	end
	local faceSide = Enum.NormalId.Front
	local removing = {}
	for _, object in ipairs(head:GetDescendants()) do
		local isFace = (object:IsA("Decal") or object:IsA("Texture")) and string.lower(object.Name) == "face"
		if isFace then
			if object:IsA("Decal") then
				faceSide = object.Face
			end
			table.insert(removing, object)
		end
	end
	for _, object in ipairs(removing) do
		object:Destroy()
	end
	local decal = template:Clone()
	decal.Name = "face"
	decal.Face = faceSide
	decal.Transparency = 0
	decal.Color3 = Color3.new(1, 1, 1)
	decal.Parent = head
end

local function tintHair(model, item)
	if not item or type(item.brickColor) ~= "string" then
		return
	end
	local color = BrickColor.new(item.brickColor).Color
	for _, child in ipairs(model:GetChildren()) do
		if child:GetAttribute("CustomiseSlot") == "hair" then
			for _, part in ipairs(child:GetDescendants()) do
				if part:IsA("BasePart") and part.Name ~= "CustomiseGuide" then
					part.Color = color
					local mesh = part:FindFirstChildOfClass("SpecialMesh")
					if mesh then
						mesh.VertexColor = Vector3.new(color.R, color.G, color.B)
					end
				end
			end
		end
	end
end

local function applyAppearance(model, appearance)
	if not model or not appearance then
		return
	end
	applySkin(model, catalog.findItem("skin", appearance.skin))
	applyRig(model, "hair", catalog.findItem("hair", appearance.hair))
	applyRig(model, "facialHair", catalog.findItem("facialHair", appearance.facialHair))
	applyRig(model, "accessory", catalog.findItem("accessory", appearance.accessory))
	tintHair(model, catalog.findItem("hairColor", appearance.hairColor))
	applyFace(model, catalog.findItem("face", appearance.face))
end

local function loadAppearance(player)
	if not storeReady then
		canPersist[player.UserId] = false
		return catalog.defaultAppearance()
	end
	local ok, data = pcall(function()
		return store:GetAsync(tostring(player.UserId))
	end)
	if not ok then
		canPersist[player.UserId] = false
		warnStoreOnce("Could not read saved customisation (" .. tostring(data) .. "). This visit starts from the barracks defaults and will not overwrite a saved soldier.")
		return catalog.defaultAppearance()
	end
	canPersist[player.UserId] = true
	return catalog.sanitize(data)
end

local function flush(player)
	if not player then
		return
	end
	local appearance = memory[player.UserId]
	if not appearance or not canPersist[player.UserId] or not storeReady then
		return
	end
	local payload = catalog.sanitize(appearance)
	local ok, err = pcall(function()
		store:SetAsync(tostring(player.UserId), payload)
	end)
	if not ok then
		warn("[Customise] Could not save customisation for " .. player.Name .. ": " .. tostring(err))
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

local function dressDisplay(appearance)
	applyAppearance(displayModel(), appearance)
end

local function publishCarry(player, appearance)
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(catalog.sanitize(appearance))
	end)
	if not ok or type(encoded) ~= "string" then
		return
	end
	local tag = player:FindFirstChild("SoldierAppearance")
	if not tag then
		tag = Instance.new("StringValue")
		tag.Name = "SoldierAppearance"
		tag.Parent = player
	end
	tag.Value = encoded
end

local function carriedAppearance(player)
	local ok, joinData = pcall(function()
		return player:GetJoinData()
	end)
	if not ok or type(joinData) ~= "table" then
		return nil
	end
	local data = joinData.TeleportData
	if type(data) ~= "table" or type(data.appearance) ~= "string" or data.appearance == "" then
		return nil
	end
	local decodedOk, decoded = pcall(function()
		return HttpService:JSONDecode(data.appearance)
	end)
	if not decodedOk then
		return nil
	end
	return catalog.sanitize(decoded)
end

local function remember(player, appearance)
	memory[player.UserId] = appearance
	publishCarry(player, appearance)
	dressDisplay(appearance)
	scheduleSave(player)
end

local function ensureAppearance(player)
	if memory[player.UserId] then
		return memory[player.UserId]
	end
	if not menuPlace then
		local carried = carriedAppearance(player)
		if carried then
			memory[player.UserId] = carried
			return carried
		end
	end
	local appearance = loadAppearance(player)
	if memory[player.UserId] then
		return memory[player.UserId]
	end
	memory[player.UserId] = appearance
	return appearance
end

local function setupPlayer(player)
	local appearance = ensureAppearance(player)
	publishCarry(player, appearance)
	dressDisplay(appearance)
end

local function withLock(player, callback)
	while locks[player.UserId] do
		task.wait()
	end
	locks[player.UserId] = true
	local ok, result = pcall(callback)
	locks[player.UserId] = nil
	if not ok then
		warn("[Customise] " .. tostring(result))
		return { ok = false, error = "Could not update the soldier." }
	end
	return result
end

local function bindMenu(player)
	task.spawn(setupPlayer, player)
end

local function dressSpawned(player, character)
	if not character then
		return
	end
	local head = character:FindFirstChild("Head") or character:WaitForChild("Head", 15)
	if not head or player.Character ~= character then
		return
	end
	local appearance = ensureAppearance(player)
	if player.Character ~= character then
		return
	end
	applyAppearance(character, appearance)
end

local function bindBattle(player)
	player.CharacterAdded:Connect(function(character)
		task.spawn(dressSpawned, player, character)
	end)
	if player.Character then
		task.spawn(dressSpawned, player, player.Character)
	end
end

if menuPlace then
	local function dressEveryone()
		for _, appearance in pairs(memory) do
			dressDisplay(appearance)
		end
	end
	if displayModel() == nil then
		warn("[Customise] No model named Character is in Workspace yet. The barracks list still runs, and the soldier is dressed when that model appears.")
		workspace.DescendantAdded:Connect(function(inst)
			if inst:IsA("Model") and string.lower(inst.Name) == "character" then
				dressEveryone()
			end
		end)
	end

	getAppearance.OnServerInvoke = function(player)
		return withLock(player, function()
			local appearance = ensureAppearance(player)
			dressDisplay(appearance)
			return { ok = true, appearance = catalog.sanitize(appearance) }
		end)
	end

	setAppearance.OnServerInvoke = function(player, categoryId, itemId)
		return withLock(player, function()
			if type(categoryId) ~= "string" or type(itemId) ~= "string" then
				return { ok = false, error = "That choice is not available." }
			end
			if #categoryId > 32 or #itemId > 120 then
				return { ok = false, error = "That choice is not available." }
			end
			local item = catalog.findItem(categoryId, itemId)
			if not item then
				return { ok = false, error = "That choice is not available." }
			end
			local appearance = ensureAppearance(player)
			appearance[categoryId] = item.id
			remember(player, appearance)
			return { ok = true, appearance = catalog.sanitize(appearance) }
		end)
	end

	Players.PlayerAdded:Connect(bindMenu)
	for _, player in ipairs(Players:GetPlayers()) do
		bindMenu(player)
	end
else
	Players.PlayerAdded:Connect(bindBattle)
	for _, player in ipairs(Players:GetPlayers()) do
		bindBattle(player)
	end
end

Players.PlayerRemoving:Connect(function(player)
	saveToken[player.UserId] = nil
	if menuPlace then
		flush(player)
	end
	memory[player.UserId] = nil
	canPersist[player.UserId] = nil
	locks[player.UserId] = nil
end)

game:BindToClose(function()
	if not menuPlace then
		return
	end
	for _, player in ipairs(Players:GetPlayers()) do
		saveToken[player.UserId] = nil
		flush(player)
	end
end)
