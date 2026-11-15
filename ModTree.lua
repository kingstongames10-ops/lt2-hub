-- [[ MOD TREE MODULE ]]
-- Designed for Dynxe LT2 UI Engine

local ModTreeModule = {}

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local Player      = Players.LocalPlayer
local Mouse       = Player:GetMouse()
local RemoteProxy = ReplicatedStorage:WaitForChild("Interaction"):WaitForChild("RemoteProxy")

local ClientPlacedBlueprint = ReplicatedStorage
    :WaitForChild("PlaceStructure")
    :WaitForChild("ClientPlacedBlueprint")

local _LOT = nil
local _Lib = nil

function ModTreeModule.SetLOT(lot) _LOT = lot end

-- ============================================================
-- DEBUG  (default OFF — flip to true to see console output)
-- ============================================================
local _debugMode = false

local function DebugLog(level, ...)
    if not _debugMode then return end
    if level == "warn" then warn(...) else print(...) end
end

-- Constants
local MOD_TP_CF            = CFrame.new(-1420, 380, 1400)
local DROP_ZONE_CF         = CFrame.new(-360, 92, -100)
local DISAPPEAR_TIMEOUT    = 60
local CHOP_FIRES           = 100
local CHOP_FIRE_DELAY      = 0.03
local CHOP_CONFIRM_TIMEOUT = 40

-- Blueprint placement constants
local BLUEPRINT_NAME  = "Wall2"
local TILE_END_OFFSET = CFrame.new(0, 5, -1.8)
local TILE_OFFSET_4L  = CFrame.new(0, 8.5, -1.8)
local MATCH_TOLERANCE = 1

-- Session state
local _isModding      = false
local _isModSawmill   = false
local _currentSession = nil

-- ┌─────────────────────────────────────────────────────────────────┐
-- │  Module-level alive refs — stored here so the cancel handlers   │
-- │  can set [1] = false and immediately unblock any WaitFor loop.  │
-- └─────────────────────────────────────────────────────────────────┘
local _modAliveRef     = { false }
local _sawmillAliveRef = { false }

-- ============================================================
-- NOTIFY HELPER
-- ============================================================

local function Notify(title, text)
    if _Lib and _Lib.Notify then
        _Lib:Notify(title, text)
    end
end

local function NotifyDebug(title, text)
    Notify(title, text)
    DebugLog("print", ("[%s] %s"):format(title, text))
end

-- ============================================================
-- SAWMILL BLUEPRINT HELPERS
-- ============================================================

local function GetBlueprintOffset(sawmill)
    local itemName = sawmill:FindFirstChild("ItemName")
    if itemName and itemName.Value == "Sawmill4L" then return TILE_OFFSET_4L end
    return TILE_END_OFFSET
end

local function GetSawmillParticlesCF(sawmill)
    local particles = sawmill:FindFirstChild("Particles", true)
    if particles and particles:IsA("BasePart") then return particles.CFrame end
    return select(1, sawmill:GetBoundingBox())
end

local function FindExistingBlueprint(targetCF)
    local pm = workspace:FindFirstChild("PlayerModels")
    if not pm then return nil end
    for _, model in ipairs(pm:GetChildren()) do
        local itemName = model:FindFirstChild("ItemName")
        if not itemName or itemName.Value ~= BLUEPRINT_NAME then continue end
        local owner       = model:FindFirstChild("Owner")
        local ownerString = owner and owner:FindFirstChild("OwnerString")
        local ownerVal    = owner and owner.Value
        local isOwner = (ownerString and ownerString.Value == Player.Name)
                     or (ownerVal    and ownerVal           == Player)
        if not isOwner then continue end
        local cf = (model:FindFirstChild("MainCFrame") and model.MainCFrame.Value)
                or (model.PrimaryPart and model.PrimaryPart.CFrame)
                or model:GetPivot()
        if (cf.Position - targetCF.Position).Magnitude <= MATCH_TOLERANCE then
            return model
        end
    end
    return nil
end

local function PlaceBlueprintAtSawmill(sawmill)
    local particlesCF = GetSawmillParticlesCF(sawmill)
    local offset      = GetBlueprintOffset(sawmill)
    local finalCF     = particlesCF * offset * CFrame.Angles(math.rad(90), 0, 0)
    local existing    = FindExistingBlueprint(finalCF)
    if existing then
        DebugLog("print", "[ModTree] Blueprint already at sawmill — skipping placement.")
        return false
    end
    DebugLog("print", "[ModTree] Placing blueprint at sawmill output...")
    ClientPlacedBlueprint:FireServer(BLUEPRINT_NAME, finalCF, Player)
    DebugLog("print", "[ModTree] Blueprint placed.")
    return true  -- newly placed
end

-- ============================================================
-- AXE HELPERS
-- ============================================================

local function ReadAxeName(tool)
    if not tool then return nil end
    local tip = tool:FindFirstChild("ToolTip")
    return (tip and tip:IsA("StringValue")) and tip.Value or tool.ToolTip
end

local function GetBestAxe(treeClass)
    local candidates = {}

    local function TryAdd(tool)
        if not tool:IsA("Tool") or tool.Name == "BlueprintTool" then return end
        local name = ReadAxeName(tool)
        if not name then return end
        local score = treeClass
            and _G.LT2Axes.GetDamage(name, treeClass)
            or (1 / (_G.LT2Axes.Rank[name] or 2^53))
        table.insert(candidates, { tool = tool, name = name, score = score })
    end

    local char = Player.Character
    if char then
        local equipped = char:FindFirstChildOfClass("Tool")
        if equipped then TryAdd(equipped) end
    end
    for _, tool in ipairs(Player.Backpack:GetChildren()) do TryAdd(tool) end

    if #candidates == 0 then return nil, nil, 0 end
    table.sort(candidates, function(a, b) return a.score > b.score end)

    local best = candidates[1]
    return best.tool, best.name, best.score
end

-- ============================================================
-- TREE ANALYSIS
-- ============================================================

local function AnalyzeTree(treeModel)
    local entries = {}

    for _, part in ipairs(treeModel:GetDescendants()) do
        if part:IsA("BasePart") and part.Name ~= "Stump" then
            local idVal = part:FindFirstChild("ID")
            if idVal and (idVal:IsA("IntValue") or idVal:IsA("NumberValue")) then
                local childIDs    = {}
                local childFolder = part:FindFirstChild("ChildIDs")
                if childFolder then
                    for _, child in ipairs(childFolder:GetChildren()) do
                        if child.Name == "Child" and (child:IsA("IntValue") or child:IsA("NumberValue")) then
                            table.insert(childIDs, child.Value)
                        end
                    end
                end
                table.insert(entries, {
                    part        = part,
                    id          = idVal.Value,
                    childIDs    = childIDs,
                    hasChildren = #childIDs > 0,
                })
            end
        end
    end

    table.sort(entries, function(a, b) return a.id < b.id end)

    local stumpEntry, targetEntry = entries[1], nil
    for i = #entries, 1, -1 do
        if entries[i].hasChildren then targetEntry = entries[i]; break end
    end

    local tipID = nil
    if targetEntry then
        for _, cid in ipairs(targetEntry.childIDs) do
            if not tipID or cid > tipID then tipID = cid end
        end
    end

    return { all = entries, stump = stumpEntry, target = targetEntry, tipID = tipID }
end

-- ============================================================
-- CLICK HELPERS
-- ============================================================

local function GetAncestorModel(instance)
    local current = instance
    while current and not current:IsA("Model") do current = current.Parent end
    return current
end

local SAWMILL_NAMES = {
    Sawmill = true, Sawmill2 = true, Sawmill3 = true,
    Sawmill4 = true, Sawmill4L = true,
}

local function IsValidSawmill(model)
    if not model or not model:IsA("Model") then return false end
    local itemName = model:FindFirstChild("ItemName")
    return itemName and itemName:IsA("StringValue") and SAWMILL_NAMES[itemName.Value] == true
end

local function IsValidTree(model)
    if not model or not model:IsA("Model") then return false end
    local logModels = workspace:FindFirstChild("LogModels")
    if not logModels or model.Parent ~= logModels then return false end
    for _, desc in ipairs(model:GetDescendants()) do
        if desc:IsA("BasePart") and desc:FindFirstChild("ID") then return true end
    end
    return false
end

-- WaitForSawmillClick: waits for a single sawmill click, unchanged from original.
local function WaitForSawmillClick(aliveRef)
    local result, done, conn = nil, false, nil
    conn = Mouse.Button1Down:Connect(function()
        local target = Mouse.Target
        if not target then return end
        local playerModels = workspace:FindFirstChild("PlayerModels")
        if not playerModels then return end
        local current = target
        while current and current.Parent ~= playerModels do current = current.Parent end
        if IsValidSawmill(current) then
            result = current; done = true; conn:Disconnect()
        end
    end)
    while not done and aliveRef[1] do task.wait() end
    if conn.Connected then conn:Disconnect() end
    return result
end

-- WaitForTreeQueueThenSawmill:
--   Lets the player click any number of trees to queue them.
--   The FIRST sawmill click ends selection and returns both the queue
--   and the selected sawmill — no extra button needed.
local function WaitForTreeQueueThenSawmill(aliveRef)
    local queue    = {}
    local queueSet = {}
    local sawmill  = nil
    local done     = false
    local conn

    conn = Mouse.Button1Down:Connect(function()
        if not aliveRef[1] or done then return end
        local target = Mouse.Target
        if not target then return end

        -- Check for sawmill first — this ends selection.
        do
            local playerModels = workspace:FindFirstChild("PlayerModels")
            if playerModels then
                local current = target
                while current and current.Parent ~= playerModels do
                    current = current.Parent
                end
                if IsValidSawmill(current) then
                    sawmill = current
                    done    = true
                    conn:Disconnect()
                    return
                end
            end
        end

        -- Otherwise check for a tree and add to queue.
        local model = GetAncestorModel(target)
        if not IsValidTree(model) then return end
        if queueSet[model] then
            Notify("Mod Tree", ("Already queued — %d tree(s) selected. Click your sawmill when ready."):format(#queue))
            return
        end
        queueSet[model] = true
        table.insert(queue, model)
        DebugLog("print", ("[ModTree] Tree queued: %s (total=%d)"):format(model.Name, #queue))
        Notify("Mod Tree", ("%d tree(s) queued — click your sawmill when ready."):format(#queue))
    end)

    while not done and aliveRef[1] do task.wait() end
    if conn.Connected then conn:Disconnect() end

    return queue, sawmill
end

-- ============================================================
-- REMOTE CUT
-- ============================================================

local function FireCutSection(section, tool, axeName, treeClass, stopFn)
    if not section or not section.Parent then return false end

    local idObj = section:FindFirstChild("ID")
    if not idObj then
        DebugLog("warn", "[ModTree] FireCutSection: no ID on", section:GetFullName()); return false
    end

    local cutEvent, current = nil, section
    while current and current ~= workspace do
        cutEvent = current:FindFirstChild("CutEvent")
        if cutEvent then break end
        current = current.Parent
    end
    if not cutEvent then
        DebugLog("warn", "[ModTree] FireCutSection: CutEvent not found for", section:GetFullName()); return false
    end

    local char = Player.Character
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
    if hrp then
        hrp.CFrame = CFrame.lookAt(section.Position + section.CFrame.RightVector * 4, section.Position)
        hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
        task.wait(0.1)
    end

    local sizeY  = section.Size.Y
    local height = sizeY * math.clamp(0.1 + (8 - sizeY) / 60, 0.1, 0.2)
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

    for _ = 1, CHOP_FIRES do
        if not section.Parent then break end
        if stopFn and stopFn() then break end
        RemoteProxy:FireServer(cutEvent, args)
        task.wait(CHOP_FIRE_DELAY)
    end

    return true
end

-- ============================================================
-- LAVA HELPERS
-- ============================================================

local function GetAllLavaTouchParts()
    local parts = {}
    local volcano = workspace:FindFirstChild("Region_Volcano")
    if not volcano then
        DebugLog("warn", "[ModTree] Region_Volcano not found.")
        return parts
    end
    for _, child in ipairs(volcano:GetChildren()) do
        for _, desc in ipairs(child:GetDescendants()) do
            if desc:IsA("BasePart")
            and (desc:FindFirstChildOfClass("TouchTransmitter") or desc:FindFirstChild("TouchInterest")) then
                table.insert(parts, desc)
            end
        end
    end
    return parts
end

-- ============================================================
-- LOT HELPERS
-- ============================================================

local function SafeTeleportMany(batch)
    if _LOT.IsBusy() then _LOT.WaitForBatch() end
    _LOT.TeleportMany(batch)
    if _LOT.IsBusy() then _LOT.WaitForBatch() end
end

-- ============================================================
-- SINGLE TREE MOD
-- ============================================================

local function RunSingleTreeMod(aliveRef, sawmill, sawmillCF, treeModel, treeIndex, treeTotal)
    local session = {
        touchParts   = nil,
        touchSizes   = nil,
        touchCFs     = nil,
        lavaRestored = false,
    }

    local finished = false

    local function RestoreLava()
        if session.lavaRestored then return end
        session.lavaRestored = true
        if session.touchParts then
            for i, tp in ipairs(session.touchParts) do
                pcall(function()
                    if tp and tp.Parent then
                        tp.Size   = session.touchSizes[i]
                        tp.CFrame = session.touchCFs[i]
                    end
                end)
            end
        end
    end

    local function Cancelled()
        return (not aliveRef[1]) or (not _isModding)
    end

    local function Sleep(duration)
        local deadline = tick() + duration
        while tick() < deadline do
            if Cancelled() then return false end
            task.wait()
        end
        return not Cancelled()
    end

    local function Bail(title, text)
        if not finished then
            finished = true
            RestoreLava()
            if title then Notify(title, text) end
        end
        return false
    end

    local prefix = ("[%d/%d]"):format(treeIndex, treeTotal)

    -- ── Analyse tree ─────────────────────────────────────────
    DebugLog("print", ("[ModTree] %s Analysing tree: %s"):format(prefix, treeModel.Name))
    local analysis = AnalyzeTree(treeModel)

    if #analysis.all == 0 then
        return Bail("Mod Tree", prefix .. " No wood sections found.")
    end
    if not analysis.target then
        return Bail("Mod Tree", prefix .. " No weld-holding section found.")
    end

    local baseSection = nil
    for _, entry in ipairs(analysis.all) do
        if entry.id == 1 then baseSection = entry.part; break end
    end
    if not baseSection then baseSection = analysis.all[1].part end
    if not baseSection then
        return Bail("Mod Tree", prefix .. " Could not resolve base section.")
    end

    local treeClassObj = treeModel:FindFirstChild("TreeClass")
    local treeClass    = treeClassObj and treeClassObj.Value or nil

    local logModels  = workspace:FindFirstChild("LogModels")
    local beforeLogs = {}
    if logModels then
        for _, m in ipairs(logModels:GetChildren()) do beforeLogs[m] = true end
    end

    local function GetOurNewLogModels()
        local result = {}
        if logModels then
            for _, m in ipairs(logModels:GetChildren()) do
                if not beforeLogs[m] and m:IsA("Model") then
                    table.insert(result, m)
                end
            end
        end
        return result
    end

    local function FindSectionInScope(targetID)
        for _, entry in ipairs(analysis.all) do
            if entry.id == targetID and entry.part and entry.part.Parent then
                return entry.part
            end
        end
        for _, desc in ipairs(treeModel:GetDescendants()) do
            if desc:IsA("BasePart") then
                local idVal = desc:FindFirstChild("ID")
                if idVal and idVal.Value == targetID then return desc end
            end
        end
        for _, model in ipairs(GetOurNewLogModels()) do
            for _, desc in ipairs(model:GetDescendants()) do
                if desc:IsA("BasePart") then
                    local idVal = desc:FindFirstChild("ID")
                    if idVal and idVal.Value == targetID then return desc end
                end
            end
        end
        return nil
    end

    if Cancelled() then return Bail(nil, nil) end

    -- ── LOT to drop zone, then CFrame to mod zone ─────────────
    DebugLog("print", ("[ModTree] %s Teleporting tree to mod zone..."):format(prefix))
    local tpOk, tpErr = pcall(function()
        SafeTeleportMany({ { target = baseSection, goalCF = DROP_ZONE_CF } })
        baseSection.CFrame = MOD_TP_CF
    end)
    if not tpOk then
        return Bail("Mod Tree", prefix .. " Teleport failed: " .. tostring(tpErr))
    end
    if Cancelled() then return Bail(nil, nil) end

    -- ── Shrink lava touch parts ───────────────────────────────
    local touchParts = GetAllLavaTouchParts()
    if #touchParts == 0 then
        return Bail("Mod Tree", prefix .. " No lava touch parts found.")
    end
    DebugLog("print", ("[ModTree] %s Found %d lava touch part(s)."):format(prefix, #touchParts))

    local touchSizes, touchCFs = {}, {}
    for i, tp in ipairs(touchParts) do
        touchSizes[i] = tp.Size
        touchCFs[i]   = tp.CFrame
        pcall(function() tp.Size = Vector3.new(0.1, 0.1, 0.1) end)
    end
    session.touchParts = touchParts
    session.touchSizes = touchSizes
    session.touchCFs   = touchCFs

    -- ── Lock lava parts onto weld-holder ("Burning") ──────────
    local targetSection = analysis.target.part
    local tipID         = analysis.tipID
    DebugLog("print", ("[ModTree] %s Target ID=%d | Tip ID=%d"):format(prefix, analysis.target.id, tipID))

    local MAX_BURN_ATTEMPTS = 5
    local burnConfirmed     = false

    for attempt = 1, MAX_BURN_ATTEMPTS do
        if Cancelled() then break end

        if attempt > 1 then
            DebugLog("print", ("[ModTree] %s Retrying burn (%d/%d)."):format(prefix, attempt, MAX_BURN_ATTEMPTS))
            pcall(function() baseSection.CFrame = MOD_TP_CF end)
            if not Sleep(0.1) then break end
        end

        local lockConn = RunService.Heartbeat:Connect(function()
            pcall(function()
                local targetCF = targetSection.CFrame
                for _, tp in ipairs(touchParts) do
                    tp.Size   = Vector3.new(0.1, 0.1, 0.1)
                    tp.CFrame = targetCF
                end
            end)
        end)
        local lockOk = Sleep(0.1)
        lockConn:Disconnect()

        for i, tp in ipairs(touchParts) do
            pcall(function() tp.Size = touchSizes[i]; tp.CFrame = touchCFs[i] end)
        end

        if not lockOk then break end
        if not Sleep(0.1) then break end

        if treeModel:FindFirstChild("Burning") then
            DebugLog("print", ("[ModTree] %s Burning confirmed (attempt %d/%d)."):format(prefix, attempt, MAX_BURN_ATTEMPTS))
            burnConfirmed = true
            break
        end

        DebugLog("warn", ("[ModTree] %s Burning not detected (attempt %d/%d)."):format(prefix, attempt, MAX_BURN_ATTEMPTS))
    end

    RestoreLava()

    if Cancelled() then return Bail(nil, nil) end
    if not burnConfirmed then
        return Bail("Mod Tree", prefix .. " Could not confirm the tree is burning.")
    end

    -- ── Reposition sections ───────────────────────────────────
    DebugLog("print", ("[ModTree] %s Repositioning sections."):format(prefix))
    local tipSection = FindSectionInScope(tipID)
    pcall(function() targetSection.CFrame = CFrame.new(1279, 52, 2328) end)
    pcall(function() baseSection.CFrame = DROP_ZONE_CF end)

    if tipSection and tipSection.Parent then
        local halfHeight = tipSection.Size.Y / 2
        local adjustedCF = sawmillCF * CFrame.new(0, 0, 0)
        pcall(function() tipSection.CFrame = adjustedCF end)
        DebugLog("print", ("[ModTree] %s Tip (ID=%d) placed at sawmill (height offset %.2f)."):format(prefix, tipID, halfHeight))
        if not Sleep(1) then return Bail(nil, nil) end
    else
        DebugLog("warn", ("[ModTree] %s Tip (ID=%d) not available at burn time."):format(prefix, tipID))
    end

    -- ── Wait for weld-holder to be destroyed ──────────────────
    DebugLog("print", ("[ModTree] %s Waiting for weld-holder removal..."):format(prefix))
    local disappearDeadline = tick() + DISAPPEAR_TIMEOUT
    while tick() < disappearDeadline do
        if Cancelled() then return Bail(nil, nil) end
        if not targetSection or not targetSection.Parent then break end
        task.wait(0.1)
    end
    if targetSection and targetSection.Parent then
        DebugLog("warn", ("[ModTree] %s Weld-holder did not disappear in time — proceeding."):format(prefix))
    else
        DebugLog("print", ("[ModTree] %s Weld-holder removed."):format(prefix))
    end

    -- ── Chop the stump section ────────────────────────────────
    DebugLog("print", ("[ModTree] %s Chopping stump..."):format(prefix))

    local stumpID      = analysis.stump and analysis.stump.id or 1
    local stumpSection = FindSectionInScope(stumpID)

    local tool, axeName = GetBestAxe(treeClass)
    if not tool then
        DebugLog("warn", ("[ModTree] %s No axe found — skipping stump chop."):format(prefix))
        Notify("Mod Tree", prefix .. " No axe found — equip one to chop the stump.")
    else
        DebugLog("print", ("[ModTree] %s Using '%s' (treeClass=%s)."):format(prefix, axeName, tostring(treeClass)))

        local initialSize = stumpSection and stumpSection.Size
                         or Vector3.new(math.huge, math.huge, math.huge)

        local function TreeHasFallen()
            if not stumpSection or not stumpSection.Parent then return true end
            return stumpSection.Size.Y < initialSize.Y - 1
        end

        local chopDone     = false
        local chopDeadline = tick() + CHOP_CONFIRM_TIMEOUT

        while not chopDone and tick() < chopDeadline do
            if Cancelled() then return Bail(nil, nil) end
            if not stumpSection or not stumpSection.Parent then
                stumpSection = FindSectionInScope(stumpID)
                if stumpSection then initialSize = stumpSection.Size end
            end
            if not stumpSection or not stumpSection.Parent then
                DebugLog("warn", ("[ModTree] %s Stump section lost — aborting chop."):format(prefix)); break
            end
            FireCutSection(stumpSection, tool, axeName, treeClass,
                function() return Cancelled() or TreeHasFallen() end)
            chopDone = TreeHasFallen()
        end

        if Cancelled() then return Bail(nil, nil) end

        if chopDone then
            DebugLog("print", ("[ModTree] %s Chop confirmed."):format(prefix))
        else
            DebugLog("warn", ("[ModTree] %s Chop timed out — proceeding anyway."):format(prefix))
        end
    end

    -- ── Success ───────────────────────────────────────────────
    if Cancelled() then return Bail(nil, nil) end
    DebugLog("print", ("[ModTree] %s Done."):format(prefix))
    finished = true
    return true
end

-- ============================================================
-- MAIN MOD LOOP
-- ============================================================

local function RunModLoop(onDone)
    _modAliveRef = { true }
    local aliveRef = _modAliveRef

    _isModding = true

    local char0    = Player.Character
    local root0    = char0 and char0:FindFirstChild("HumanoidRootPart")
    local preModCF = root0 and root0.CFrame

    local finished = false

    local function ReturnPlayer(cf)
        if not cf then return end
        local ch  = Player.Character
        local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
        if hrp then
            pcall(function()
                hrp.CFrame = cf
                hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
            end)
        end
    end

    local function Finish(notifyTitle, notifyText, returnCF)
        if finished then return end
        finished = true
        ReturnPlayer(returnCF or preModCF)
        if notifyTitle then Notify(notifyTitle, notifyText) end
        _isModding      = false
        _currentSession = nil
        if onDone then onDone() end
    end

    local function Cancelled()
        return (not aliveRef[1]) or (not _isModding)
    end

    local function FinishCancel()
        DebugLog("print", "[ModTree] Cancelled — returning player.")
        Finish(nil, nil, preModCF)
    end

    local function FinishError(msg)
        DebugLog("warn", "[ModTree] " .. msg)
        Finish("Mod Tree", "Failed: " .. msg, preModCF)
    end

    -- ── Preflight ─────────────────────────────────────────────
    if not _LOT    then return FinishError("LOT teleport module is not available.") end
    if not _G.LT2Axes then return FinishError("LT2Axes is not loaded.") end

    -- ── Step 1: collect tree queue; sawmill click ends selection ─
    NotifyDebug("Mod Tree", "Click trees to queue them, then click your sawmill to start.")

    local treeQueue, sawmill = WaitForTreeQueueThenSawmill(aliveRef)

    if Cancelled() then return FinishCancel() end
    if not sawmill then return FinishError("No sawmill was selected.") end
    if #treeQueue == 0 then return FinishError("No trees were selected.") end

    DebugLog("print", ("[ModTree] %d tree(s) queued. Sawmill: %s"):format(#treeQueue, sawmill.Name))

    -- Resolve sawmill CF once, shared across all trees.
    local sawmillParticles = sawmill:FindFirstChild("Particles", true)
    local sawmillCF
    if sawmillParticles and sawmillParticles:IsA("BasePart") then
        sawmillCF = sawmillParticles.CFrame
    else
        DebugLog("warn", "[ModTree] Particles part not found — using bounding box.")
        sawmillCF = select(1, sawmill:GetBoundingBox())
    end

    local function SawmillStandCF()
        return sawmillCF * CFrame.new(0, 8, 6)
    end

    NotifyDebug("Mod Tree", ("Processing %d tree(s)..."):format(#treeQueue))

    -- ── Step 2: process each tree in order ───────────────────
    local successCount = 0
    for i, treeModel in ipairs(treeQueue) do
        if Cancelled() then return FinishCancel() end

        DebugLog("print", ("[ModTree] Starting tree %d/%d: %s"):format(i, #treeQueue, treeModel.Name))
        Notify("Mod Tree", ("Tree %d/%d — modding %s"):format(i, #treeQueue, treeModel.Name))

        local ok = RunSingleTreeMod(aliveRef, sawmill, sawmillCF, treeModel, i, #treeQueue)

        if Cancelled() then return FinishCancel() end

        if ok then
            successCount = successCount + 1
            DebugLog("print", ("[ModTree] Tree %d/%d succeeded."):format(i, #treeQueue))
        else
            DebugLog("warn", ("[ModTree] Tree %d/%d failed/skipped."):format(i, #treeQueue))
        end

        -- Brief pause between trees so the game can settle.
        if i < #treeQueue then task.wait(1) end
    end

    -- ── Step 3: final summary ─────────────────────────────────
    local summary = ("Done! %d/%d tree(s) modded."):format(successCount, #treeQueue)
    DebugLog("print", "[ModTree] " .. summary)
    Finish("Mod Tree", summary, SawmillStandCF())
end

-- ============================================================
-- MODULE INIT
-- ============================================================

function ModTreeModule.Init(Tab, lot, lib)
    if lot ~= nil then _LOT = lot end
    if lib ~= nil then _Lib = lib end

    Tab:CreateSection("Mod Tree Options")

    -- ── Mod Sawmill button ──────────────────────────────────
    local ModSawmillBtn

    local function SetSawmillState(active)
        if ModSawmillBtn then
            ModSawmillBtn:SetText(active and "Cancel" or "Sawmill")
        end
    end

    ModSawmillBtn = Tab:CreateAction("Mod Sawmill", "Sawmill", function()
        if _isModSawmill then
            _isModSawmill       = false
            _sawmillAliveRef[1] = false
            SetSawmillState(false)
            DebugLog("print", "[ModTree] Mod Sawmill cancelled.")
            return
        end

        _isModSawmill = true
        SetSawmillState(true)

        task.spawn(function()
            _sawmillAliveRef = { true }
            local aliveRef = _sawmillAliveRef

            local function done()
                _isModSawmill = false
                SetSawmillState(false)
            end

            NotifyDebug("Mod Sawmill", "Click your sawmill.")

            local sawmill = WaitForSawmillClick(aliveRef)
            if not aliveRef[1] then return end

            if not sawmill then
                Notify("Mod Sawmill", "No sawmill selected.")
                return done()
            end

            local ok, placed = pcall(function() return PlaceBlueprintAtSawmill(sawmill) end)
            if ok then
                if placed then
                    Notify("Mod Sawmill", "Fill the blueprint!")
                else
                    Notify("Mod Sawmill", "Blueprint already placed — fill it if you haven't!")
                end
            else
                DebugLog("warn", "[ModTree] Mod Sawmill failed: " .. tostring(placed))
                Notify("Mod Sawmill", "Failed to place blueprint.")
            end

            done()
        end)
    end, false)

    ModSawmillBtn:AddTooltip(
        "Places a Floor2 blueprint at your sawmill's output end.\n" ..
        "Run this BEFORE modding a tree.\n" ..
        "After placement, fill the blueprint with wood planks\n" ..
        "so the modded log lands on a full surface."
    )

    -- ── Mod Tree button ─────────────────────────────────────
    local ModBtn

    local function SetState(modding)
        if ModBtn then ModBtn:SetText(modding and "Cancel" or "Tree") end
    end

    ModBtn = Tab:CreateAction("Mod Tree", "Tree", function()
        if _isModding then
            _isModding      = false
            _modAliveRef[1] = false
            SetState(false)
            DebugLog("print", "[ModTree] Cancel requested.")
            return
        end

        SetState(true)
        task.spawn(function() RunModLoop(function() SetState(false) end) end)
    end, false)

    ModBtn:AddTooltip(
        "Click trees to queue them, then click your sawmill to begin.\n" ..
        "Each tree is modded one at a time in order."
    )
end

return ModTreeModule