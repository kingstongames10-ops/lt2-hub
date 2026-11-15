local TreeModule = {}

-- ==========================================
--             SYSTEM SETTINGS
-- ==========================================
local Settings = {
    SyncDelay       = 0.1,
    ReadyDelay      = 0.1,

    -- [ Cut Settings ]
    FiresPerSection = 100,
    FireDelay       = 0.01,
    SweepDelay      = 0.1,

    -- [ LOT Settings ]
    LogDropDistance = 6,

    -- [ Sell Location ]
    SellPosition    = Vector3.new(315, 0, 88),

    -- [ Death Handling ]
    RespawnResumeDelay = 1,   -- seconds to wait after respawn before resuming
}

-- ==========================================
--             CORE SERVICES & VARS
-- ==========================================
local Players           = game:GetService("Players")
local Workspace         = game:GetService("Workspace")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

local isChopping          = false
local preChopCFrame       = nil
local preChopCameraCFrame = nil
local preChopLogModels    = {}

-- ==========================================
--   SILENCE TROLL SOUNDS
-- ==========================================
local function SilenceRegionAlternates()
    local function killAlternate(parent)
        for _, child in ipairs(parent:GetChildren()) do
            if child.Name == "Alternate" and child:IsA("Sound") then
                child.Volume = 0
                pcall(function() child:Stop() end)
            end
        end
        parent.ChildAdded:Connect(function(child)
            if child.Name == "Alternate" and child:IsA("Sound") then
                child.Volume = 0
                pcall(function() child:Stop() end)
            end
        end)
    end

    local function scanClientSounds()
        local pg     = player:WaitForChild("PlayerGui", 10)
        local sounds = pg and pg:FindFirstChild("ClientSounds")
        if not sounds then return end

        local function processRegion(folder)
            killAlternate(folder)
        end

        local function scanAll()
            for _, child in ipairs(sounds:GetChildren()) do
                if child.Name == "Region_Main" or child.Name == "Region_Mountain" then
                    processRegion(child)
                end
            end
        end

        scanAll()

        sounds.ChildAdded:Connect(function(child)
            if child.Name == "Region_Main" or child.Name == "Region_Mountain" then
                processRegion(child)
            end
        end)
    end

    task.spawn(scanClientSounds)
end

SilenceRegionAlternates()

-- ==========================================
--             UTILITY
-- ==========================================

local function ReadAxeName(tool)
    if not tool then return nil end
    local tipChild = tool:FindFirstChild("ToolTip")
    return (tipChild and tipChild:IsA("StringValue")) and tipChild.Value or tool.ToolTip
end

local function GetBackpackAxe(treeClass)
    local candidates = {}

    local function TryAdd(tool)
        if not tool:IsA("Tool") then return end
        if tool.Name == "BlueprintTool" then return end

        local axeName = ReadAxeName(tool)
        if not axeName then return end

        local score = treeClass
            and _G.LT2Axes.GetDamage(axeName, treeClass)
            or (1 / (_G.LT2Axes.Rank[axeName] or 2^53))

        table.insert(candidates, { tool = tool, axeName = axeName, score = score })
    end

    local char = player.Character
    if char then
        local equipped = char:FindFirstChildOfClass("Tool")
        if equipped then TryAdd(equipped) end
    end
    for _, tool in ipairs(player.Backpack:GetChildren()) do
        TryAdd(tool)
    end

    if #candidates == 0 then return nil, nil end

    table.sort(candidates, function(a, b) return a.score > b.score end)

    local best = candidates[1]
    return best.tool, best.axeName
end

local function FindPriorityTree(treeClass)
    local bestModel   = nil
    local maxSections = -1
    for _, folder in ipairs(Workspace:GetChildren()) do
        if folder.Name:lower():match("treeregion") then
            for _, model in ipairs(folder:GetChildren()) do
                if model:IsA("Model")
                and model:FindFirstChild("TreeClass")
                and model.TreeClass.Value == treeClass then
                    local count = 0
                    for _, part in ipairs(model:GetChildren()) do
                        if part.Name == "WoodSection" then count += 1 end
                    end
                    if treeClass == "Generic" and count < 12 then continue end
                    if count > maxSections then
                        maxSections = count
                        bestModel   = model
                    end
                end
            end
        end
    end
    return bestModel
end

local function GetSectionsBottomFirst(treeModel)
    local sections = {}
    for _, part in ipairs(treeModel:GetChildren()) do
        if part.Name == "WoodSection" then
            table.insert(sections, part)
        end
    end
    table.sort(sections, function(a, b)
        return a.Position.Y < b.Position.Y
    end)
    return sections
end

local function SnapshotLogModels()
    preChopLogModels = {}
    local logModels = Workspace:FindFirstChild("LogModels")
    if not logModels then return end
    for _, model in ipairs(logModels:GetChildren()) do
        preChopLogModels[model] = true
    end
end

-- ==========================================
--   OWNERSHIP CHECK
-- ==========================================
local function IsOwnedByLocalPlayer(model)
    local ownerObj = model:FindFirstChild("Owner")
    if ownerObj then
        if ownerObj:IsA("ObjectValue") and ownerObj.Value == player then return true end
        if ownerObj:IsA("StringValue") and ownerObj.Value == player.Name then return true end
    end
    local ownerStr = model:FindFirstChild("OwnerString")
    if ownerStr and ownerStr:IsA("StringValue") and ownerStr.Value == player.Name then
        return true
    end
    return false
end

local function CountWoodSections(model)
    local count = 0
    for _, desc in ipairs(model:GetDescendants()) do
        if desc:IsA("BasePart") and desc.Name == "WoodSection" then
            count += 1
        end
    end
    return count
end

local function CountTreeSections(model)
    local count = 0
    for _, part in ipairs(model:GetChildren()) do
        if part.Name == "WoodSection" then count += 1 end
    end
    return count
end

local function ScanForTreeTypes()
    local found, seen = {}, {}
    for _, folder in ipairs(Workspace:GetChildren()) do
        if folder.Name:lower():match("treeregion") then
            for _, model in ipairs(folder:GetChildren()) do
                if model:IsA("Model") then
                    local tc = model:FindFirstChild("TreeClass")
                    if tc and tc:IsA("StringValue") and not seen[tc.Value] then
                        if CountTreeSections(model) > 1 then
                            seen[tc.Value] = true
                            table.insert(found, tc.Value)
                        end
                    end
                end
            end
        end
    end
    return #found > 0 and found or {"None Found"}
end

local function CollectNewStumps(treeClass)
    local results   = {}
    local logModels = Workspace:FindFirstChild("LogModels")
    if not logModels then return results end
    for _, model in ipairs(logModels:GetChildren()) do
        if preChopLogModels[model] then continue end
        if model:IsA("Model") then
            local tc = model:FindFirstChild("TreeClass")
            if tc and tc.Value == treeClass then
                local iw = model:FindFirstChild("InnerWood")
                if iw and iw:IsA("BasePart") then
                    table.insert(results, iw)
                end
            end
        end
    end
    if #results == 0 then
        warn("[TreeModule] No InnerWood found after chop for TreeClass:", treeClass)
    end
    return results
end

local function CollectAllOwnedStumps()
    local results   = {}
    local logModels = Workspace:FindFirstChild("LogModels")
    if not logModels then return results end
    for _, model in ipairs(logModels:GetChildren()) do
        if not model:IsA("Model") then continue end
        if not IsOwnedByLocalPlayer(model) then continue end
        local iw = model:FindFirstChild("InnerWood")
        if iw and iw:IsA("BasePart") then
            table.insert(results, iw)
        end
    end
    if #results == 0 then
        warn("[TreeModule] No owned InnerWood found.")
    end
    return results
end

local function CollectSingleSectionStumps()
    local results   = {}
    local logModels = Workspace:FindFirstChild("LogModels")
    if not logModels then return results end
    for _, model in ipairs(logModels:GetChildren()) do
        if not model:IsA("Model") then continue end
        if not IsOwnedByLocalPlayer(model) then continue end
        if CountWoodSections(model) ~= 1 then continue end
        local iw = model:FindFirstChild("InnerWood")
        if iw and iw:IsA("BasePart") then
            table.insert(results, iw)
        end
    end
    if #results == 0 then
        warn("[TreeModule] No single-section logs ready to sell. Chop logs into sections first.")
    end
    return results
end

local function SellLogModelSectionBySection(model, LOT, sellPos, sectionIndex)
    sectionIndex = sectionIndex or 0

    local sections = {}
    for _, part in ipairs(model:GetDescendants()) do
        if part:IsA("BasePart") and part.Name == "WoodSection" then
            table.insert(sections, part)
        end
    end
    table.sort(sections, function(a, b) return a.Position.Y < b.Position.Y end)

    if #sections == 0 then
        warn("[TreeModule] No WoodSections found in model:", model.Name)
        return sectionIndex
    end

    for _, section in ipairs(sections) do
        if not section or not section.Parent then continue end

        for _, desc in ipairs(model:GetDescendants()) do
            if desc:IsA("Weld") or desc:IsA("WeldConstraint") or desc:IsA("ManualWeld") then
                if desc.Part0 == section or desc.Part1 == section then
                    pcall(function() desc:Destroy() end)
                end
            end
        end

        task.wait(0.1)

        sectionIndex += 1
        local cf = CFrame.new(sellPos.X + ((sectionIndex - 1) * 3), sellPos.Y, sellPos.Z)
        if LOT.IsBusy() then repeat task.wait(0.05) until not LOT.IsBusy() end
        LOT.TeleportObjectTo(section, cf)
        repeat task.wait(0.05) until not LOT.IsBusy()
    end

    return sectionIndex
end

local function SellAllOwnedTreesSectionBySection(LOT, sellPos, onComplete)
    task.spawn(function()
        local logModels = Workspace:FindFirstChild("LogModels")
        if not logModels then
            if onComplete then onComplete() end
            return
        end

        local ownedModels = {}
        for _, model in ipairs(logModels:GetChildren()) do
            if model:IsA("Model") and IsOwnedByLocalPlayer(model) then
                table.insert(ownedModels, model)
            end
        end

        if #ownedModels == 0 then
            warn("[TreeModule] No owned log models found.")
            if onComplete then onComplete() end
            return
        end

        print(("[TreeModule] Selling %d log model(s) section by section."):format(#ownedModels))

        local globalIndex = 0
        for _, model in ipairs(ownedModels) do
            if not model or not model.Parent then continue end
            globalIndex = SellLogModelSectionBySection(model, LOT, sellPos, globalIndex)
        end

        if onComplete then onComplete() end
    end)
end

local function CleanupState()
    isChopping = false

    local char = player.Character
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")

    if hrp and preChopCFrame then
        hrp.CFrame = preChopCFrame
        hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
    end

    player.CameraMode = Enum.CameraMode.Classic

    if preChopCameraCFrame then
        camera.CFrame = preChopCameraCFrame
    end
end

local function WaitForLogsToSettle(treeClass)
    local VELOCITY_THRESHOLD = 0.5
    local STABLE_DURATION    = 0.3
    local TIMEOUT            = 10
    local POLL_RATE          = 0.05

    local logModels = Workspace:FindFirstChild("LogModels")
    if not logModels then task.wait(1.5) return end

    local innerWoods = {}
    for _, model in ipairs(logModels:GetChildren()) do
        if preChopLogModels[model] then continue end
        if model:IsA("Model") then
            local tc = model:FindFirstChild("TreeClass")
            if tc and tc.Value == treeClass then
                local iw = model:FindFirstChild("InnerWood")
                if iw and iw:IsA("BasePart") then
                    table.insert(innerWoods, iw)
                end
            end
        end
    end

    if #innerWoods == 0 then task.wait(1.5) return end

    local deadline   = tick() + TIMEOUT
    local stableFrom = nil

    while tick() < deadline do
        local allStill = true
        for _, iw in ipairs(innerWoods) do
            if not iw or not iw.Parent then continue end
            if iw.AssemblyLinearVelocity.Magnitude > VELOCITY_THRESHOLD then
                allStill = false
                break
            end
        end
        if allStill then
            if not stableFrom then
                stableFrom = tick()
            elseif tick() - stableFrom >= STABLE_DURATION then
                return
            end
        else
            stableFrom = nil
        end
        task.wait(POLL_RATE)
    end
    warn("[TreeModule] WaitForLogsToSettle timed out — proceeding anyway.")
end

-- ==========================================
--   LOT BATCH HELPER
-- ==========================================
local function RunLOTBatch(LOT, stumps, goalCFBuilder, onComplete)
    if not LOT then if onComplete then onComplete() end return end
    if #stumps == 0 then
        warn("[TreeModule] RunLOTBatch: nothing to teleport.")
        if onComplete then onComplete() end
        return
    end

    task.spawn(function()
        for i, stump in ipairs(stumps) do
            if LOT.IsBusy() then
                repeat task.wait(0.1) until not LOT.IsBusy()
            end
            local goalCF = goalCFBuilder(i, stump)
            LOT.TeleportObjectTo(stump, goalCF, true)
            task.spawn(function()
                repeat task.wait(0.1) until not LOT.IsBusy()
            end)
        end
        if onComplete then onComplete() end
    end)
end

-- ==========================================
--   PLANK SELLING
-- ==========================================
local PLANK_SELL_CF = CFrame.new(315, 0, 88) * CFrame.Angles(math.rad(90), 0, 0)
local PLANK_LOCK_TIME = 1
local _sellPlanksOn = false
local _hoverOutline = nil
local _hoverPlank   = nil
local _plankConn    = nil
local _clickConn    = nil
local _isSelling    = false

local function FindOwnedPlank(part)
    if not part then return nil end
    local current = part
    while current and current ~= Workspace do
        if current.Name == "Plank" and current:IsA("Model") then
            local playerModels = Workspace:FindFirstChild("PlayerModels")
            if not playerModels then return nil end
            if current.Parent ~= playerModels then return nil end
            local owner = current:FindFirstChild("Owner")
            if not owner then return nil end
            local ownerStr = owner:FindFirstChild("OwnerString")
            if not ownerStr or not ownerStr:IsA("StringValue") then return nil end
            if ownerStr.Value ~= player.Name then return nil end
            return current
        end
        current = current.Parent
    end
    return nil
end

local function ClearHoverOutline()
    if _hoverOutline then _hoverOutline:Destroy(); _hoverOutline = nil end
    _hoverPlank = nil
end

local function ApplyHoverOutline(model)
    if _hoverPlank == model then return end
    ClearHoverOutline()
    _hoverPlank                       = model
    _hoverOutline                     = Instance.new("SelectionBox")
    _hoverOutline.Adornee             = model
    _hoverOutline.Color3              = Color3.fromRGB(74, 120, 255)
    _hoverOutline.LineThickness       = 0.08
    _hoverOutline.SurfaceColor3       = Color3.fromRGB(74, 120, 255)
    _hoverOutline.SurfaceTransparency = 0.65
    _hoverOutline.Parent              = Workspace
end

local function StopSellPlanks()
    _sellPlanksOn = false
    _isSelling    = false
    ClearHoverOutline()
    if _plankConn then _plankConn:Disconnect(); _plankConn = nil end
    if _clickConn then _clickConn:Disconnect(); _clickConn = nil end
end

local function StartSellPlanks(LOT)
    if not LOT then warn("[TreeModule] LOT not available for Sell Planks.") return end

    _sellPlanksOn = true
    _isSelling    = false
    local mouse   = player:GetMouse()

    _plankConn = RunService.RenderStepped:Connect(function()
        if not _sellPlanksOn then return end
        if _isSelling then ClearHoverOutline() return end
        local plank = FindOwnedPlank(mouse.Target)
        if plank then ApplyHoverOutline(plank) else ClearHoverOutline() end
    end)

    _clickConn = mouse.Button1Down:Connect(function()
        if not _sellPlanksOn or _isSelling then return end
        if not _hoverPlank or not _hoverPlank.Parent then return end

        local plank = _hoverPlank
        ClearHoverOutline()
        _isSelling = true

        task.spawn(function()
            if LOT.IsBusy() then repeat task.wait(0.05) until not LOT.IsBusy() end

            local target = plank.PrimaryPart
            if not target then
                for _, v in ipairs(plank:GetDescendants()) do
                    if v:IsA("BasePart") then target = v; break end
                end
            end

            if not target then
                warn("[TreeModule] Plank has no BasePart to teleport.")
                _isSelling = false
                return
            end

            LOT.TeleportObjectTo(target, PLANK_SELL_CF)
            repeat task.wait(0.05) until not LOT.IsBusy()

            -- hold the plank pinned at the sell spot so the sale registers
            local lockDeadline = tick() + PLANK_LOCK_TIME
            while tick() < lockDeadline and target and target.Parent do
                target.CFrame = PLANK_SELL_CF
                target.AssemblyLinearVelocity  = Vector3.new(0, 0, 0)
                target.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
                RunService.Heartbeat:Wait()
            end

            _isSelling = false
        end)
    end)
end

-- ==========================================
--   REMOTE CUT
-- ==========================================
local RemoteProxy = ReplicatedStorage:WaitForChild("Interaction"):WaitForChild("RemoteProxy")
local NPCDialogRemote = ReplicatedStorage:WaitForChild("NPCDialog"):WaitForChild("PlayerChatted")
local NPCPromptChat   = ReplicatedStorage:WaitForChild("NPCDialog"):WaitForChild("PromptChat")

local function CutHeightFrac(sizeY)
    return math.clamp(0.1 + (8 - sizeY) / 60, 0.1, 0.2)
end

local function FireCutSection(section, tool, axeName, treeClass, stopFn)
    if not section or not section.Parent then return end

    local idObj = section:FindFirstChild("ID")
    if not idObj then return end

    local cutEvent = section:FindFirstChild("CutEvent")
                  or section.Parent:FindFirstChild("CutEvent")
                  or (section.Parent.Parent and section.Parent.Parent:FindFirstChild("CutEvent"))
    if not cutEvent then return end

    local damage = _G.LT2Axes.GetDamage(axeName, treeClass)
    local height = section.Size.Y * CutHeightFrac(section.Size.Y)

    local args = {
        sectionId    = idObj.Value,
        faceVector   = Vector3.new(0, 0, -1),
        height       = height,
        hitPoints    = damage,
        cooldown     = 0,
        cuttingClass = "Axe",
        tool         = tool,
    }

    for _ = 1, Settings.FiresPerSection do
        if not section.Parent then break end
        if stopFn and stopFn() then break end
        RemoteProxy:FireServer(cutEvent, args)
        task.wait(Settings.FireDelay)
    end
end

local function FireCutAtHeight(section, tool, axeName, treeClass, height)
    if not section or not section.Parent then return end
    local idObj = section:FindFirstChild("ID")
    if not idObj then return end

    local cutEvent = section:FindFirstChild("CutEvent")
                  or section.Parent:FindFirstChild("CutEvent")
                  or (section.Parent.Parent and section.Parent.Parent:FindFirstChild("CutEvent"))

    if not cutEvent then
        warn("[TreeModule] CutEvent not found for section:", section:GetFullName())
        for _, c in ipairs(section.Parent:GetChildren()) do
            print("  parent child:", c.Name, c.ClassName)
        end
        return
    end

    local damage = _G.LT2Axes.GetDamage(axeName, treeClass)
    local args = {
        sectionId    = idObj.Value,
        faceVector   = Vector3.new(0, 0, -1),
        height       = height,
        hitPoints    = damage,
        cooldown     = 0,
        cuttingClass = "Axe",
        tool         = tool,
    }

    for _ = 1, Settings.FiresPerSection do
        if not section.Parent then break end
        RemoteProxy:FireServer(cutEvent, args)
        task.wait(Settings.FireDelay)
    end
end

-- ==========================================
--   CHOP LOGS INTO INDIVIDUAL SECTIONS
-- ==========================================
local _chopLogsActive = false
local function ChopLogsIntoSections(onComplete)
    local logModels = Workspace:FindFirstChild("LogModels")
    if not logModels then
        warn("[TreeModule] No LogModels folder.")
        if onComplete then onComplete() end
        return
    end

    local ownedModels = {}
    for _, model in ipairs(logModels:GetChildren()) do
        if model:IsA("Model") and IsOwnedByLocalPlayer(model) then
            table.insert(ownedModels, model)
        end
    end

    if #ownedModels == 0 then
        warn("[TreeModule] No owned log models to chop.")
        if onComplete then onComplete() end
        return
    end

    local function SnapshotModels()
        local snap = {}
        for _, m in ipairs(logModels:GetChildren()) do snap[m] = true end
        return snap
    end

    local function SectionCount(model)
        local count = 0
        for _, desc in ipairs(model:GetDescendants()) do
            if desc:IsA("BasePart") and desc.Name == "WoodSection" then
                count += 1
            end
        end
        return count
    end

    local function BuildConnectionMap(model)
        local map = {}
        for _, desc in ipairs(model:GetDescendants()) do
            if (desc:IsA("Weld") or desc:IsA("ManualWeld")) and desc.Name == "Tree Weld" then
                local p0, p1 = desc.Part0, desc.Part1
                if p0 and p1 and p0.Name == "WoodSection" and p1.Name == "WoodSection" then
                    map[p0] = (map[p0] or 0) + 1
                    map[p1] = (map[p1] or 0) + 1
                end
            end
        end
        return map
    end

    local function FindStump(model)
        local iw = model:FindFirstChild("InnerWood", true)
        if not iw then return nil end
        for _, desc in ipairs(model:GetDescendants()) do
            if (desc:IsA("Weld") or desc:IsA("ManualWeld")) then
                local p0, p1 = desc.Part0, desc.Part1
                if p0 == iw and p1 and p1.Name == "WoodSection" then return p1 end
                if p1 == iw and p0 and p0.Name == "WoodSection" then return p0 end
            end
        end
        return nil
    end

    local function FindTipWeld(model, tip)
        for _, desc in ipairs(model:GetDescendants()) do
            if (desc:IsA("Weld") or desc:IsA("ManualWeld")) and desc.Name == "Tree Weld" then
                local p0, p1 = desc.Part0, desc.Part1
                if p0 == tip and p1 and p1.Name == "WoodSection" then return desc, p1 end
                if p1 == tip and p0 and p0.Name == "WoodSection" then return desc, p0 end
            end
        end
        return nil
    end

    task.spawn(function()
        _chopLogsActive = true
        local queue = {}
        for _, m in ipairs(ownedModels) do
            table.insert(queue, m)
        end

        while #queue > 0 do
            if not _chopLogsActive then break end
            local model = table.remove(queue, 1)
            if not model or not model.Parent then continue end

            local tc        = model:FindFirstChild("TreeClass")
            local treeClass = tc and tc.Value or "Generic"
            local tool, axeName = GetBackpackAxe(treeClass)
            local stump     = FindStump(model)

            if not tool then
                warn("[TreeModule] No axe found for model:", model.Name, "— skipping.")
                continue
            end

            while model and model.Parent and SectionCount(model) > 1 do
                if not _chopLogsActive then break end
                local connMap = BuildConnectionMap(model)

                local tip = nil
                for section, count in pairs(connMap) do
                    if count == 1 and section ~= stump and section.Parent then
                        tip = section
                        break
                    end
                end

                if not tip then break end

                local weld, parent = FindTipWeld(model, tip)
                if not weld or not parent then break end

                local cutSection    = parent:FindFirstChild("ID") and parent or tip
                local jointWorldPos = (weld.Part0.CFrame * weld.C0).Position
                local localY        = (cutSection.CFrame:Inverse() * CFrame.new(jointWorldPos)).Position.Y
                local height        = math.clamp(localY + cutSection.Size.Y / 2, 0.05, cutSection.Size.Y - 0.05)

                local char = player.Character
                local hrp  = char and char:FindFirstChild("HumanoidRootPart")
                if hrp then
                    hrp.CFrame = CFrame.new(jointWorldPos + cutSection.CFrame.RightVector * 4)
                    hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
                    task.wait(0.1)
                end

                local before = SnapshotModels()

                FireCutAtHeight(cutSection, tool, axeName, treeClass, height)

                task.wait(0.1)

                for _, m in ipairs(logModels:GetChildren()) do
                    if not before[m] and m:IsA("Model") and IsOwnedByLocalPlayer(m) then
                        if SectionCount(m) > 1 then
                            table.insert(queue, m)
                        end
                    end
                end
            end
        end

        _chopLogsActive = false
        print("[TreeModule] Done chopping logs into sections.")
        if onComplete then onComplete() end
    end)
end

-- ==========================================
--   BRIDGE TOLL (LoneCave only)
-- ==========================================
local _bridgeNPCID       = nil
local _bridgeLastPaid    = 0
local BRIDGE_PAID_WINDOW = 120

local function BridgeSafeInvoke(npcArg, action)
    local co   = coroutine.running()
    local done = false
    local thread = task.spawn(function()
        pcall(function() NPCDialogRemote:InvokeServer(npcArg, action) end)
        if not done then done = true; task.spawn(co) end
    end)
    task.delay(7, function()
        if not done then done = true; pcall(task.cancel, thread); task.spawn(co) end
    end)
    coroutine.yield()
end

local function PayBridgeToll()
    local seranok = Workspace:FindFirstChild("Bridge")
        and Workspace.Bridge:FindFirstChild("TollBooth0")
        and Workspace.Bridge.TollBooth0:FindFirstChild("Seranok")

    if not seranok then
        warn("[TreeModule] Seranok not found — cannot lower bridge.")
        return
    end

    local char = player.Character
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end

    local npcRoot = seranok:FindFirstChild("HumanoidRootPart")
    hrp.CFrame = npcRoot
        and CFrame.new(npcRoot.Position + Vector3.new(3, 0, 0))
        or seranok:GetPivot() * CFrame.new(3, 0, 0)
    hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
    task.wait(0.1)

    if not seranok:FindFirstChild("Dialog") then
        Instance.new("Dialog", seranok)
    end

    if not _bridgeNPCID then
        local lastData = nil
        local conn = NPCPromptChat.OnClientEvent:Connect(function(_, data)
            if data then lastData = data end
        end)
        pcall(function() NPCPromptChat:FireServer(true, seranok, seranok.Dialog) end)
        local t = tick()
        repeat task.wait(0.05) until lastData or tick() - t > 5
        conn:Disconnect()
        pcall(function() NPCPromptChat:FireServer(false, seranok, seranok.Dialog) end)
        task.wait(0.1)

        if lastData then
            _bridgeNPCID = lastData.ID
        else
            warn("[TreeModule] Failed to get Seranok NPC ID.")
            return
        end
    end

    local npcArg = {
        ID        = _bridgeNPCID,
        Character = seranok,
        Name      = "Seranok",
        Dialog    = seranok.Dialog,
    }

    BridgeSafeInvoke(npcArg, "Initiate")
    task.wait(0.05)
    BridgeSafeInvoke(npcArg, "ConfirmPurchase")
    task.wait(0.05)
    BridgeSafeInvoke(npcArg, "EndChat")

    print("[TreeModule] Bridge toll paid — waiting for bridge to lower.")
    task.wait(1.5)
end

-- ==========================================
--   FALL DETECTION
-- ==========================================
local function TreeHasFallen(treeClass)
    local logModels = Workspace:FindFirstChild("LogModels")
    if not logModels then return false end
    for _, model in ipairs(logModels:GetChildren()) do
        if preChopLogModels[model] then continue end
        if not model:IsA("Model") then continue end
        local tc = model:FindFirstChild("TreeClass")
        if tc and tc.Value == treeClass then return true end
    end
    return false
end

-- ==========================================
--   DEATH / RESPAWN HANDLING
-- ==========================================
local function WaitForRespawn()
    print("[TreeModule] Player died — waiting for respawn...")

    local char = player.Character
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    if not char or not hum or hum.Health <= 0 then
        player.CharacterAdded:Wait()
    end

    local deadline = tick() + 30
    repeat
        task.wait(0.1)
        char = player.Character
        hum  = char and char:FindFirstChildOfClass("Humanoid")
    until (char and hum and hum.Health > 0 and char:FindFirstChild("HumanoidRootPart"))
       or tick() > deadline

    print(("[TreeModule] Respawned — resuming in %ds"):format(Settings.RespawnResumeDelay))
    task.wait(Settings.RespawnResumeDelay)
end

-- ==========================================
--   MAIN CHOP SEQUENCE
-- ==========================================
local function StartChopping(treeClass, LOT, onComplete)
    if isChopping then return end

    SnapshotLogModels()

    local treeModel = FindPriorityTree(treeClass)
    if not treeModel then
        warn("[TreeModule] No tree found for class:", treeClass)
        if onComplete then onComplete() end
        return
    end

    local sections = GetSectionsBottomFirst(treeModel)
    if #sections == 0 then
        warn("[TreeModule] Tree has no WoodSections.")
        if onComplete then onComplete() end
        return
    end

    local tool, axeName = GetBackpackAxe(treeClass)
    if not tool then
        warn("[TreeModule] No tool found in Backpack. Cannot chop.")
        if onComplete then onComplete() end
        return
    end
    print(("[TreeModule] Using '%s' from Backpack for tree class '%s'."):format(axeName, treeClass))

    local char = player.Character
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then
        if onComplete then onComplete() end
        return
    end

    preChopCFrame       = hrp.CFrame
    preChopCameraCFrame = camera.CFrame
    isChopping          = true

    if treeClass == "LoneCave" then
        PayBridgeToll()
        char = player.Character
        hrp  = char and char:FindFirstChild("HumanoidRootPart")
        if not hrp then
            isChopping = false
            if onComplete then onComplete() end
            return
        end
    end

    local targetPart = sections[1]
    for _, s in ipairs(sections) do
        local idObj = s:FindFirstChild("ID")
        if idObj and idObj.Value == 1 then
            targetPart = s
            break
        end
    end
    hrp.CFrame = targetPart.CFrame
    hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0)

    local lockConn = nil

    local function StartLockConn()
        if lockConn then lockConn:Disconnect() end
        lockConn = RunService.Heartbeat:Connect(function()
            local c = player.Character
            local r = c and c:FindFirstChild("HumanoidRootPart")
            if r and targetPart and targetPart.Parent then
                r.CFrame = targetPart.CFrame
                r.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
            end
        end)
    end

    local function StopLockConn()
        if lockConn then lockConn:Disconnect(); lockConn = nil end
    end

    local playerDied = false
    local diedConn   = nil

    local function HookDiedEvent()
        if diedConn then diedConn:Disconnect(); diedConn = nil end
        local c    = player.Character
        local hum2 = c and c:FindFirstChildOfClass("Humanoid")
        if not hum2 then return end
        diedConn = hum2.Died:Connect(function()
            playerDied = true
            StopLockConn()
            print("[TreeModule] Death detected during chop.")
        end)
    end

    HookDiedEvent()
    StartLockConn()
    task.wait(Settings.SyncDelay)

    task.spawn(function()
        local baseSection = nil

        local function RefreshBaseSection()
            baseSection = nil
            local fresh = GetSectionsBottomFirst(treeModel)
            if #fresh == 0 then return end
            baseSection = fresh[1]
            for _, s in ipairs(fresh) do
                local idObj = s:FindFirstChild("ID")
                if idObj and idObj.Value == 1 then
                    baseSection = s
                    break
                end
            end
        end

        RefreshBaseSection()

        while not TreeHasFallen(treeClass) and isChopping do
            if playerDied then
                StopLockConn()
                WaitForRespawn()
                if not isChopping then break end
                if TreeHasFallen(treeClass) then break end

                tool, axeName = GetBackpackAxe(treeClass)
                if not tool then
                    warn("[TreeModule] No axe found after respawn — stopping.")
                    isChopping = false
                    break
                end
                print(("[TreeModule] Resumed with '%s' after respawn."):format(axeName))

                local newChar = player.Character
                local newHRP  = newChar and newChar:FindFirstChild("HumanoidRootPart")
                if newHRP and targetPart and targetPart.Parent then
                    newHRP.CFrame = targetPart.CFrame
                    newHRP.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
                end

                playerDied = false
                HookDiedEvent()
                StartLockConn()
                task.wait(Settings.SyncDelay)

                RefreshBaseSection()
            end

            if not baseSection or not baseSection.Parent then
                RefreshBaseSection()
                if not baseSection then break end
            end

            FireCutSection(baseSection, tool, axeName, treeClass, function()
                return TreeHasFallen(treeClass) or playerDied
            end)

            task.wait(Settings.SweepDelay)
        end

        StopLockConn()
        if diedConn then diedConn:Disconnect(); diedConn = nil end

        if not isChopping then
            CleanupState()
            if onComplete then onComplete() end
            return
        end

        print("[TreeModule] Tree is down. Returning player.")
        task.wait(0.3)
        CleanupState()

        local stumps     = CollectNewStumps(treeClass)
        local currentHRP = player.Character and player.Character:FindFirstChild("HumanoidRootPart")

        RunLOTBatch(LOT, stumps, function(i, _)
            return currentHRP
                and (currentHRP.CFrame * CFrame.new((i - 1) * 5, 0, -Settings.LogDropDistance))
                or CFrame.new(0, 0, 0)
        end, onComplete)
    end)
end

-- ==========================================
--   LIVE TREE REMOVAL WATCHER
-- ==========================================
local function WatchForRemovedTreeTypes(onClassEmpty)
    local connections = {}
    
    local function CountTreeClass(className)
        local count = 0
        for _, folder in ipairs(Workspace:GetChildren()) do
            if folder.Name:lower():match("treeregion") then
                for _, model in ipairs(folder:GetChildren()) do
                    if model:IsA("Model") then
                        local tc = model:FindFirstChild("TreeClass")
                        if tc and tc.Value == className and CountTreeSections(model) > 1 then
                            count += 1
                        end
                    end
                end
            end
        end
        return count
    end

    local function WatchFolder(folder)
        local conn = folder.ChildRemoved:Connect(function(model)
            if not model:IsA("Model") then return end
            local tc = model:FindFirstChild("TreeClass")
            if not tc or not tc:IsA("StringValue") then return end
            local className = tc.Value
            -- small delay to let the engine settle before we recount
            task.delay(0.5, function()
                local remaining = CountTreeClass(className)
                onClassEmpty(className, remaining == 0)
            end)
        end)
        table.insert(connections, conn)
    end

    for _, folder in ipairs(Workspace:GetChildren()) do
        if folder.Name:lower():match("treeregion") then
            WatchFolder(folder)
        end
    end

    local workspaceConn = Workspace.ChildAdded:Connect(function(child)
        if child.Name:lower():match("treeregion") then
            WatchFolder(child)
        end
    end)
    table.insert(connections, workspaceConn)

    return function()
        for _, conn in ipairs(connections) do conn:Disconnect() end
    end
end

-- ==========================================
--   LIVE TREE TYPE WATCHER
-- ==========================================
-- Calls `onNewClass(className)` whenever a tree class appears in any
-- TreeRegion folder that wasn't present in `knownSet` at call time.
-- Returns a cleanup function that disconnects all listeners.
local function WatchForNewTreeTypes(knownSet, onNewClass)
    local connections = {}

    -- Hook ChildAdded on a single TreeRegion folder
    local function WatchFolder(folder)
        local conn = folder.ChildAdded:Connect(function(model)
            if not model:IsA("Model") then return end

            -- The TreeClass StringValue may not exist yet if the model
            -- is still streaming in — wait a short moment for it.
            task.delay(0.5, function()
                if not model or not model.Parent then return end
                local tc = model:FindFirstChild("TreeClass")
                if not tc or not tc:IsA("StringValue") then return end
                if CountTreeSections(model) <= 1 then return end
                local className = tc.Value
                if knownSet[className] then return end
                knownSet[className] = true
                onNewClass(className)
            end)
        end)
        table.insert(connections, conn)
    end

    -- Watch all TreeRegion folders that exist right now
    for _, folder in ipairs(Workspace:GetChildren()) do
        if folder.Name:lower():match("treeregion") then
            WatchFolder(folder)
        end
    end

    -- Also watch for TreeRegion folders that haven't loaded yet
    local workspaceConn = Workspace.ChildAdded:Connect(function(child)
        if child.Name:lower():match("treeregion") then
            WatchFolder(child)
        end
    end)
    table.insert(connections, workspaceConn)

    -- Return a cleanup function so Init can disconnect everything on
    -- shutdown if needed (e.g. if the Tab is destroyed)
    return function()
        for _, conn in ipairs(connections) do
            conn:Disconnect()
        end
    end
end

-- ==========================================
--             DYNXE UI
-- ==========================================
function TreeModule.Init(Tab, LOT)
    Tab:CreateSection("Auto-Tree Configuration")

    local PRIORITY_TREES = {
        "Generic", "Cherry", "Birch", "Oak", "Walnut", "Koa", "Pine", "Palm", "Fir",
        "Volcano", "Frost", "GreenSwampy", "GoldSwampy",
        "SnowGlow", "CaveCrawler", "LoneCave", "Spook", "Sinister",
    }

    local treeTypes = ScanForTreeTypes()
    
    -- Also scan for ALL tree classes present regardless of section count
    -- so we can show them in the list but disabled
    local function ScanAllTreeClasses()
        local found, seen = {}, {}
        for _, folder in ipairs(Workspace:GetChildren()) do
            if folder.Name:lower():match("treeregion") then
                for _, model in ipairs(folder:GetChildren()) do
                    if model:IsA("Model") then
                        local tc = model:FindFirstChild("TreeClass")
                        if tc and tc:IsA("StringValue") and not seen[tc.Value] then
                            seen[tc.Value] = true
                            table.insert(found, tc.Value)
                        end
                    end
                end
            end
        end
        return found
    end
    
    local allTreeClasses = ScanAllTreeClasses()
    
    local foundSet    = {}
    for _, t in ipairs(treeTypes) do foundSet[t] = true end
    local prioritySet = {}
    for _, t in ipairs(PRIORITY_TREES) do prioritySet[t] = true end
    
    -- allClassSet = every class present in workspace (even single-section ones)
    local allClassSet = {}
    for _, t in ipairs(allTreeClasses) do allClassSet[t] = true end
    
    local orderedOptions = {}
    local disabledInDrop = {}
    
    -- 1. Priority trees with valid (>1 section) trees — enabled
    for _, t in ipairs(PRIORITY_TREES) do
        if foundSet[t] then table.insert(orderedOptions, t) end
    end
    -- 2. Non-priority trees with valid trees — enabled
    for _, t in ipairs(treeTypes) do
        if not prioritySet[t] then table.insert(orderedOptions, t) end
    end
    -- 3. Priority trees that exist but only have single-section trees — disabled
    for _, t in ipairs(PRIORITY_TREES) do
        if not foundSet[t] and allClassSet[t] then
            table.insert(orderedOptions, t)
            disabledInDrop[t] = true
        end
    end
    -- 4. Priority trees completely absent from workspace — disabled
    for _, t in ipairs(PRIORITY_TREES) do
        if not allClassSet[t] then
            table.insert(orderedOptions, t)
            disabledInDrop[t] = true
        end
    end

    -- Default to first available (non-disabled) option
    local selectedTree = "Error"
    for _, t in ipairs(orderedOptions) do
        if not disabledInDrop[t] then selectedTree = t; break end
    end

    local chopQuantity      = 1
    local chopButton
    local chopSessionActive = false

    local treeDropdown = Tab:CreateDropdown("Target Tree Type", orderedOptions, selectedTree, function(sel)
        selectedTree = sel
    end)

    for t in pairs(disabledInDrop) do
        treeDropdown:SetOptionDisabled(t, true)
    end

    -- ── Live watcher ─────────────────────────────────────────────
    -- `knownSet` starts as a copy of foundSet so the watcher only
    -- fires for classes that were genuinely absent at init time.
    local knownSet = {}
    for k, v in pairs(foundSet) do knownSet[k] = v end

    WatchForNewTreeTypes(knownSet, function(newClass)
        print(("[TreeModule] New tree type detected: %s — enabling in dropdown."):format(newClass))

        -- If it's a known priority tree that was sitting disabled at
        -- the bottom, just re-enable it.  Otherwise add it fresh
        -- (between existing enabled options and the disabled block).
        if disabledInDrop[newClass] then
            disabledInDrop[newClass] = nil
            treeDropdown:SetOptionDisabled(newClass, false)
        else
            -- Truly new class (not in PRIORITY_TREES at all) —
            -- insert it before the first disabled entry so it lands
            -- in the "workspace extras" region of the list.
            local insertAt = #orderedOptions + 1
            for i, opt in ipairs(orderedOptions) do
                if disabledInDrop[opt] then
                    insertAt = i
                    break
                end
            end
            table.insert(orderedOptions, insertAt, newClass)
            treeDropdown:AddOption(newClass, insertAt)
        end

        -- If nothing was selectable before, auto-select this new class
        if selectedTree == "Error" then
            selectedTree = newClass
            treeDropdown:SetSelected(newClass)
        end
    end)
    -- ─────────────────────────────────────────────────────────────

    WatchForRemovedTreeTypes(function(className, isEmpty)
        if isEmpty then
            -- tree class has no more instances in any region — disable it
            disabledInDrop[className] = true
            treeDropdown:SetOptionDisabled(className, true)
            print(("[TreeModule] No more '%s' trees — disabled in dropdown."):format(className))
    
            -- if the player had this selected, reset to next available
            if selectedTree == className then
                selectedTree = "Error"
                for _, t in ipairs(orderedOptions) do
                    if not disabledInDrop[t] then
                        selectedTree = t
                        treeDropdown:SetSelected(t)
                        break
                    end
                end
            end
        else
            -- tree grew back / still has instances — make sure it's enabled
            if disabledInDrop[className] then
                disabledInDrop[className] = nil
                treeDropdown:SetOptionDisabled(className, false)
                print(("[TreeModule] '%s' trees available again — enabled in dropdown."):format(className))
            end
        end
    end)
    
    Tab:CreateSlider("Quantity", 1, 25, 1, function(val)
        chopQuantity = val
    end)

    chopButton = Tab:CreateAction("Get Tree", "Start", function()
        if chopSessionActive then
            chopSessionActive = false
            isChopping = false
            if type(chopButton) == "table" and chopButton.SetText then
                chopButton:SetText("Start")
            end
        else
            if selectedTree == "None Found" or selectedTree == "Error" then return end
            chopSessionActive = true
            if type(chopButton) == "table" and chopButton.SetText then
                chopButton:SetText("Stop")
            end

            local remaining = chopQuantity
            local function chopNext()
                if not chopSessionActive or remaining <= 0 then
                    chopSessionActive = false
                    if type(chopButton) == "table" and chopButton.SetText then
                        chopButton:SetText("Start")
                    end
                    return
                end
                remaining -= 1
                StartChopping(selectedTree, LOT, function()
                    chopNext()
                end)
            end

            chopNext()
        end
    end)

    Tab:CreateSection("Log Management")

    local chopSectionsButton
    chopSectionsButton = Tab:CreateAction("Chop All Trees", "Start", function()
        if _chopLogsActive then
            _chopLogsActive = false
            if type(chopSectionsButton) == "table" and chopSectionsButton.SetText then
                chopSectionsButton:SetText("Start")
            end
            return
        end

        if not LOT then warn("[TreeModule] LOT not available.") return end

        if type(chopSectionsButton) == "table" and chopSectionsButton.SetText then
            chopSectionsButton:SetText("Stop")
        end

        ChopLogsIntoSections(function()
            if type(chopSectionsButton) == "table" and chopSectionsButton.SetText then
                chopSectionsButton:SetText("Start")
            end
        end)
    end)
    
    local LogRow = Tab:CreateRow()

    local tpAllButton = LogRow:CreateAction("TP All Logs", "TP", function()
        if not LOT then warn("[TreeModule] LOT not available.") return end
        if LOT.IsBusy() then warn("[TreeModule] LOT busy.") return end
    
        local stumps     = CollectAllOwnedStumps()
        local currentHRP = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
        if #stumps == 0 then return end
    
        if type(tpAllButton) == "table" and tpAllButton.SetText then
            tpAllButton:SetText("Working...")
        end
    
        RunLOTBatch(LOT, stumps, function(_, _)
            return currentHRP
                and (currentHRP.CFrame * CFrame.new(0, 0, -Settings.LogDropDistance))
                or CFrame.new(0, 0, 0)
        end, function()
            if type(tpAllButton) == "table" and tpAllButton.SetText then
                tpAllButton:SetText("TP")
            end
        end)
    end)
    
    local sellButton = LogRow:CreateAction("Sell All Logs", "Sell", function()
        if not LOT then warn("[TreeModule] LOT not available.") return end
        if LOT.IsBusy() then warn("[TreeModule] LOT busy.") return end
    
        local stumps = CollectSingleSectionStumps()
        if #stumps == 0 then return end
    
        if type(sellButton) == "table" and sellButton.SetText then
            sellButton:SetText("Selling...")
        end
    
        local sellPos = Settings.SellPosition
        RunLOTBatch(LOT, stumps, function(_, _)
            return CFrame.new(sellPos.X, sellPos.Y, sellPos.Z)
        end, function()
            if type(sellButton) == "table" and sellButton.SetText then
                sellButton:SetText("Sell")
            end
        end)
    end)
    Tab:CreateToggle("Click To Sell (Planks)", false, function(state)
        if state then StartSellPlanks(LOT) else StopSellPlanks() end
    end)
    
    local pc_enabled        = false
    local pc_isCutting      = false
    local pc_outline        = nil
    local pc_cutPlanes      = {}
    local pc_trackedSection = nil
    local pc_currentTarget  = nil
    local pc_hoverConn      = nil
    local pc_clickConn      = nil
    local pc_visualConn     = nil
    local pc_mouse          = player:GetMouse()
    local pc_queue          = {}
    
    local PC_FIRE_DELAY    = 0.03
    local PC_CUT_TIMEOUT   = 90
    local PC_BLUE          = Color3.fromRGB(74, 120, 255)
    local PC_QUEUE_COLOR   = Color3.fromRGB(255, 170, 60)
    local pc_queueHighlights = {}
    local PC_MAX_CUT_UNITS = 100
    local PC_DETECT_RADIUS = 8
    local RemoteProxyPC    = ReplicatedStorage:WaitForChild("Interaction"):WaitForChild("RemoteProxy")
    
    local function pc_ReadAxeName(tool)
        if not tool then return nil end
        local tip = tool:FindFirstChild("ToolTip")
        return (tip and tip:IsA("StringValue")) and tip.Value or tool.ToolTip
    end
    
    local function pc_GetPlankTreeClass(plankModel)
        if not plankModel then return nil end
        local tc = plankModel:FindFirstChild("TreeClass")
        if tc and tc:IsA("StringValue") then return tc.Value end
        for _, v in ipairs(plankModel:GetDescendants()) do
            if v.Name == "TreeClass" and v:IsA("StringValue") then return v.Value end
        end
        return nil
    end
    
    local function pc_GetBestAxe(treeClass)
        local candidates = {}
        local function TryAdd(tool)
            if not tool:IsA("Tool") then return end
            if tool.Name == "BlueprintTool" then return end
            local name = pc_ReadAxeName(tool)
            if not name then return end
            if treeClass == "LoneCave" and name ~= "End Times Axe" then return end
            local dmg = _G.LT2Axes.GetDamage(name, treeClass) or 0
            table.insert(candidates, { tool = tool, name = name, dmg = dmg })
        end
        local char = player.Character
        if char then
            local eq = char:FindFirstChildOfClass("Tool")
            if eq then TryAdd(eq) end
        end
        for _, t in ipairs(player.Backpack:GetChildren()) do TryAdd(t) end
        if #candidates == 0 then return nil, nil, 0 end

        -- Refined Axe does 12 damage to planks — always prefer it for 1x1 cutting
        for _, c in ipairs(candidates) do
            if c.name == "Refined Axe" then
                return c.tool, c.name, 12
            end
        end

        table.sort(candidates, function(a, b) return a.dmg > b.dmg end)
        local best = candidates[1]
        return best.tool, best.name, best.dmg
    end
    
    local function pc_FindOwnedPlank(part)
        if not part then return nil end
        local pm = Workspace:FindFirstChild("PlayerModels")
        if not pm then return nil end
        local cur = part
        while cur and cur.Parent ~= pm do cur = cur.Parent end
        if not cur or not cur:IsA("Model") or cur.Name ~= "Plank" then return nil end
        local owner    = cur:FindFirstChild("Owner")
        local ownerStr = owner and owner:FindFirstChild("OwnerString")
        if not ownerStr or ownerStr.Value ~= player.Name then return nil end
        return cur
    end
    
    local function pc_GetPlankSection(model)
        if not model then return nil end
        for _, d in ipairs(model:GetDescendants()) do
            if d:IsA("BasePart") and d:FindFirstChild("ID") then return d end
        end
        return nil
    end
    
    local function pc_GetCutStep(section)
        return math.max(0.5, 1 / math.min(section.Size.X, section.Size.Z))
    end
    
    local PC_MIN_LEFTOVER = 1 -- studs; a trailing piece shorter than this is left uncut rather than sliced off

    local function pc_GetCutHeights(section)
        local sizeY = section.Size.Y
        local step  = pc_GetCutStep(section)
        local out   = {}
        local h     = step
        -- only add a cut if what's left above it would still be >= PC_MIN_LEFTOVER
        while h <= sizeY - PC_MIN_LEFTOVER + 0.001 do table.insert(out, h); h = h + step end
        return out, step
    end
    
    local function pc_IsPlankEligible(section, treeClass)
        if not section then return false end
        local heights = pc_GetCutHeights(section)
        if #heights == 0 then return false end
        if #heights > PC_MAX_CUT_UNITS then return false end
        if treeClass == "LoneCave" then
            local t = pc_GetBestAxe("LoneCave")
            if not t then return false end
        end
        return true
    end

    local function pc_AddQueueHighlight(plank)
        if not plank or pc_queueHighlights[plank] then return end
        local box = Instance.new("SelectionBox")
        box.Color3 = PC_QUEUE_COLOR
        box.SurfaceColor3 = PC_QUEUE_COLOR
        box.LineThickness = 0.03
        box.SurfaceTransparency = 0.85
        box.Adornee = plank
        box.Parent = Workspace
        pc_queueHighlights[plank] = box
    end

    local function pc_RemoveQueueHighlight(plank)
        local box = pc_queueHighlights[plank]
        if box then
            pcall(function() box:Destroy() end)
            pc_queueHighlights[plank] = nil
        end
    end

    local function pc_ClearQueueHighlights()
        for _, box in pairs(pc_queueHighlights) do
            pcall(function() box:Destroy() end)
        end
        pc_queueHighlights = {}
    end

    local function pc_QueuePlank(plank)
        if not plank or plank == pc_currentTarget then return end
        for _, queued in ipairs(pc_queue) do
            if queued == plank then return end
        end
        table.insert(pc_queue, plank)
        pc_AddQueueHighlight(plank)
    end

    local function pc_PopNextQueued()
        while #pc_queue > 0 do
            local candidate = table.remove(pc_queue, 1)
            pc_RemoveQueueHighlight(candidate)
            if candidate and candidate.Parent then
                local sec = pc_GetPlankSection(candidate)
                local tc  = pc_GetPlankTreeClass(candidate)
                if sec and pc_IsPlankEligible(sec, tc) then
                    return candidate
                end
            end
        end
        return nil
    end
    
    local function pc_EnsureOutline()
        if pc_outline and pc_outline.Parent then return end
        pc_outline = Instance.new("SelectionBox")
        pc_outline.Color3 = PC_BLUE
        pc_outline.SurfaceColor3 = PC_BLUE
        pc_outline.LineThickness = 0.04
        pc_outline.SurfaceTransparency = 0.8
        pc_outline.Parent = Workspace
    end
    
    local function pc_SetOutlineTarget(model)
        pc_EnsureOutline()
        if pc_outline.Adornee ~= model then pc_outline.Adornee = model end
    end
    
    local function pc_ClearCutPlanes()
        for _, e in ipairs(pc_cutPlanes) do pcall(function() e.part:Destroy() end) end
        pc_cutPlanes = {}
        pc_trackedSection = nil
    end
    
    local function pc_RebuildCutPlanes(section)
        pc_ClearCutPlanes()
        if not section or not section.Parent then return end
        local heights = pc_GetCutHeights(section)
        local sx    = section.Size.X + 0.08
        local sz    = section.Size.Z + 0.08
        local sizeY = section.Size.Y
        for _, h in ipairs(heights) do
            local localCF = CFrame.new(0, -sizeY / 2 + h, 0)
            local p = Instance.new("Part")
            p.Anchored = true; p.CanCollide = false; p.CanTouch = false
            p.CanQuery = false; p.CastShadow = false
            p.Size = Vector3.new(sx, 0.04, sz)
            p.Color = PC_BLUE; p.Material = Enum.Material.Neon
            p.Transparency = 0.2
            p.CFrame = section.CFrame * localCF
            p.Parent = Workspace
            table.insert(pc_cutPlanes, { part = p, localCF = localCF })
        end
        pc_trackedSection = section
    end
    
    local function pc_FindCutEvent(section)
        local cur = section
        while cur and cur ~= Workspace do
            local ce = cur:FindFirstChild("CutEvent")
            if ce then return ce end
            cur = cur.Parent
        end
        return nil
    end
    
    local function pc_FireUntilSplit(section, tool, damage, height)
        local idObj    = section:FindFirstChild("ID")
        local cutEvent = pc_FindCutEvent(section)
        if not idObj or not cutEvent then return nil end
        local pm = Workspace:FindFirstChild("PlayerModels")
        local snapshot = {}
        if pm then for _, m in ipairs(pm:GetChildren()) do snapshot[m] = true end end
        local args = {
            sectionId = idObj.Value, faceVector = Vector3.new(0,0,-1),
            height = height, hitPoints = damage, cooldown = 0,
            cuttingClass = "Axe", tool = tool,
        }
        local lastPos = section.Position
        local function FindNewSection()
            if not pm then return nil end
            for _, m in ipairs(pm:GetChildren()) do
                if not snapshot[m] and m:IsA("Model") and m.Name == "Plank" then
                    local owner = m:FindFirstChild("Owner")
                    local ownerStr = owner and owner:FindFirstChild("OwnerString")
                    if ownerStr and ownerStr.Value == player.Name then
                        local sec = pc_GetPlankSection(m)
                        if sec and (sec.Position - lastPos).Magnitude <= PC_DETECT_RADIUS then
                            return sec
                        end
                    end
                end
            end
            return nil
        end
        local originalSizeY = section.Size.Y
        local deadline = tick() + PC_CUT_TIMEOUT
        while tick() < deadline and pc_enabled do
            if section.Parent then lastPos = section.Position end
            if not section.Parent then task.wait(0.05); return FindNewSection() end
            RemoteProxyPC:FireServer(cutEvent, args)
            task.wait(PC_FIRE_DELAY)
            if not section.Parent or section.Size.Y ~= originalSizeY then
                task.wait(0.05); return FindNewSection()
            end
        end
        return nil
    end
    
    local function pc_TeleportAbovePlank(section, cutHeight)
        local char = player.Character
        local hrp  = char and char:FindFirstChild("HumanoidRootPart")
        if not hrp or not section or not section.Parent then return end
        local bottomY   = -section.Size.Y / 2
        local localCutY = bottomY + (cutHeight or 0)
        local worldPos  = (section.CFrame * CFrame.new(0, localCutY + 3, 0)).Position
        if (hrp.Position - worldPos).Magnitude <= PC_DETECT_RADIUS then return end
        hrp.CFrame = CFrame.new(worldPos)
        hrp.AssemblyLinearVelocity  = Vector3.new(0, 0, 0)
        hrp.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
    end
    
    local pc_statusBB = nil
    local pc_sessionCutCount = 0
    local pc_sessionCutTotal = 0.0

    local function pc_ShowStatus(text)
        if pc_statusBB then pc_statusBB:Destroy(); pc_statusBB = nil end
        local char = player.Character
        local hrp  = char and char:FindFirstChild("HumanoidRootPart")
        if not hrp then return end

        local bb = Instance.new("BillboardGui")
        bb.Name        = "DynxeCutStatus"
        bb.Size        = UDim2.new(0, 220, 0, 48)
        bb.StudsOffset = Vector3.new(0, 4, 0)
        bb.AlwaysOnTop = true
        bb.Adornee     = hrp
        bb.Parent      = game:GetService("CoreGui")

        local bg = Instance.new("Frame")
        bg.Size                   = UDim2.new(1, 0, 1, 0)
        bg.BackgroundColor3       = Color3.fromRGB(18, 18, 22)
        bg.BackgroundTransparency = 0.1
        bg.BorderSizePixel        = 0
        bg.Parent                 = bb
        local corner = Instance.new("UICorner", bg)
        corner.CornerRadius = UDim.new(0, 6)
        local stroke = Instance.new("UIStroke", bg)
        stroke.Color     = Color3.fromRGB(74, 120, 255)
        stroke.Thickness = 1.5

        local topBar = Instance.new("Frame")
        topBar.Size             = UDim2.new(1, 0, 0, 3)
        topBar.BackgroundColor3 = Color3.fromRGB(74, 120, 255)
        topBar.BorderSizePixel  = 0
        topBar.ZIndex           = 3
        topBar.Parent           = bg

        local lbl = Instance.new("TextLabel")
        lbl.Size                   = UDim2.new(1, -10, 1, -6)
        lbl.Position               = UDim2.new(0, 5, 0, 5)
        lbl.BackgroundTransparency = 1
        lbl.Text                   = text
        lbl.TextColor3             = Color3.fromRGB(210, 215, 240)
        lbl.Font                   = Enum.Font.GothamBold
        lbl.TextSize               = 13
        lbl.TextXAlignment         = Enum.TextXAlignment.Center
        lbl.TextYAlignment         = Enum.TextYAlignment.Center
        lbl.ZIndex                 = 4
        lbl.Parent                 = bg

        pc_statusBB = bb
        return lbl
    end

    local function pc_HideStatus()
        if pc_statusBB then pc_statusBB:Destroy(); pc_statusBB = nil end
    end

    local function pc_CountCuts(section)
        local heights = pc_GetCutHeights(section)
        return #heights, #heights + 1  -- cuts needed, planks produced
    end

    local function pc_CutPlankIntoUnits(plankModel)
        pc_isCutting     = true
        pc_currentTarget = plankModel
        pc_SetOutlineTarget(plankModel)
        local treeClass = pc_GetPlankTreeClass(plankModel)
        local tool, axeName, damage = pc_GetBestAxe(treeClass)
        if not tool then
            pc_SetOutlineTarget(nil); pc_ClearCutPlanes()
            pc_isCutting = false; pc_currentTarget = nil; return
        end
        local section = pc_GetPlankSection(plankModel)
        if not section then
            pc_SetOutlineTarget(nil); pc_ClearCutPlanes()
            pc_isCutting = false; pc_currentTarget = nil; return
        end

        local step            = pc_GetCutStep(section)
        local cutsNeeded, planksTotal = pc_CountCuts(section)
        local statusLbl       = pc_ShowStatus(
            string.format("✂  %d planks  ·  ETA --", planksTotal)
        )

        local cutsDone    = 0
        local avgCutTime  = nil

        local function formatETA(secsLeft)
            local s = math.floor(secsLeft)
            local m = math.floor(s / 60)
            s = s % 60
            return m > 0 and string.format("%dm %ds", m, s) or string.format("%ds", s)
        end

        local function updateStatus()
            if not statusLbl or not statusLbl.Parent then return end
            local planksLeft = math.max(0, planksTotal - cutsDone - 1)
            local cutsLeft   = math.max(0, cutsNeeded - cutsDone)
            local etaStr     = "--"
            if avgCutTime and cutsLeft > 0 then
                etaStr = formatETA(avgCutTime * cutsLeft)
            elseif cutsLeft == 0 then
                etaStr = "done"
            end
            local queueSuffix = #pc_queue > 0 and string.format("  ·  +%d queued", #pc_queue) or ""
            statusLbl.Text = string.format("✂  %d planks  ·  ETA %s%s", planksLeft, etaStr, queueSuffix)
        end

        pc_TeleportAbovePlank(section, step)
        task.wait(0.1)

        local cur = section
        while pc_enabled and cur and cur.Parent do
            if cur.Size.Y - step < PC_MIN_LEFTOVER - 0.001 then break end
            pc_RebuildCutPlanes(cur)
            pc_currentTarget = cur.Parent
            pc_SetOutlineTarget(pc_currentTarget)
            pc_TeleportAbovePlank(cur, step)

            local t0     = tick()
            local newSec = pc_FireUntilSplit(cur, tool, damage, step)
            local elapsed = tick() - t0

            cutsDone += 1

            pc_sessionCutCount += 1
            pc_sessionCutTotal += elapsed
            avgCutTime = pc_sessionCutTotal / pc_sessionCutCount

            pc_ClearCutPlanes()
            updateStatus()

            if not newSec then break end
            local nextPiece = cur
            if not (cur.Parent and cur.Size.Y > newSec.Size.Y) then nextPiece = newSec end
            if nextPiece and nextPiece.Parent then
                cur = nextPiece
                pc_currentTarget = nextPiece.Parent
                pc_SetOutlineTarget(pc_currentTarget)
            end
            task.wait(0.1)
        end

        pc_sessionCutCount = 0
        pc_sessionCutTotal = 0.0
        pc_ClearCutPlanes()
        pc_HideStatus()
        pc_isCutting = false

        if pc_enabled then
            local nextPlank = pc_PopNextQueued()
            if nextPlank then
                task.spawn(pc_CutPlankIntoUnits, nextPlank)
            end
        end
    end
    
    Tab:CreateToggle("1x1 Cutter", false, function(state)
        if state then
            pc_enabled   = true
            pc_isCutting = false
    
            pc_visualConn = RunService.Heartbeat:Connect(function()
                if not pc_trackedSection or not pc_trackedSection.Parent then return end
                local cf = pc_trackedSection.CFrame
                for _, e in ipairs(pc_cutPlanes) do
                    if e.part.Parent then e.part.CFrame = cf * e.localCF end
                end
            end)
    
            local lastSection = nil
            pc_hoverConn = RunService.RenderStepped:Connect(function()
                if not pc_enabled or pc_isCutting then return end
                local target = pc_mouse.Target
                local plank  = pc_FindOwnedPlank(target)
                if plank then
                    local sec = pc_GetPlankSection(plank)
                    local tc  = pc_GetPlankTreeClass(plank)
                    if sec and pc_IsPlankEligible(sec, tc) then
                        if pc_currentTarget ~= plank then
                            pc_currentTarget = plank
                            pc_SetOutlineTarget(plank)
                        end
                        if sec ~= lastSection then
                            lastSection = sec
                            pc_RebuildCutPlanes(sec)
                        end
                    else
                        if pc_currentTarget then
                            pc_currentTarget = nil
                            pc_SetOutlineTarget(nil)
                            pc_ClearCutPlanes()
                            lastSection = nil
                        end
                    end
                else
                    local clearOk = true
                    if pc_currentTarget and target and target:IsDescendantOf(pc_currentTarget) then
                        clearOk = false
                    end
                    if clearOk and pc_currentTarget then
                        pc_currentTarget = nil
                        pc_SetOutlineTarget(nil)
                        pc_ClearCutPlanes()
                        lastSection = nil
                    end
                end
            end)
    
            pc_clickConn = pc_mouse.Button1Down:Connect(function()
                if not pc_enabled then return end
                local plank = pc_FindOwnedPlank(pc_mouse.Target)
                if not plank then return end
                local sec = pc_GetPlankSection(plank)
                local tc  = pc_GetPlankTreeClass(plank)
                if not pc_IsPlankEligible(sec, tc) then return end
                if pc_isCutting then
                    pc_QueuePlank(plank)
                else
                    task.spawn(function() pc_CutPlankIntoUnits(plank) end)
                end
            end)
    
        else
            pc_sessionCutCount = 0
            pc_sessionCutTotal = 0.0
            pc_enabled = false
            pc_queue = {}
            pc_ClearQueueHighlights()
            if pc_hoverConn  then pc_hoverConn:Disconnect();  pc_hoverConn  = nil end
            if pc_clickConn  then pc_clickConn:Disconnect();  pc_clickConn  = nil end
            if pc_visualConn then pc_visualConn:Disconnect(); pc_visualConn = nil end
            if pc_outline    then pc_outline.Adornee = nil end
            pc_ClearCutPlanes()
            pc_currentTarget = nil
            pc_HideStatus()
        end
    end)

    -- ==========================================
    --   HOVER VALUE DISPLAY
    -- ==========================================
    local TREE_RATES = {
        Generic     = 1.5,  Cherry    = 1.3,  Birch      = 2.25,
        Oak         = 0.75, Walnut    = 1.2,  Koa        = 2.8,
        Pine        = 3.2,  Palm      = 2.9,  Fir        = 3.2,
        Volcano     = 3.5,  Frost     = 9.0,  GreenSwampy = 4.4,
        GoldSwampy  = 5.7,  SnowGlow  = 1.5,  CaveCrawler = 8.0,
        LoneCave    = 150.0, BlueSpruce = 20.0, Spook    = 19.0,
        SpookNeon   = 25.0,
    }
    local PLANK_RATES = {
        Generic     = 10,   Cherry    = 10.5, Birch      = 15,
        Oak         = 6,    Walnut    = 11,   Koa        = 26.4,
        Pine        = 18,   Palm      = 32,   Fir        = 18,
        Volcano     = 28,   Frost     = 106.0, GreenSwampy = 30.0,
        GoldSwampy  = 36.0, SnowGlow  = 10,   CaveCrawler = 36.0,
        LoneCave    = 420.0, BlueSpruce = 40.0, Spook    = 54.0,
        SpookNeon   = 90.0,
    }

    local hv_billboard  = nil
    local hv_lastModel  = nil
    local hv_hoverConn  = nil
    local hv_mouse      = player:GetMouse()
    local hv_CoreGui    = game:GetService("CoreGui")

    local HV_ACCENT  = Color3.fromRGB(74,  120, 255)
    local HV_BG      = Color3.fromRGB(18,  18,  22)
    local HV_STROKE  = Color3.fromRGB(40,  40,  48)
    local HV_MUTED   = Color3.fromRGB(120, 120, 130)

    local function hv_DestroyBillboard()
        if hv_billboard and hv_billboard.Parent then hv_billboard:Destroy() end
        hv_billboard = nil
        hv_lastModel = nil
    end

    local function hv_CreateBillboard(adornPart, heightOffset, valueText, labelText)
        if hv_billboard then hv_billboard:Destroy(); hv_billboard = nil end

        local char = player.Character
        local hrp  = char and char:FindFirstChild("HumanoidRootPart")
        if not hrp then return end

        local bb = Instance.new("BillboardGui")
        bb.Name          = "DynxeHoverValue"
        bb.Size          = UDim2.new(0, 200, 0, 56)
        bb.StudsOffset   = Vector3.new(0, 4, 0)
        bb.AlwaysOnTop   = true
        bb.MaxDistance   = 800
        bb.Adornee       = hrp
        bb.Parent        = hv_CoreGui

        local bg = Instance.new("Frame")
        bg.Size                   = UDim2.new(1, 0, 1, 0)
        bg.BackgroundColor3       = Color3.fromRGB(18, 18, 22)
        bg.BackgroundTransparency = 0.1
        bg.BorderSizePixel        = 0
        bg.Parent                 = bb
        local corner = Instance.new("UICorner", bg)
        corner.CornerRadius = UDim.new(0, 6)
        local stroke = Instance.new("UIStroke", bg)
        stroke.Color     = HV_ACCENT
        stroke.Thickness = 1.5

        local topBar = Instance.new("Frame")
        topBar.Size             = UDim2.new(1, 0, 0, 3)
        topBar.BackgroundColor3 = HV_ACCENT
        topBar.BorderSizePixel  = 0
        topBar.ZIndex           = 3
        topBar.Parent           = bg

        local valueLbl = Instance.new("TextLabel")
        valueLbl.Size                   = UDim2.new(1, -12, 0, 28)
        valueLbl.Position               = UDim2.new(0, 6, 0, 6)
        valueLbl.BackgroundTransparency = 1
        valueLbl.Text                   = valueText
        valueLbl.TextColor3             = HV_ACCENT
        valueLbl.Font                   = Enum.Font.GothamBold
        valueLbl.TextSize               = 20
        valueLbl.TextXAlignment         = Enum.TextXAlignment.Center
        valueLbl.ZIndex                 = 4
        valueLbl.Parent                 = bg

        local subLbl = Instance.new("TextLabel")
        subLbl.Size                   = UDim2.new(1, -12, 0, 14)
        subLbl.Position               = UDim2.new(0, 6, 0, 36)
        subLbl.BackgroundTransparency = 1
        subLbl.Text                   = labelText
        subLbl.TextColor3             = Color3.fromRGB(210, 215, 240)
        subLbl.Font                   = Enum.Font.Gotham
        subLbl.TextSize               = 12
        subLbl.TextXAlignment         = Enum.TextXAlignment.Center
        subLbl.ZIndex                 = 4
        subLbl.Parent                 = bg

        hv_billboard = bb
    end

    local function hv_GetWoodVolume(model)
        local total = 0
        for _, part in ipairs(model:GetChildren()) do
            if part.Name == "WoodSection" and part:IsA("BasePart") then
                total += part.Size.X * part.Size.Y * part.Size.Z
            end
        end
        return total
    end

    local function hv_FormatMoney(n)
        local s      = tostring(math.floor(n + 0.5))
        local result = ""
        local len    = #s
        for i = 1, len do
            if i > 1 and (len - i + 1) % 3 == 0 then result ..= "," end
            result ..= s:sub(i, i)
        end
        return "$" .. result
    end

    local function hv_EvaluateModel(model)
        if not model or not model.Parent then return nil end
        local parent   = model.Parent
        local mainPart = model:FindFirstChild("Main") or model:FindFirstChildWhichIsA("BasePart")
        if not mainPart then return nil end

        local bbCF, bbSize = model:GetBoundingBox()
        local topY         = bbCF.Position.Y + bbSize.Y * 0.5
        local heightOffset = math.clamp((topY - mainPart.Position.Y) + 3, 3, 12)

        if parent.Name:lower():match("treeregion") then
            local tc   = model:FindFirstChild("TreeClass")
            local cls  = tc and tc.Value or "Unknown"
            local vol  = hv_GetWoodVolume(model)
            if vol <= 0 then return nil end
            return mainPart, heightOffset,
                hv_FormatMoney(vol * (TREE_RATES[cls] or 1.0)),
                cls .. "  ·  Tree"
        end

        if parent.Name == "PlayerModels" then
            local vol = hv_GetWoodVolume(model)
            if vol <= 0 then return nil end
            local tc  = model:FindFirstChild("TreeClass")
            local cls = tc and tc.Value or nil
            return mainPart, heightOffset,
                hv_FormatMoney(vol * ((cls and PLANK_RATES[cls]) or 1.0)),
                (cls or "Unknown") .. "  ·  Plank"
        end

        if parent.Name == "LogModels" then
            local vol = hv_GetWoodVolume(model)
            if vol <= 0 then return nil end
            local tc  = model:FindFirstChild("TreeClass")
            local cls = tc and tc.Value or nil
            return mainPart, heightOffset,
                hv_FormatMoney(vol * ((cls and TREE_RATES[cls]) or 1.0)),
                (cls or "Unknown") .. "  ·  Log"
        end

        return nil
    end

    local function hv_Enable()
        if hv_hoverConn then hv_hoverConn:Disconnect() end
        hv_hoverConn = RunService.RenderStepped:Connect(function()
            local target = hv_mouse.Target
            local model  = target and target:FindFirstAncestorOfClass("Model")
            if model == hv_lastModel then return end
            hv_lastModel = model
            if not model then hv_DestroyBillboard(); return end
            local adornPart, heightOffset, valueText, subText = hv_EvaluateModel(model)
            if adornPart then
                hv_CreateBillboard(adornPart, heightOffset, valueText, subText)
            else
                hv_DestroyBillboard()
            end
        end)
    end

    local function hv_Disable()
        if hv_hoverConn then hv_hoverConn:Disconnect(); hv_hoverConn = nil end
        hv_DestroyBillboard()
    end

    Tab:CreateToggle("Hover Value Display", false, function(on)
        if on then hv_Enable() else hv_Disable() end
    end)
end

return TreeModule