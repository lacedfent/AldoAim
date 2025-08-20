--// Services
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local Camera = workspace.CurrentCamera
local LocalPlayer = Players.LocalPlayer

--// SETTINGS (live-updated by GUI)
local settings = {
    -- Aimbot
    camlock = true,
    fovCircle = true,
    aimRadius = 150,   -- px
    smoothness = 1.00,  -- 1.00 = snap

    -- Fly
    flyEnabled = false,
    flySpeed = 50,

    -- ESP
    espEnabled = true,
    boxESP = true,
    skelESP = true,

    -- Targeting
    targetNPCs = true,  -- include NPCs/dummies
    targetPlayers = true,  -- include players
}

local holdingRMB = false
local targetModel = nil

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

-- Character (re)binding
local function onCharacterAdded(char)
    hrp = char:FindFirstChild("HumanoidRootPart") or char:WaitForChild("HumanoidRootPart", 5)
    humanoid = char:FindFirstChildOfClass("Humanoid") or char:WaitForChild("Humanoid", 5)
    if settings.flyEnabled then
        disableFly()
        enableFly()
    else
        disableFly()
    end
    if humanoid then
        humanoid.Died:Connect(function()
            disableFly()
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
        updateHitbox(char)
    end)
end)

-- Also update respawns of existing players
for _, player in ipairs(Players:GetPlayers()) do
    player.CharacterAdded:Connect(function(char)
        task.wait(1)
        updateHitbox(char)
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

local function screenPoint(v3)
    local v2, on = Camera:WorldToViewportPoint(v3)
    return Vector2.new(v2.X, v2.Y), on, v2.Z
end

local function hasLineOfSight(model)
    local myChar = LocalPlayer.Character
    if not (myChar and model) then return false end
    local myHead = myChar:FindFirstChild("Head")
    local theirHead = model:FindFirstChild("Head")
    if not (myHead and theirHead) then return false end
    local origin = myHead.Position
    local target = theirHead.Position
    local dir = (target - origin)
    local ray = Ray.new(origin, dir.Unit * dir.Magnitude)
    local hit = workspace:FindPartOnRayWithIgnoreList(ray, {myChar, model})
    return hit == nil
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

local function updateHitbox(char)
    if not char or not char:IsA("Model") then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then return end
    local multiplier = settings.hitboxEnabled and settings.hitboxScale or 1
    for _, part in ipairs(char:GetChildren()) do
        if part:IsA("BasePart") then
            -- Store original size if not stored
            if not part:FindFirstChild("_OriginalSize") then
                local os = Instance.new("Vector3Value")
                os.Name = "_OriginalSize"
                os.Value = part.Size
                os.Parent = part
            end
            part.Size = part:FindFirstChild("_OriginalSize").Value * multiplier
        end
    end
end

function updateAllHitboxes()
    for _, char in ipairs(workspace:GetChildren()) do
        if char:IsA("Model") and char ~= LocalPlayer.Character then
            updateHitbox(char)
        end
    end
end

local ESP = { cache = {} } -- [model] = {box=Square, lines={Line...}}
local function newLine()
    local ln = Drawing.new("Line")
    ln.Thickness = 2
    ln.Color = Color3.fromRGB(0, 255, 180)
    ln.Visible = false
    return ln
end
local function getCache(model)
    local c = ESP.cache[model]
    if c then return c end
    c = {
        box = Drawing.new("Square"),
        lines = {}
    }
    c.box.Thickness = 2
    c.box.Filled = false
    c.box.Color = Color3.fromRGB(255, 255, 255)
    c.box.Visible = false
    for i = 1, 24 do table.insert(c.lines, newLine()) end -- pool for skeleton
    ESP.cache[model] = c
    return c
end
local function hideCache(model)
    local c = ESP.cache[model]
    if not c then return end
    if c.box then c.box.Visible = false end
    for _, ln in ipairs(c.lines) do ln.Visible = false end
end
local function removeCache(model)
    local c = ESP.cache[model]
    if not c then return end
    if c.box then pcall(function() c.box:Remove() end) end
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
    local head = gp("Head")
    local ut, lt = gp("UpperTorso"), gp("LowerTorso")
    local torso = gp("Torso")
    local hrpLocal = gp("HumanoidRootPart")

    local LUA, LLA, LH = gp("LeftUpperArm"), gp("LeftLowerArm"), gp("LeftHand")
    local RUA, RLA, RH = gp("RightUpperArm"), gp("RightLowerArm"), gp("RightHand")
    local LUL, LLL, LF = gp("LeftUpperLeg"), gp("LeftLowerLeg"), gp("LeftFoot")
    local RUL, RLL, RF = gp("RightUpperLeg"), gp("RightLowerLeg"), gp("RightFoot")

    local LA, RA, LL, RL = gp("Left Arm"), gp("Right Arm"), gp("Left Leg"), gp("Right Leg")

    if ut and lt then
        if head then table.insert(b, {head, ut}) end
        table.insert(b, {ut, lt})
        if LUA and LLA then table.insert(b, {ut, LUA}); table.insert(b, {LUA, LLA}); if LH then table.insert(b, {LLA, LH}) end end
        if RUA and RLA then table.insert(b, {ut, RUA}); table.insert(b, {RUA, RLA}); if RH then table.insert(b, {RLA, RH}) end end
        if LUL and LLL then table.insert(b, {lt, LUL}); table.insert(b, {LUL, LLL}); if LF then table.insert(b, {LLL, LF}) end end
        if RUL and RLL then table.insert(b, {lt, RUL}); table.insert(b, {RUL, RLL}); if RF then table.insert(b, {RLL, RF}) end end
    else
        local t = torso or hrpLocal
        if head and t then table.insert(b, {head, t}) end
        if LA and t then table.insert(b, {t, LA}) end
        if RA and t then table.insert(b, {t, RA}) end
        if LL and t then table.insert(b, {t, LL}) end
        if RL and t then table.insert(b, {t, RL}) end
    end
    return b
end
local function updateESP(model)
    local hum = model:FindFirstChildOfClass("Humanoid")
    if not isAlive(hum) or not settings.espEnabled then hideCache(model) return end

    local cache = getCache(model)

    if settings.boxESP then
        local pts = getBoundPoints(model)
        local anyOn = false
        local minX, minY = math.huge, math.huge
        local maxX, maxY = -math.huge, -math.huge
        for _, wp in ipairs(pts) do
            local sp, on = screenPoint(wp)
            if on then
                anyOn = true
                minX = math.min(minX, sp.X)
                minY = math.min(minY, sp.Y)
                maxX = math.max(maxX, sp.X)
                maxY = math.max(maxY, sp.Y)
            end
        end
        if anyOn then
            cache.box.Visible = true
            cache.box.Position = Vector2.new(minX, minY)
            cache.box.Size = Vector2.new(math.max(2, maxX - minX), math.max(2, maxY - minY))
            cache.box.Color = Color3.fromRGB(255, 255, 255)
        else
            cache.box.Visible = false
        end
    else
        cache.box.Visible = false
    end

    local used = 0
    if settings.skelESP then
        for _, pair in ipairs(getBones(model)) do
            local a, b = pair[1], pair[2]
            if a and b and a:IsA("BasePart") and b:IsA("BasePart") then
                local a2, aon = screenPoint(a.Position)
                local b2, bon = screenPoint(b.Position)
                if aon and bon then
                    used = used + 1
                    local ln = cache.lines[used] or newLine()
                    cache.lines[used] = ln
                    ln.From = a2
                    ln.To = b2
                    ln.Visible = true
                    ln.Color = Color3.fromRGB(0, 255, 180)
                end
            end
        end
    end
    for i = used + 1, #cache.lines do
        cache.lines[i].Visible = false
    end
end

workspace.ChildRemoved:Connect(function(child)
    if ESP.cache[child] then removeCache(child) end
end)

local function getClosestTarget()
    local best, bestDist = nil, settings.aimRadius
    local center = Vector2.new(Camera.ViewportSize.X/2, Camera.ViewportSize.Y/2)
    for _, m in ipairs(workspace:GetChildren()) do
        if m:IsA("Model") and m ~= LocalPlayer.Character and isValidTarget(m) then
            local head = m:FindFirstChild("Head")
            if head and hasLineOfSight(m) then
                local sp, on = screenPoint(head.Position)
                if on then
                    local d = (Vector2.new(sp.X, sp.Y) - center).Magnitude
                    if d <= bestDist then
                        bestDist = d
                        best = m
                    end
                end
            end
            updateESP(m)
        else
            if ESP.cache[m] then hideCache(m) end
        end
    end
    return best
end

local function aimAt(model)
    if not (model and model:FindFirstChild("Head")) then return end
    local desired = CFrame.new(Camera.CFrame.Position, model.Head.Position)
    local s = tonumber(settings.smoothness) or 1
    if s >= 1 then
        Camera.CFrame = desired
    else
        Camera.CFrame = Camera.CFrame:Lerp(desired, math.clamp(s, 0.05, 0.99))
    end
end

--// Input (RMB for camlock + N for fly toggle)
UIS.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.UserInputType == Enum.UserInputType.MouseButton2 then
        holdingRMB = true
    end
    if input.KeyCode == Enum.KeyCode.N then
        setFlyEnabled(not settings.flyEnabled)
    elseif input.KeyCode == Enum.KeyCode.RightControl then
        if _G.__AimESP_MainFrame then
            _G.__AimESP_MainFrame.Visible = not _G.__AimESP_MainFrame.Visible
        end
    end
end)
UIS.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton2 then
        holdingRMB = false
    end
end)

--// Render loop (aim + fly BV update)
local rsConn
rsConn = RunService.RenderStepped:Connect(function(delta)
    fovCircle.Visible = settings.fovCircle
    fovCircle.Radius = settings.aimRadius
    fovCircle.Position = Vector2.new(Camera.ViewportSize.X/2, Camera.ViewportSize.Y/2)

    targetModel = getClosestTarget()
    if settings.camlock and holdingRMB and targetModel then
        aimAt(targetModel)
    end

    if settings.flyEnabled and flyBV and flyBG and hrp then
        local dir = Vector3.new()
        local cam = workspace.CurrentCamera
        if UIS:IsKeyDown(Enum.KeyCode.W) then dir = dir + cam.CFrame.LookVector end
        if UIS:IsKeyDown(Enum.KeyCode.S) then dir = dir - cam.CFrame.LookVector end
        if UIS:IsKeyDown(Enum.KeyCode.A) then dir = dir - cam.CFrame.RightVector end
        if UIS:IsKeyDown(Enum.KeyCode.D) then dir = dir + cam.CFrame.RightVector end
        if UIS:IsKeyDown(Enum.KeyCode.Space) then dir = dir + Vector3.new(0,1,0) end
        if UIS:IsKeyDown(Enum.KeyCode.LeftControl) then dir = dir - Vector3.new(0,1,0) end

        if dir.Magnitude > 0 then
            flyBV.Velocity = dir.Unit * settings.flySpeed
        else
            flyBV.Velocity = Vector3.new(0,0,0)
        end
        flyBG.CFrame = CFrame.new(hrp.Position, hrp.Position + cam.CFrame.LookVector)
    end
end)

--// GUI creation (kept layout; I only hook the fly toggle/slider)
local sg = Instance.new("ScreenGui")
sg.Name = "AimESP_UI"
sg.ResetOnSpawn = false
sg.IgnoreGuiInset = true
sg.ZIndexBehavior = Enum.ZIndexBehavior.Global
local function safeParentGui(gui)
    local ok, cg = pcall(function() return game:GetService("CoreGui") end)
    if ok and cg then gui.Parent = cg else gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui") end
end
safeParentGui(sg)

local main = Instance.new("Frame")
main.Name = "Main"
main.Size = UDim2.new(0, 380, 0, 430)
main.Position = UDim2.new(0.06, 0, 0.22, 0)
main.BackgroundColor3 = Color3.fromRGB(18, 18, 20)
main.BorderSizePixel = 0
main.Active = true
main.Draggable = true
main.Parent = sg
_G.__AimESP_MainFrame = main
local originalSize = main.Size

local uiCorner = Instance.new("UICorner", main) uiCorner.CornerRadius = UDim.new(0, 12)
local uiStroke = Instance.new("UIStroke", main) uiStroke.Thickness = 2 uiStroke.Color = Color3.fromRGB(60,60,60)

local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, 38)
titleBar.BackgroundColor3 = Color3.fromRGB(28, 28, 32)
titleBar.BorderSizePixel = 0
titleBar.Parent = main
local tbCorner = Instance.new("UICorner", titleBar) tbCorner.CornerRadius = UDim.new(0, 12)

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.new(0, 12, 0, 0)
title.Size = UDim2.new(1, -110, 1, 0)
title.Text = "AldoAim 2.5"
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.fromRGB(255, 255, 255)
title.Font = Enum.Font.GothamBold
title.TextSize = 12
title.Parent = titleBar

local function topBtn(txt, xOff)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, 70, 0, 28)
    b.Position = UDim2.new(0, xOff, 0, 5)
    b.Text = txt
    b.BackgroundColor3 = Color3.fromRGB(38,38,42)
    b.TextColor3 = Color3.fromRGB(255,255,255)
    b.Font = Enum.Font.GothamBold
    b.TextSize = 14
    b.Parent = titleBar
    local c = Instance.new("UICorner", b) c.CornerRadius = UDim.new(0, 6)
    local s = Instance.new("UIStroke", b) s.Thickness = 1 s.Color = Color3.fromRGB(70,70,72)
    return b
end

local tabAimbotBtn = topBtn("Aimbot", 90)
local tabESPBtn = topBtn("ESP", 165)
local tabMiscBtn = topBtn("Misc", 240)

local btnMinimize = Instance.new("TextButton")
btnMinimize.Name = "Minimize"
btnMinimize.Size = UDim2.new(0, 28, 0, 28)
btnMinimize.Position = UDim2.new(1, -66, 0, 5)
btnMinimize.Text = "—"
btnMinimize.BackgroundColor3 = Color3.fromRGB(45,45,50)
btnMinimize.TextColor3 = Color3.fromRGB(255,255,255)
btnMinimize.Font = Enum.Font.GothamBold
btnMinimize.TextSize = 18
btnMinimize.Parent = titleBar
Instance.new("UICorner", btnMinimize).CornerRadius = UDim.new(0, 6)

local btnMaximize = Instance.new("TextButton")
btnMaximize.Name = "Maximize"
btnMaximize.Size = UDim2.new(0, 28, 0, 28)
btnMaximize.Position = UDim2.new(1, -66, 0, 5)
btnMaximize.Text = "+"
btnMaximize.BackgroundColor3 = Color3.fromRGB(45,45,50)
btnMaximize.TextColor3 = Color3.fromRGB(255,255,255)
btnMaximize.Font = Enum.Font.GothamBold
btnMaximize.TextSize = 18
btnMaximize.Parent = titleBar
btnMaximize.Visible = false
Instance.new("UICorner", btnMaximize).CornerRadius = UDim.new(0, 6)

local btnClose = Instance.new("TextButton")
btnClose.Name = "Close"
btnClose.Size = UDim2.new(0, 28, 0, 28)
btnClose.Position = UDim2.new(1, -34, 0, 5)
btnClose.Text = "X"
btnClose.BackgroundColor3 = Color3.fromRGB(55,35,35)
btnClose.TextColor3 = Color3.fromRGB(255,120,120)
btnClose.Font = Enum.Font.GothamBold
btnClose.TextSize = 16
btnClose.Parent = titleBar
Instance.new("UICorner", btnClose).CornerRadius = UDim.new(0, 6)

local isMinimized = false
local pages = Instance.new("Frame")
pages.Position = UDim2.new(0, 12, 0, 50)
pages.Size = UDim2.new(1, -24, 1, -62)
pages.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
pages.BorderSizePixel = 0
pages.Parent = main
Instance.new("UICorner", pages).CornerRadius = UDim.new(0, 10)

local pageAim = Instance.new("Frame", pages)
pageAim.Size = UDim2.new(1, 0, 1, 0)
pageAim.BackgroundTransparency = 1

local pageESP = Instance.new("Frame", pages)
pageESP.Size = UDim2.new(1, 0, 1, 0)
pageESP.BackgroundTransparency = 1
pageESP.Visible = false

local pageMisc = Instance.new("Frame", pages)
pageMisc.Size = UDim2.new(1, 0, 1, 0)
pageMisc.BackgroundTransparency = 1
pageMisc.Visible = false

local hint = Instance.new("TextLabel")
hint.BackgroundTransparency = 1
hint.Position = UDim2.new(0, 12, 1, -22)
hint.Size = UDim2.new(1, -24, 0, 16)
hint.Font = Enum.Font.Gotham
hint.TextSize = 12
hint.TextXAlignment = Enum.TextXAlignment.Left
hint.TextColor3 = Color3.fromRGB(200,200,205)
hint.Text = "dont steal this pls"
hint.Parent = main

local function setPagesVisible(visible)
    pages.Visible = visible
    hint.Visible = visible
end

btnMinimize.MouseButton1Click:Connect(function()
    if not isMinimized then
        setPagesVisible(false)
        main:TweenSize(UDim2.new(main.Size.X.Scale, main.Size.X.Offset, 0, 38), "Out", "Quad", 0.3)
        wait(0.3)
        btnMinimize.Visible = false
        btnMaximize.Visible = true
        isMinimized = true
    end
end)

btnMaximize.MouseButton1Click:Connect(function()
    if isMinimized then
        main:TweenSize(originalSize, "Out", "Quad", 0.3)
        wait(0.3)
        btnMaximize.Visible = false
        btnMinimize.Visible = true
        setPagesVisible(true)
        isMinimized = false
    end
end)

btnClose.MouseButton1Click:Connect(function()
    if rsConn then rsConn:Disconnect() end
    for m,_ in pairs(ESP.cache) do removeCache(m) end
    pcall(function() fovCircle:Remove() end)
    sg:Destroy()
end)

UIS.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.RightControl then
        main.Visible = not main.Visible
    elseif input.KeyCode == Enum.KeyCode.RightShift then
        if isMinimized then
            btnMaximize.MouseButton1Click:Fire()
        else
            btnMinimize.MouseButton1Click:Fire()
        end
    end
end)

settings.hitboxEnabled = false
settings.hitboxScale = 2
local function showPage(which)
    pageAim.Visible = (which == "aim")
    pageESP.Visible = (which == "esp")
    pageMisc.Visible = (which == "misc")
end
tabAimbotBtn.MouseButton1Click:Connect(function() showPage("aim") end)
tabESPBtn.MouseButton1Click:Connect(function() showPage("esp") end)
tabMiscBtn.MouseButton1Click:Connect(function() showPage("misc") end)

local function mkToggle(parent, label, getVal, setVal, y)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, -24, 0, 34)
    btn.Position = UDim2.new(0, 12, 0, y)
    btn.Text = ""
    btn.BackgroundColor3 = Color3.fromRGB(34,34,38)
    btn.Parent = parent
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)
    local st = Instance.new("UIStroke", btn) st.Thickness = 1 st.Color = Color3.fromRGB(70,70,74)

    local lbl = Instance.new("TextLabel")
    lbl.BackgroundTransparency = 1
    lbl.Size = UDim2.new(1, -12, 1, 0)
    lbl.Position = UDim2.new(0, 12, 0, 0)
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Text = string.format("%s: %s", label, tostring(getVal()))
    lbl.TextColor3 = Color3.fromRGB(255,255,255)
    lbl.Font = Enum.Font.Gotham
    lbl.TextSize = 14
    lbl.Parent = btn

    btn.MouseButton1Click:Connect(function()
        local new = not getVal()
        setVal(new)
        lbl.Text = string.format("%s: %s", label, tostring(getVal()))
    end)
    return btn
end

local function mkSlider(parent, label, minV, maxV, step, getV, setV, y)
    local lbl = Instance.new("TextLabel")
    lbl.BackgroundTransparency = 1
    lbl.Position = UDim2.new(0, 12, 0, y)
    lbl.Size = UDim2.new(1, -24, 0, 20)
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Text = label .. ": " .. tostring(getV())
    lbl.TextColor3 = Color3.fromRGB(255,255,255)
    lbl.Font = Enum.Font.Gotham
    lbl.TextSize = 14
    lbl.Parent = parent

    local bar = Instance.new("Frame")
    bar.Position = UDim2.new(0, 12, 0, y + 24)
    bar.Size = UDim2.new(1, -24, 0, 12)
    bar.BackgroundColor3 = Color3.fromRGB(36,36,40)
    bar.BorderSizePixel = 0
    bar.Parent = parent
    Instance.new("UICorner", bar).CornerRadius = UDim.new(0, 6)

    local fill = Instance.new("Frame")
    fill.BackgroundColor3 = Color3.fromRGB(255, 70, 70)
    fill.BorderSizePixel = 0
    fill.Size = UDim2.new((getV()-minV)/(maxV - minV), 0, 1, 0)
    fill.Parent = bar
    Instance.new("UICorner", fill).CornerRadius = UDim.new(0, 6)

    local dragging = false
    local function setFromMouse(x)
        local rel = math.clamp((x - bar.AbsolutePosition.X)/bar.AbsoluteSize.X, 0, 1)
        local raw = minV + (maxV - minV) * rel
        local stepped = (step >= 1 and math.floor(raw/step+0.5)*step) or (math.floor(raw/step+0.5)*step)
        stepped = math.clamp(stepped, minV, maxV)
        setV(stepped)
        lbl.Text = label .. ": " .. tostring(stepped)
        fill.Size = UDim2.new((stepped-minV)/(maxV - minV), 0, 1, 0)
    end

    bar.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            setFromMouse(i.Position.X)
        end
    end)
    UIS.InputChanged:Connect(function(i)
        if dragging and i.UserInputType == Enum.UserInputType.MouseMovement then
            setFromMouse(i.Position.X)
        end
    end)
    UIS.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = false
        end
    end)
end

mkToggle(pageAim, "Aimbot (hold RMB)", function() return settings.camlock end, function(v) settings.camlock = v end, 8)
mkToggle(pageAim, "Show FOV Circle", function() return settings.fovCircle end, function(v) settings.fovCircle = v end, 50)
mkSlider(pageAim, "FOV Radius", 50, 600, 1,
    function() return settings.aimRadius end,
    function(v) settings.aimRadius = v end,
    94
)
mkSlider(pageAim, "Smoothness (1 = snap)", 0.05, 1.00, 0.01,
    function() return tonumber(string.format("%.2f", settings.smoothness)) end,
    function(v) settings.smoothness = tonumber(string.format("%.2f", v)) end,
    154
)

mkToggle(pageESP, "ESP Enabled", function() return settings.espEnabled end, function(v) settings.espEnabled = v end, 8)
mkToggle(pageESP, "Box ESP", function() return settings.boxESP end, function(v) settings.boxESP = v end, 50)
mkToggle(pageESP, "Skeleton ESP", function() return settings.skelESP end, function(v) settings.skelESP = v end, 92)
mkToggle(pageESP, "Include NPCs/Dummies", function() return settings.targetNPCs end, function(v) settings.targetNPCs = v end, 134)
mkToggle(pageESP, "Include Players", function() return settings.targetPlayers end, function(v) settings.targetPlayers = v end, 176)
mkToggle(pageMisc, "Hitbox Expander", 
    function() return settings.hitboxEnabled end, 
    function(v)
        settings.hitboxEnabled = v
        updateAllHitboxes()
    end, 
    8
)
