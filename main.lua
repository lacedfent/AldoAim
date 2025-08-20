--// ===================================================================================
--// --- Cleanup routine to prevent duplicates when re-executing ---
--// ===================================================================================
pcall(function()
	if _G.AimESP_RS_CONN and _G.AimESP_RS_CONN.Connected then
		_G.AimESP_RS_CONN:Disconnect()
	end
	if _G.AimESP_FOV_CIRCLE then
		_G.AimESP_FOV_CIRCLE:Remove()
	end
	local playerGui = game:GetService("Players").LocalPlayer and game:GetService("Players").LocalPlayer:FindFirstChild("PlayerGui")
	local coreGui = game:GetService("CoreGui")
	if playerGui and playerGui:FindFirstChild("AimESP_UI") then
		playerGui:FindFirstChild("AimESP_UI"):Destroy()
	end
	if coreGui and coreGui:FindFirstChild("AimESP_UI") then
		coreGui:FindFirstChild("AimESP_UI"):Destroy()
	end
end)


--// Services
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local Camera = workspace.CurrentCamera
local LocalPlayer = Players.LocalPlayer

--// SETTINGS (live-updated by GUI, with save/load functionality)
local settings = {
	-- Aimbot
	camlock = true,
	fovCircle = true,
	aimRadius = 150, -- px
	smoothness = 1.00, -- 1.00 = snap
	aimPart = "Head", -- New: Head, UpperTorso, HumanoidRootPart

	-- Fly
	flyEnabled = false,
	flySpeed = 50,

	-- ESP
	espEnabled = true,
	boxESP = true,
	skelESP = true,
	healthBar = true, -- New
	infoESP = true, -- New: Name + Distance
	espVisibleColor = Color3.fromRGB(0, 255, 180), -- New
	espOccludedColor = Color3.fromRGB(255, 80, 80), -- New

	-- Targeting
	targetNPCs = true, -- include NPCs/dummies
	targetPlayers = true, -- include players
	
	-- Misc
	walkSpeed = 16,
	noclipEnabled = false, -- <-- NEW

	-- Keybinds (New)
	keybinds = {
		toggleGUI = Enum.KeyCode.RightControl,
		toggleFly = Enum.KeyCode.N,
	}
}

local holdingRMB = false
local targetModel = nil
local originalWalkSpeed = nil
local listeningForKeybind = nil -- For changing keybinds

-- === Team check (top-level) ===
local function isEnemy(plr)
	if not plr then return false end
	if LocalPlayer.Team and plr.Team then
		return plr.Team ~= LocalPlayer.Team
	end
	return true
end

--// Fly runtime state (BodyVelocity + BodyGyro)
local hrp, humanoid = nil, nil
local flyBV, flyBG = nil, nil

local function enableFly()
	if not hrp or flyBV then return end

	flyBV = Instance.new("BodyVelocity")
	flyBV.MaxForce = Vector3.new(9e9, 9e9, 9e9)
	flyBV.Velocity = Vector3.new(0,0,0)
	flyBV.Parent = hrp

	flyBG = Instance.new("BodyGyro")
	flyBG.MaxTorque = Vector3.new(9e9, 9e9, 9e9)
	flyBG.CFrame = hrp.CFrame
	flyBG.Parent = hrp

	if humanoid then
		humanoid.PlatformStand = true
		local animate = hrp.Parent and hrp.Parent:FindFirstChild("Animate")
		if animate then pcall(function() animate.Disabled = true end) end
		for _, track in pairs(humanoid:GetPlayingAnimationTracks()) do
			pcall(function() track:AdjustSpeed(0) end)
		end
	end
end

local function disableFly()
	if flyBV then
		pcall(function() flyBV:Destroy() end)
		flyBV = nil
	end
	if flyBG then
		pcall(function() flyBG:Destroy() end)
		flyBG = nil
	end
	if humanoid then
		pcall(function() humanoid.PlatformStand = false end)
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
		local animate = hrp and hrp.Parent and hrp:FindFirstChild("Animate")
		if animate then pcall(function() animate.Disabled = false end) end
	end
end

local function setFlyEnabled(v)
	settings.flyEnabled = v and true or false
	if settings.flyEnabled then
		enableFly()
	else
		disableFly()
	end
end

--// Noclip runtime state <-- NEW SECTION
local noclipConnection = nil

local function setNoclipEnabled(enabled)
	settings.noclipEnabled = enabled
	if noclipConnection then
		noclipConnection:Disconnect()
		noclipConnection = nil
	end
	local char = LocalPlayer.Character
	if not char then return end

	if enabled then
		noclipConnection = RunService.Stepped:Connect(function()
			if not settings.noclipEnabled or not LocalPlayer.Character then
				if noclipConnection then
					noclipConnection:Disconnect()
					noclipConnection = nil
				end
				return
			end
			for _, part in ipairs(LocalPlayer.Character:GetDescendants()) do
				if part:IsA("BasePart") then
					part.CanCollide = false
				end
			end
		end)
	else
		for _, part in ipairs(char:GetDescendants()) do
			if part:IsA("BasePart") then
				part.CanCollide = true
			end
		end
	end
end

-- Character (re)binding
local function onCharacterAdded(char)
	hrp = char:FindFirstChild("HumanoidRootPart") or char:WaitForChild("HumanoidRootPart", 5)
	humanoid = char:FindFirstChildOfClass("Humanoid") or char:WaitForChild("Humanoid", 5)
	if humanoid then
		if not originalWalkSpeed then
			originalWalkSpeed = humanoid.WalkSpeed
		end
		humanoid.WalkSpeed = settings.walkSpeed
	end
	if settings.flyEnabled then
		disableFly()
		enableFly()
	else
		disableFly()
	end
	if settings.noclipEnabled then -- <-- NEW: Re-apply noclip on respawn
		setNoclipEnabled(true)
	end
	if humanoid then
		humanoid.Died:Connect(function()
			disableFly()
			if noclipConnection then -- <-- NEW: Clean up noclip on death
				noclipConnection:Disconnect()
				noclipConnection = nil
			end
		end)
	end
end

if LocalPlayer.Character then
	onCharacterAdded(LocalPlayer.Character)
end
LocalPlayer.CharacterAdded:Connect(onCharacterAdded)

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(char)
		task.wait(1) -- wait for parts to exist
	end)
end)

-- Also update respawns of existing players
for _, player in ipairs(Players:GetPlayers()) do
	player.CharacterAdded:Connect(function(char)
		task.wait(1)
	end)
end

--// Aimbot/ESP (fixed)
local function isAlive(hum)
	return hum and hum.Health and hum.MaxHealth and hum.Health > 0
end

local fovCircle = Drawing.new("Circle")
fovCircle.Color = Color3.fromRGB(255, 64, 64)
fovCircle.Thickness = 2
fovCircle.Filled = false
fovCircle.NumSides = 64
fovCircle.Radius = settings.aimRadius
fovCircle.Visible = settings.fovCircle
fovCircle.Position = Vector2.new(Camera.ViewportSize.X/2, Camera.ViewportSize.Y/2)
_G.AimESP_FOV_CIRCLE = fovCircle -- Store reference for cleanup

local function screenPoint(v3)
	local v2, on = Camera:WorldToViewportPoint(v3)
	return Vector2.new(v2.X, v2.Y), on, v2.Z
end

local function hasLineOfSight(model)
	local myChar = LocalPlayer.Character
	if not (myChar and model) then return false end
	local myHead = myChar:FindFirstChild("Head")
	local theirTargetPart = model:FindFirstChild(settings.aimPart) or model:FindFirstChild("Head")
	if not (myHead and theirTargetPart) then return false end
	
	local origin = myHead.Position
	local target = theirTargetPart.Position
	local direction = target - origin

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {myChar, model}

	return workspace:Raycast(origin, direction, params) == nil
end

local function isValidTarget(model)
	if not (model and model:IsA("Model")) then return false end
	local hum = model:FindFirstChildOfClass("Humanoid")
	if not isAlive(hum) then return false end

	local plr = Players:GetPlayerFromCharacter(model)
	if plr then
		if not settings.targetPlayers then return false end
		if not isEnemy(plr) then return false end
	else
		if not settings.targetNPCs then return false end
	end
	return true
end

local ESP = { cache = {} }
local function newLine()
	local ln = Drawing.new("Line")
	ln.Thickness = 2
	ln.Visible = false
	return ln
end
local function getCache(model)
	local c = ESP.cache[model]
	if c then return c end
	c = {
		box = Drawing.new("Square"),
		lines = {},
		healthBarBg = Drawing.new("Square"),
		healthBar = Drawing.new("Square"),
		infoText = Drawing.new("Text"),
	}
	c.box.Thickness = 2; c.box.Filled = false; c.box.Visible = false
	c.healthBarBg.Thickness = 1; c.healthBarBg.Filled = true; c.healthBarBg.Color = Color3.fromRGB(20,20,20); c.healthBarBg.Visible = false
	c.healthBar.Thickness = 0; c.healthBar.Filled = true; c.healthBar.Visible = false
	c.infoText.Size = 13; c.infoText.Center = true; c.infoText.Outline = true; c.infoText.Visible = false
	for i = 1, 24 do table.insert(c.lines, newLine()) end
	ESP.cache[model] = c
	return c
end
local function hideCache(model)
	local c = ESP.cache[model]
	if not c then return end
	if c.box then c.box.Visible = false end
	if c.healthBar then c.healthBar.Visible = false end
	if c.healthBarBg then c.healthBarBg.Visible = false end
	if c.infoText then c.infoText.Visible = false end
	for _, ln in ipairs(c.lines) do ln.Visible = false end
end
local function removeCache(model)
	local c = ESP.cache[model]
	if not c then return end
	if c.box then pcall(function() c.box:Remove() end) end
	if c.healthBar then pcall(function() c.healthBar:Remove() end) end
	if c.healthBarBg then pcall(function() c.healthBarBg:Remove() end) end
	if c.infoText then pcall(function() c.infoText:Remove() end) end
	for _, ln in ipairs(c.lines) do pcall(function() ln:Remove() end) end
	ESP.cache[model] = nil
end
local function getBoundPoints(model)
	local pts = {}
	local names = {
		"Head", "HumanoidRootPart", "UpperTorso", "LowerTorso", "Torso",
		"LeftUpperArm", "LeftLowerArm", "LeftHand", "RightUpperArm", "RightLowerArm", "RightHand",
		"LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "RightUpperLeg", "RightLowerLeg", "RightFoot",
		"Left Arm", "Right Arm", "Left Leg", "Right Leg"
	}
	for _, n in ipairs(names) do
		local p = model:FindFirstChild(n)
		if p and p:IsA("BasePart") then table.insert(pts, p.Position) end
	end
	if #pts == 0 then
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") then table.insert(pts, d.Position) end
		end
	end
	return pts
end
local function getBones(model)
	local b = {}
	local function gp(n) return model:FindFirstChild(n) end
	local head = gp("Head"); local ut, lt = gp("UpperTorso"), gp("LowerTorso"); local torso = gp("Torso"); local hrpLocal = gp("HumanoidRootPart")
	local LUA, LLA, LH = gp("LeftUpperArm"), gp("LeftLowerArm"), gp("LeftHand"); local RUA, RLA, RH = gp("RightUpperArm"), gp("RightLowerArm"), gp("RightHand")
	local LUL, LLL, LF = gp("LeftUpperLeg"), gp("LeftLowerLeg"), gp("LeftFoot"); local RUL, RLL, RF = gp("RightUpperLeg"), gp("RightLowerLeg"), gp("RightFoot")
	local LA, RA, LL, RL = gp("Left Arm"), gp("Right Arm"), gp("Left Leg"), gp("Right Leg")
	if ut and lt then
		if head then table.insert(b, {head, ut}) end; table.insert(b, {ut, lt})
		if LUA and LLA then table.insert(b, {ut, LUA}); table.insert(b, {LUA, LLA}); if LH then table.insert(b, {LLA, LH}) end end
		if RUA and RLA then table.insert(b, {ut, RUA}); table.insert(b, {RUA, RLA}); if RH then table.insert(b, {RLA, RH}) end end
		if LUL and LLL then table.insert(b, {lt, LUL}); table.insert(b, {LUL, LLL}); if LF then table.insert(b, {LLL, LF}) end end
		if RUL and RLL then table.insert(b, {lt, RUL}); table.insert(b, {RUL, RLL}); if RF then table.insert(b, {RLL, RF}) end end
	else
		local t = torso or hrpLocal; if head and t then table.insert(b, {head, t}) end
		if LA and t then table.insert(b, {t, LA}) end; if RA and t then table.insert(b, {t, RA}) end
		if LL and t then table.insert(b, {t, LL}) end; if RL and t then table.insert(b, {t, RL}) end
	end
	return b
end

local function updateESP(model)
	local hum = model:FindFirstChildOfClass("Humanoid")
	if not isAlive(hum) or not settings.espEnabled then hideCache(model) return end
	local cache = getCache(model)
	local isVisible = hasLineOfSight(model)
	local espColor = isVisible and settings.espVisibleColor or settings.espOccludedColor
	cache.box.Color = espColor; cache.infoText.Color = espColor; for _, ln in ipairs(cache.lines) do ln.Color = espColor end
	local pts = getBoundPoints(model)
	local anyOn = false; local minX, minY = math.huge, math.huge; local maxX, maxY = -math.huge, -math.huge
	for _, wp in ipairs(pts) do
		local sp, on = screenPoint(wp)
		if on then anyOn = true; minX = math.min(minX, sp.X); minY = math.min(minY, sp.Y); maxX = math.max(maxX, sp.X); maxY = math.max(maxY, sp.Y) end
	end
	if anyOn then
		if settings.boxESP then cache.box.Visible = true; cache.box.Position = Vector2.new(minX, minY); cache.box.Size = Vector2.new(math.max(2, maxX - minX), math.max(2, maxY - minY)) else cache.box.Visible = false end
		if settings.healthBar then
			local boxHeight = math.max(2, maxY - minY); local healthPercent = hum.Health / hum.MaxHealth
			cache.healthBarBg.Visible = true; cache.healthBar.Visible = true; cache.healthBarBg.Position = Vector2.new(minX - 6, minY); cache.healthBarBg.Size = Vector2.new(4, boxHeight)
			cache.healthBar.Position = Vector2.new(minX - 6, minY + (boxHeight * (1 - healthPercent))); cache.healthBar.Size = Vector2.new(4, boxHeight * healthPercent); cache.healthBar.Color = Color3.fromHSV(0.33 * healthPercent, 1, 1)
		else cache.healthBarBg.Visible = false; cache.healthBar.Visible = false end
		if settings.infoESP then
			local player = Players:GetPlayerFromCharacter(model); local name = player and player.DisplayName or model.Name; local dist = (hrp.Position - model.HumanoidRootPart.Position).Magnitude
			cache.infoText.Visible = true; cache.infoText.Text = string.format("%s [%.0fm]", name, dist); cache.infoText.Position = Vector2.new(minX + (maxX - minX) / 2, minY - 15)
		else cache.infoText.Visible = false end
	else hideCache(model) end
	local used = 0
	if settings.skelESP and anyOn then
		for _, pair in ipairs(getBones(model)) do
			local a, b = pair[1], pair[2]
			if a and b and a:IsA("BasePart") and b:IsA("BasePart") then
				local a2, aon = screenPoint(a.Position); local b2, bon = screenPoint(b.Position)
				if aon and bon then used = used + 1; local ln = cache.lines[used] or newLine(); cache.lines[used] = ln; ln.From = a2; ln.To = b2; ln.Visible = true end
			end
		end
	end
	for i = used + 1, #cache.lines do cache.lines[i].Visible = false end
end

workspace.ChildRemoved:Connect(function(child) if ESP.cache[child] then removeCache(child) end end)

local function getClosestTarget()
	local best, bestDist = nil, settings.aimRadius
	local center = Vector2.new(Camera.ViewportSize.X/2, Camera.ViewportSize.Y/2)
	for _, m in ipairs(workspace:GetChildren()) do
		if m:IsA("Model") and m ~= LocalPlayer.Character and isValidTarget(m) then
			local targetPart = m:FindFirstChild(settings.aimPart) or m:FindFirstChild("Head")
			if targetPart and hasLineOfSight(m) then
				local sp, on = screenPoint(targetPart.Position)
				if on then local d = (Vector2.new(sp.X, sp.Y) - center).Magnitude; if d <= bestDist then bestDist = d; best = m end end
			end
			updateESP(m)
		else if ESP.cache[m] then hideCache(m) end end
	end
	return best
end

local function aimAt(model)
	local targetPart = model and (model:FindFirstChild(settings.aimPart) or model:FindFirstChild("Head"))
	if not targetPart then return end
	local desired = CFrame.new(Camera.CFrame.Position, targetPart.Position)
	local s = tonumber(settings.smoothness) or 1
	if s >= 1 then Camera.CFrame = desired else Camera.CFrame = Camera.CFrame:Lerp(desired, math.clamp(s, 0.05, 0.99)) end
end

local guiElements = {}
--// --- FIXED: Consolidated Input Handling ---
UIS.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if listeningForKeybind then
		settings.keybinds[listeningForKeybind.Name] = input.KeyCode
		listeningForKeybind.Text = tostring(input.KeyCode.Name)
		listeningForKeybind = nil
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton2 then holdingRMB = true end
	
	--// --- Keybind Logic ---
	if input.KeyCode == settings.keybinds.toggleFly then
		setFlyEnabled(not settings.flyEnabled)
		if guiElements.flyEnabled and guiElements.flyEnabled.Update then
			guiElements.flyEnabled.Update() -- Update visual state of the button
		end
	end
	if input.KeyCode == settings.keybinds.toggleGUI then
		if _G.__AimESP_MainFrame then
			_G.__AimESP_MainFrame.Visible = not _G.__AimESP_MainFrame.Visible
		end
	end
end)
UIS.InputEnded:Connect(function(input) if input.UserInputType == Enum.UserInputType.MouseButton2 then holdingRMB = false end end)

--// Render loop
local rsConn
rsConn = RunService.RenderStepped:Connect(function(delta)
	fovCircle.Visible = settings.fovCircle; fovCircle.Radius = settings.aimRadius; fovCircle.Position = Vector2.new(Camera.ViewportSize.X/2, Camera.ViewportSize.Y/2)
	targetModel = getClosestTarget()
	if settings.camlock and holdingRMB and targetModel then aimAt(targetModel) end
	if settings.flyEnabled and flyBV and flyBG and hrp then
		local dir = Vector3.new(); local cam = workspace.CurrentCamera
		if UIS:IsKeyDown(Enum.KeyCode.W) then dir = dir + cam.CFrame.LookVector end
		if UIS:IsKeyDown(Enum.KeyCode.S) then dir = dir - cam.CFrame.LookVector end
		if UIS:IsKeyDown(Enum.KeyCode.A) then dir = dir - cam.CFrame.RightVector end
		if UIS:IsKeyDown(Enum.KeyCode.D) then dir = dir + cam.CFrame.RightVector end
		if UIS:IsKeyDown(Enum.KeyCode.Space) then dir = dir + Vector3.new(0,1,0) end
		if UIS:IsKeyDown(Enum.KeyCode.LeftControl) then dir = dir - Vector3.new(0,1,0) end
		if dir.Magnitude > 0 then flyBV.Velocity = dir.Unit * settings.flySpeed else flyBV.Velocity = Vector3.new(0,0,0) end
		flyBG.CFrame = CFrame.new(hrp.Position, hrp.Position + cam.CFrame.LookVector)
	end
end)
_G.AimESP_RS_CONN = rsConn -- Store reference for cleanup

--// GUI creation
local sg = Instance.new("ScreenGui"); sg.Name = "AimESP_UI"; sg.ResetOnSpawn = false; sg.IgnoreGuiInset = true; sg.ZIndexBehavior = Enum.ZIndexBehavior.Global
local function safeParentGui(gui) local ok, cg = pcall(function() return game:GetService("CoreGui") end); if ok and cg then gui.Parent = cg else gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui") end end
safeParentGui(sg)

local main = Instance.new("Frame"); main.Name = "Main"; main.Size = UDim2.new(0, 570, 0, 645); main.Position = UDim2.new(0.06, 0, 0.22, 0)
main.BackgroundColor3 = Color3.fromRGB(18, 18, 20); main.BorderSizePixel = 0; main.Active = false; main.Draggable = false; main.Parent = sg
_G.__AimESP_MainFrame = main

local uiCorner = Instance.new("UICorner", main); uiCorner.CornerRadius = UDim.new(0, 12)
local uiStroke = Instance.new("UIStroke", main); uiStroke.Thickness = 2; uiStroke.Color = Color3.fromRGB(60,60,60)

local titleBar = Instance.new("Frame"); titleBar.Size = UDim2.new(1, 0, 0, 38); titleBar.BackgroundColor3 = Color3.fromRGB(28, 28, 32); titleBar.BorderSizePixel = 0; titleBar.Parent = main
local tbCorner = Instance.new("UICorner", titleBar); tbCorner.CornerRadius = UDim.new(0, 12)

--// --- DRAGGING LOGIC ---
local dragging = false
local dragStart = Vector2.new(0,0)
local startPos = UDim2.new(0,0,0,0)
titleBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = main.Position
    end
end)
titleBar.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = false
    end
end)
UIS.InputChanged:Connect(function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - dragStart
        main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
    end
end)

local title = Instance.new("TextLabel"); title.BackgroundTransparency = 1; title.Position = UDim2.new(0, 12, 0, 0); title.Size = UDim2.new(1, -200, 1, 0)
title.Text = "AldoAim 2.5"; title.TextXAlignment = Enum.TextXAlignment.Left; title.TextColor3 = Color3.fromRGB(255, 255, 255); title.Font = Enum.Font.GothamBold; title.TextSize = 12; title.Parent = titleBar

local function topBtn(txt, xOff, isIcon)
	local b = Instance.new("TextButton"); b.Size = isIcon and UDim2.new(0, 28, 0, 28) or UDim2.new(0, 65, 0, 28); b.Position = UDim2.new(0, xOff, 0, 5); b.Text = txt
	b.BackgroundColor3 = Color3.fromRGB(38,38,42); b.TextColor3 = Color3.fromRGB(255,255,255); b.Font = isIcon and Enum.Font.SourceSansBold or Enum.Font.GothamBold; b.TextSize = isIcon and 20 or 14; b.Parent = titleBar
	local c = Instance.new("UICorner", b); c.CornerRadius = UDim.new(0, 6); local s = Instance.new("UIStroke", b); s.Thickness = 1; s.Color = Color3.fromRGB(70,70,72)
	return b
end

local tabAimbotBtn = topBtn("Aimbot", 150)
local tabESPBtn = topBtn("ESP", 220)
local tabMiscBtn = topBtn("Misc", 290)
local tabSettingsBtn = topBtn("⚙", 360, true)

local btnClose = Instance.new("TextButton"); btnClose.Name = "Close"; btnClose.Size = UDim2.new(0, 28, 0, 28); btnClose.Position = UDim2.new(1, -34, 0, 5)
btnClose.Text = "X"; btnClose.BackgroundColor3 = Color3.fromRGB(55,35,35); btnClose.TextColor3 = Color3.fromRGB(255,120,120); btnClose.Font = Enum.Font.GothamBold; btnClose.TextSize = 16; btnClose.Parent = titleBar
Instance.new("UICorner", btnClose).CornerRadius = UDim.new(0, 6)

local pages = Instance.new("Frame"); pages.Position = UDim2.new(0, 12, 0, 50); pages.Size = UDim2.new(1, -24, 1, -62); pages.BackgroundColor3 = Color3.fromRGB(24, 24, 28); pages.BorderSizePixel = 0; pages.Parent = main
Instance.new("UICorner", pages).CornerRadius = UDim.new(0, 10)

local pageAim = Instance.new("Frame", pages); local pageESP = Instance.new("Frame", pages); local pageMisc = Instance.new("Frame", pages); local pageSettings = Instance.new("Frame", pages)
local allPages = { aim = pageAim, esp = pageESP, misc = pageMisc, settings = pageSettings }
for _, page in pairs(allPages) do page.Size = UDim2.new(1, 0, 1, 0); page.BackgroundTransparency = 1; page.Visible = false end
pageAim.Visible = true
local function showPage(pageName) for name, page in pairs(allPages) do page.Visible = (name == pageName) end end
tabAimbotBtn.MouseButton1Click:Connect(function() showPage("aim") end); tabESPBtn.MouseButton1Click:Connect(function() showPage("esp") end); tabMiscBtn.MouseButton1Click:Connect(function() showPage("misc") end); tabSettingsBtn.MouseButton1Click:Connect(function() showPage("settings") end)

local hint = Instance.new("TextLabel"); hint.BackgroundTransparency = 1; hint.Position = UDim2.new(0, 12, 1, -22); hint.Size = UDim2.new(1, -24, 0, 16)
hint.Font = Enum.Font.Gotham; hint.TextSize = 12; hint.TextXAlignment = Enum.TextXAlignment.Left; hint.TextColor3 = Color3.fromRGB(200,200,205); hint.Text = "dont steal this pls"; hint.Parent = main

btnClose.MouseButton1Click:Connect(function()
	if rsConn then rsConn:Disconnect() end
	setNoclipEnabled(false)
	if LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid") and originalWalkSpeed then LocalPlayer.Character.Humanoid.WalkSpeed = originalWalkSpeed end
	for m,_ in pairs(ESP.cache) do removeCache(m) end
	pcall(function() fovCircle:Remove() end); sg:Destroy()
end)

--// --- MODIFIED MK-TOGGLE ---
local function mkToggle(parent, label, getVal, setVal, y)
	local btn = Instance.new("TextButton"); btn.Size = UDim2.new(1, -24, 0, 34); btn.Position = UDim2.new(0, 12, 0, y); btn.Text = ""; btn.BackgroundColor3 = Color3.fromRGB(34,34,38); btn.Parent = parent
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8); local st = Instance.new("UIStroke", btn); st.Thickness = 1; st.Color = Color3.fromRGB(70,70,74)
	
	local lbl = Instance.new("TextLabel"); lbl.BackgroundTransparency = 1; lbl.Size = UDim2.new(1, -12, 1, 0); lbl.Position = UDim2.new(0, 12, 0, 0); lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Text = label; lbl.TextColor3 = Color3.fromRGB(255,255,255); lbl.Font = Enum.Font.Gotham; lbl.TextSize = 14; lbl.Parent = btn

	local statusCircle = Instance.new("Frame"); statusCircle.Size = UDim2.new(0, 14, 0, 14); statusCircle.Position = UDim2.new(1, -25, 0.5, -7); statusCircle.BorderSizePixel = 0; statusCircle.Parent = btn
	Instance.new("UICorner", statusCircle).CornerRadius = UDim.new(1, 0)
	Instance.new("UIStroke", statusCircle).Color = Color3.fromRGB(18,18,20)

	local function updateVisuals()
		local value = getVal()
		if type(value) == "boolean" then
			statusCircle.Visible = true
			if value then
				statusCircle.BackgroundColor3 = Color3.fromRGB(40, 160, 80) -- Green for True
			else
				statusCircle.BackgroundColor3 = Color3.fromRGB(80, 80, 80) -- Dark Gray for False
			end
			lbl.Text = label -- Keep label simple for boolean toggles
		else
			statusCircle.Visible = false -- Hide circle for non-boolean toggles like Aim Part
			lbl.Text = string.format("%s: %s", label, tostring(value))
		end
	end

	btn.MouseButton1Click:Connect(function()
		local currentValue = getVal()
		if type(currentValue) == "boolean" then
			setVal(not currentValue)
			updateVisuals()
		end
	end)
	
	updateVisuals() -- Set initial state
	return {Button = btn, Label = lbl, Update = updateVisuals}
end


--// --- MODIFIED MK-SLIDER ---
local function mkSlider(parent, label, minV, maxV, step, getV, setV, y)
	local lbl = Instance.new("TextLabel"); lbl.BackgroundTransparency = 1; lbl.Position = UDim2.new(0, 12, 0, y); lbl.Size = UDim2.new(1, -24, 0, 20); lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Text = label.. ": ".. tostring(getV()); lbl.TextColor3 = Color3.fromRGB(255,255,255); lbl.Font = Enum.Font.Gotham; lbl.TextSize = 14; lbl.Parent = parent
	local bar = Instance.new("Frame"); bar.Position = UDim2.new(0, 12, 0, y + 24); bar.Size = UDim2.new(1, -24, 0, 12); bar.BackgroundColor3 = Color3.fromRGB(18, 18, 20); bar.BorderSizePixel = 0; bar.Parent = parent
	Instance.new("UICorner", bar).CornerRadius = UDim.new(0, 6)
	local barStroke = Instance.new("UIStroke", bar); barStroke.Thickness = 1; barStroke.Color = Color3.fromRGB(80,80,80)
	local fill = Instance.new("Frame"); fill.BackgroundColor3 = Color3.fromRGB(255, 255, 255); fill.BorderSizePixel = 0; fill.Size = UDim2.new((getV()-minV)/(maxV - minV), 0, 1, 0); fill.Parent = bar
	Instance.new("UICorner", fill).CornerRadius = UDim.new(0, 6)
	local dragging = false
	local function setFromMouse(x)
		local rel = math.clamp((x - bar.AbsolutePosition.X)/bar.AbsoluteSize.X, 0, 1); local raw = minV + (maxV - minV) * rel
		local stepped = (step >= 1 and math.floor(raw/step+0.5)*step) or (math.floor(raw/step+0.5)*step); stepped = math.clamp(stepped, minV, maxV)
		setV(stepped); lbl.Text = label.. ": ".. tostring(stepped); fill.Size = UDim2.new((stepped-minV)/(maxV - minV), 0, 1, 0)
	end
	bar.InputBegan:Connect(function(i) if i.UserInputType == Enum.UserInputType.MouseButton1 then dragging = true; setFromMouse(i.Position.X) end end)
	UIS.InputChanged:Connect(function(i) if dragging and i.UserInputType == Enum.UserInputType.MouseMovement then setFromMouse(i.Position.X) end end)
	UIS.InputEnded:Connect(function(i) if i.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end end)
	return {Label = lbl, Fill = fill, Min = minV, Max = maxV}
end

--// --- Populate Aimbot Page ---
guiElements.camlock = mkToggle(pageAim, "Aimbot (hold RMB)", function() return settings.camlock end, function(v) settings.camlock = v end, 8)
guiElements.fovCircle = mkToggle(pageAim, "Show FOV Circle", function() return settings.fovCircle end, function(v) settings.fovCircle = v end, 50)
guiElements.aimRadius = mkSlider(pageAim, "FOV Radius", 50, 600, 1, function() return settings.aimRadius end, function(v) settings.aimRadius = v end, 92)
guiElements.smoothness = mkSlider(pageAim, "Smoothness (1 = snap)", 0.05, 1.00, 0.01, function() return tonumber(string.format("%.2f", settings.smoothness)) end, function(v) settings.smoothness = tonumber(string.format("%.2f", v)) end, 152)
local aimParts = {"Head", "UpperTorso", "HumanoidRootPart"}; local currentAimPartIdx = table.find(aimParts, settings.aimPart) or 1
guiElements.aimPart = mkToggle(pageAim, "Aim Part", function() return settings.aimPart end, function() end, 212)
guiElements.aimPart.Button.MouseButton1Click:Connect(function() currentAimPartIdx = (currentAimPartIdx % #aimParts) + 1; settings.aimPart = aimParts[currentAimPartIdx]; guiElements.aimPart.Update() end)

--// --- Populate ESP Page ---
guiElements.espEnabled = mkToggle(pageESP, "ESP Enabled", function() return settings.espEnabled end, function(v) settings.espEnabled = v end, 8)
guiElements.boxESP = mkToggle(pageESP, "Box ESP", function() return settings.boxESP end, function(v) settings.boxESP = v end, 50)
guiElements.skelESP = mkToggle(pageESP, "Skeleton ESP", function() return settings.skelESP end, function(v) settings.skelESP = v end, 92)
guiElements.healthBar = mkToggle(pageESP, "Health Bar", function() return settings.healthBar end, function(v) settings.healthBar = v end, 134)
guiElements.infoESP = mkToggle(pageESP, "Info (Name/Dist)", function() return settings.infoESP end, function(v) settings.infoESP = v end, 176)
guiElements.targetNPCs = mkToggle(pageESP, "Include NPCs/Dummies", function() return settings.targetNPCs end, function(v) settings.targetNPCs = v end, 218)
guiElements.targetPlayers = mkToggle(pageESP, "Include Players", function() return settings.targetPlayers end, function(v) settings.targetPlayers = v end, 260)

--// --- Populate Misc Page ---
guiElements.flyEnabled = mkToggle(pageMisc, "Fly Enabled", function() return settings.flyEnabled end, setFlyEnabled, 8)
guiElements.noclipEnabled = mkToggle(pageMisc, "Noclip (Walk through walls)", function() return settings.noclipEnabled end, setNoclipEnabled, 50)
guiElements.walkSpeed = mkSlider(pageMisc, "Walk Speed", 16, 100, 1, function() return settings.walkSpeed end, function(v) settings.walkSpeed = v; if LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid") then LocalPlayer.Character.Humanoid.WalkSpeed = v end end, 92)
guiElements.flySpeed = mkSlider(pageMisc, "Fly Speed", 10, 200, 5, function() return settings.flySpeed end, function(v) settings.flySpeed = v end, 152)

--// --- Populate Settings Page ---
local function mkButton(parent, text, y, x, w)
	local btn = Instance.new("TextButton"); btn.Size = UDim2.new(0, w, 0, 34); btn.Position = UDim2.new(0, x, 0, y); btn.Text = text
	btn.BackgroundColor3 = Color3.fromRGB(34,34,38); btn.TextColor3 = Color3.fromRGB(255,255,255); btn.Font = Enum.Font.Gotham; btn.TextSize = 14; btn.Parent = parent
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8); local st = Instance.new("UIStroke", btn); st.Thickness = 1; st.Color = Color3.fromRGB(70,70,74)
	return btn
end

local configTextBox = Instance.new("TextBox"); configTextBox.Size = UDim2.new(1, -24, 0, 60); configTextBox.Position = UDim2.new(0, 12, 0, 8)
configTextBox.BackgroundColor3 = Color3.fromRGB(34,34,38); configTextBox.TextColor3 = Color3.fromRGB(220,220,220); configTextBox.Font = Enum.Font.Code; configTextBox.TextSize = 14
configTextBox.ClearTextOnFocus = false; configTextBox.PlaceholderText = "Paste config string here..."; configTextBox.TextXAlignment = Enum.TextXAlignment.Left; configTextBox.TextYAlignment = Enum.TextYAlignment.Top; configTextBox.MultiLine = true; configTextBox.Parent = pageSettings
Instance.new("UICorner", configTextBox).CornerRadius = UDim.new(0, 8); local tbStroke = Instance.new("UIStroke", configTextBox); tbStroke.Thickness = 1; tbStroke.Color = Color3.fromRGB(70,70,74)

local saveBtn = mkButton(pageSettings, "Copy Config to Clipboard", 76, 12, 260)
local loadBtn = mkButton(pageSettings, "Load Config from Textbox", 76, 282, 260)

local function mkKeybind(parent, name, label, y)
	local lbl = Instance.new("TextLabel", parent); lbl.BackgroundTransparency = 1; lbl.Position = UDim2.new(0, 12, 0, y); lbl.Size = UDim2.new(0, 250, 0, 34)
	lbl.Text = label; lbl.Font = Enum.Font.Gotham; lbl.TextSize = 14; lbl.TextColor3 = Color3.fromRGB(255,255,255); lbl.TextXAlignment = Enum.TextXAlignment.Left
	local btn = mkButton(parent, tostring(settings.keybinds[name].Name), y, 282, 260); btn.Name = name
	btn.MouseButton1Click:Connect(function() if listeningForKeybind then listeningForKeybind.Text = tostring(settings.keybinds[listeningForKeybind.Name].Name) end; listeningForKeybind = btn; btn.Text = "..." end)
	return btn
end

guiElements.toggleGUIKeybind = mkKeybind(pageSettings, "toggleGUI", "Toggle GUI", 120)
guiElements.toggleFlyKeybind = mkKeybind(pageSettings, "toggleFly", "Toggle Fly", 162)

--// --- FIXED: Config System Logic ---
local function updateGUIFromSettings()
	for name, element in pairs(guiElements) do
		if element.Update then -- For toggles
			element.Update()
		end
		if element.Label and element.Fill then -- For sliders
			local value = settings[name]
			if value ~= nil then
				element.Label.Text = element.Label.Text:match("(.+):") .. " " .. tostring(value)
				element.Fill.Size = UDim2.new((value - element.Min) / (element.Max - element.Min), 0, 1, 0)
			end
		end
	end
	guiElements.toggleGUIKeybind.Text = settings.keybinds.toggleGUI.Name
	guiElements.toggleFlyKeybind.Text = settings.keybinds.toggleFly.Name
end


saveBtn.MouseButton1Click:Connect(function()
	if setclipboard then
		local success, err = pcall(function() setclipboard(HttpService:JSONEncode(settings)) end)
		if success then hint.Text = "Config copied to clipboard!" else hint.Text = "Error copying config." end
	else hint.Text = "setclipboard is not available." end
	task.wait(2); hint.Text = "dont steal this pls"
end)

loadBtn.MouseButton1Click:Connect(function()
	local content = configTextBox.Text
	if content and #content > 0 then
		local decodedSuccess, decoded = pcall(HttpService.JSONDecode, HttpService, content)
		if decodedSuccess and decoded then
			for k, v in pairs(decoded) do
				if k == "keybinds" then for key, val in pairs(v) do settings.keybinds[key] = Enum.KeyCode[val.Name] end
				elseif string.find(k, "Color") then settings[k] = Color3.new(v.r, v.g, v.b)
				else settings[k] = v end
			end
			hint.Text = "Config loaded successfully!"
			updateGUIFromSettings()
		else hint.Text = "Invalid config string in textbox." end
	else hint.Text = "Textbox is empty." end
	task.wait(2); hint.Text = "dont steal this pls"
end)
