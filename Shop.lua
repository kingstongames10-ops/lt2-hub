-- [[ SHOP MODULE ]] --
-- Designed for Dynxe LT2 UI Engine

local ShopModule = {}

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui        = game:GetService("StarterGui")
local Player            = Players.LocalPlayer

-- ┌─────────────────────────────────────────────────────────────────┐
-- │                     LOT REFERENCE                               │
-- └─────────────────────────────────────────────────────────────────┘
local _LOT = nil

function ShopModule.SetLOT(lot)
    _LOT = lot
end

-- ┌─────────────────────────────────────────────────────────────────┐
-- │                  MODULE-LEVEL SHARED STATE                      │
-- │  _ShopItems   — item list loaded on Init, exposed via API.      │
-- │  _cachedFunds — last known balance, refreshed on a background   │
-- │                 poll so UI updates don't block on remotes.      │
-- └─────────────────────────────────────────────────────────────────┘
local _ShopItems   = nil
local _cachedFunds = nil

-- ============================================================
-- SETTINGS
-- ============================================================
-- Quick Purchase: if true and a purchase lands in under 1 second,
-- the return TP skips LOT and directly sets the item's CFrame.
-- This is faster but may cause failures if the server hasn't fully
-- handed off ownership yet. Toggle via the Settings UI section.
local _quickPurchase = false

-- Force Respawn on Stuck NPC: enables NuclearReset as the final escalation
-- step when HardResetNPC fails to free a pinned ChattingPlayer. Off by
-- default — toggle via the Settings UI section.
local _allowNuclearReset = false

-- ┌─────────────────────────────────────────────────────────────────┐
-- │                     NPC / REMOTE SETUP                          │
-- └─────────────────────────────────────────────────────────────────┘
local NPCs = {
    Thom    = workspace.Stores.WoodRUs.Thom,
    Corey   = workspace.Stores.FurnitureStore.Corey,
    Jenny   = workspace.Stores.CarStore.Jenny,
    Bob     = workspace.Stores.ShackShop.Bob,
    Timothy = workspace.Stores.FineArt.Timothy,
    Lincoln = workspace.Stores.LogicStore.Lincoln,
}

local Remote      = ReplicatedStorage.NPCDialog.PlayerChatted
local PromptChat  = ReplicatedStorage.NPCDialog.PromptChat
local Interact    = ReplicatedStorage.Interaction.ClientInteracted
local DragRemote  = ReplicatedStorage.Interaction:WaitForChild("ClientIsDragging")

-- ┌─────────────────────────────────────────────────────────────────┐
-- │                   PER-STORE CONFIGURATION                       │
-- └─────────────────────────────────────────────────────────────────┘
local StoreConfigs = {
    WoodRUs = {
        NPCName     = "Thom",
        PlayerBuyCF = CFrame.new(262.1, 3.2,  64.8),
    },
    FurnitureStore = {
        NPCName     = "Corey",
        PlayerBuyCF = CFrame.new(481.4, 3.2, -1712.5),
    },
    CarStore = {
        NPCName     = "Jenny",
        PlayerBuyCF = CFrame.new(524.9, 3.2, -1466.6),
    },
    ShackShop = {
        NPCName     = "Bob",
        PlayerBuyCF = CFrame.new(256.7, 8.4, -2546.7),
    },
    FineArt = {
        NPCName     = "Timothy",
        PlayerBuyCF = CFrame.new(5232.4, -166.0, 737.3),
    },
    LogicStore = {
        NPCName     = "Lincoln",
        PlayerBuyCF = CFrame.new(4598.4, 7.0, -778.4),
    },
}

-- ┌─────────────────────────────────────────────────────────────────┐
-- │              COUNTER-BASED ITEM DROP CF RESOLVER                │
-- └─────────────────────────────────────────────────────────────────┘
local CounterCache = {}

local function GetCounterPart(storeName)
    if CounterCache[storeName] ~= nil then
        return CounterCache[storeName] or nil
    end

    local config = StoreConfigs[storeName]
    if not config then CounterCache[storeName] = false; return nil end

    local npc   = NPCs[config.NPCName]
    local store = npc and npc.Parent
    if not store then CounterCache[storeName] = false; return nil end

    local counter = store:FindFirstChild("Counter")
    if not counter then CounterCache[storeName] = false; return nil end

    local part
    if counter:IsA("BasePart") then
        part = counter
    elseif counter:IsA("Model") then
        part = counter.PrimaryPart
        if not part then
            for _, desc in ipairs(counter:GetDescendants()) do
                if desc:IsA("BasePart") then part = desc; break end
            end
        end
    end

    CounterCache[storeName] = part or false
    return part or nil
end

local function ComputeDropCF(storeName, mainPart)
    local counterPart = GetCounterPart(storeName)
    if not counterPart then return nil end

    local up         = counterPart.CFrame.UpVector
    local surfaceTop = counterPart.Position + up * (counterPart.Size.Y / 2)
    local itemRise   = mainPart and (mainPart.Size.Y / 2) or 0
    return CFrame.new(surfaceTop + up * (itemRise + 0.05))
end

-- ┌─────────────────────────────────────────────────────────────────┐
-- │                       FUNDS REMOTE                              │
-- └─────────────────────────────────────────────────────────────────┘
local GetFundsRemote = nil

local function FindRemoteRecursive(root, name)
    for _, child in ipairs(root:GetDescendants()) do
        if child.Name == name and child:IsA("RemoteFunction") then
            return child
        end
    end
    return nil
end

local function FetchFunds()
    if not GetFundsRemote then
        GetFundsRemote = FindRemoteRecursive(ReplicatedStorage, "GetFunds")
        if not GetFundsRemote then return nil end
    end
    local ok, result = pcall(function()
        return GetFundsRemote:InvokeServer()
    end)
    if ok and type(result) == "number" then return result end
    return nil
end

-- ┌─────────────────────────────────────────────────────────────────┐
-- │                      NPC ID FETCHING                            │
-- └─────────────────────────────────────────────────────────────────┘
local NPCIDs = {}

local function FetchNPCID(npcName)
    local npc = NPCs[npcName]
    if not npc then return nil end

    if not npc:FindFirstChild("Dialog") then
        Instance.new("Dialog", npc)
    end

    local lastData
    local conn = PromptChat.OnClientEvent:Connect(function(active, chatData)
        -- CRITICAL: filter by NPC Character and only accept "open" events.
        -- The server's 1Hz proximity loop fires PromptChat for any nearby
        -- NPC. Without this filter, lastData can be set to a DIFFERENT
        -- NPC's data during our 5s wait — poisoning the ID cache and
        -- sending all future EndChats to the wrong NPC. That cached-wrong-ID
        -- state survives until rejoin.
        if active and chatData and chatData.Character == npc then
            lastData = chatData
        end
    end)

    pcall(function() PromptChat:FireServer(true, npc, npc.Dialog) end)
    local t = tick()
    repeat task.wait(0.05) until lastData or tick() - t > 5
    conn:Disconnect()

    pcall(function() PromptChat:FireServer(false, npc, npc.Dialog) end)
    task.wait(0.2)

    if lastData and lastData.Character == npc and lastData.ID then
        NPCIDs[npcName] = lastData.ID
        return lastData.ID
    end

    warn("[Shop] Failed to fetch ID for NPC:", npcName)
    return nil
end

local function EnsureNPCID(npcName)
    if NPCIDs[npcName] then return NPCIDs[npcName] end
    return FetchNPCID(npcName)
end

local function InvalidateNPCID(npcName)
    NPCIDs[npcName] = nil
end

local function FetchAllNPCIDs()
    for name, _ in pairs(NPCs) do
        if not NPCIDs[name] then
            FetchNPCID(name)
            task.wait(0.15)
        end
    end
end

-- ┌─────────────────────────────────────────────────────────────────┐
-- │          PROXIMITY-BASED CASHIER FINDER (fallback only)         │
-- └─────────────────────────────────────────────────────────────────┘
local function FindNearestCashierToItem(mainPart)
    if not mainPart then return nil, nil end
    local itemPos  = mainPart.Position
    local bestNPC, bestName, bestDist = nil, nil, math.huge

    for name, npc in pairs(NPCs) do
        local head = npc:FindFirstChild("Head")
        if head then
            local dist = (head.Position - itemPos).Magnitude
            if dist < bestDist then
                bestDist = dist
                bestNPC  = npc
                bestName = name
            end
        end
    end

    return bestNPC, bestName
end

-- ┌─────────────────────────────────────────────────────────────────┐
-- │                   NPC ARG BUILDER                               │
-- └─────────────────────────────────────────────────────────────────┘
local function BuildNPCArg(npcName, npc)
    if not npc then return nil end
    if not npc:FindFirstChild("Dialog") then
        Instance.new("Dialog", npc)
    end
    local id = EnsureNPCID(npcName)
    if not id then return nil end
    return {
        ID        = id,
        Character = npc,
        Name      = npcName,
        Dialog    = npc.Dialog,
    }
end

local function GetNPCArgForItem(storeName, mainPart)
    local config = StoreConfigs[storeName]
    if config then
        local npc = NPCs[config.NPCName]
        if npc then
            local arg = BuildNPCArg(config.NPCName, npc)
            if arg then return arg, config.NPCName end
        end
    end

    if mainPart then
        local proxNPC, proxName = FindNearestCashierToItem(mainPart)
        if proxNPC and proxName then
            local arg = BuildNPCArg(proxName, proxNPC)
            if arg then return arg, proxName end
        end
    end

    return nil, nil
end

-- ┌─────────────────────────────────────────────────────────────────┐
-- │               SAFE INVOKE — HARD TIMEOUT + CLEANUP              │
-- └─────────────────────────────────────────────────────────────────┘
-- Tunables for the remote-invoke lifecycle.
local INVOKE_TIMEOUT      = 4       -- per-call hard timeout (s)
local POST_TIMEOUT_SETTLE = 0.6     -- wait after timeout before cleanup EndChat
local CLEANUP_ENDCHATS    = 3       -- EndChats fired after a timeout
local CLEANUP_GAP         = 0.3     -- spacing between cleanup EndChats
local CLEANUP_CALL_BUDGET = 1.5     -- per-EndChat hard cap during cleanup

local _lastInvokeTimedOut = false

local function SafeInvoke(npcArg, action)
    local co       = coroutine.running()
    local done     = false
    local timedOut = false

    local fireThread = task.spawn(function()
        pcall(function()
            Remote:InvokeServer(npcArg, action)
        end)
        if not done then
            done = true
            task.spawn(co)
        end
    end)

    task.delay(INVOKE_TIMEOUT, function()
        if not done then
            done     = true
            timedOut = true
            pcall(task.cancel, fireThread)
            task.spawn(co)
        end
    end)

    coroutine.yield()
    _lastInvokeTimedOut = timedOut

    -- If we timed out on anything other than EndChat, the server is likely
    -- still processing our action. Wait for it to settle, then synchronously
    -- fire multiple EndChats so the late-arriving action gets cleared BEFORE
    -- the next iteration starts a new dialog. The async cleanup in the old
    -- version was the root of half the stuck-NPC cases.
    if timedOut and action ~= "EndChat" then
        task.wait(POST_TIMEOUT_SETTLE)
        for _ = 1, CLEANUP_ENDCHATS do
            local cleanupDone   = false
            local cleanupThread = task.spawn(function()
                pcall(function() Remote:InvokeServer(npcArg, "EndChat") end)
                cleanupDone = true
            end)
            local cleanupDeadline = tick() + CLEANUP_CALL_BUDGET
            while not cleanupDone and tick() < cleanupDeadline do
                task.wait(0.05)
            end
            if not cleanupDone then
                pcall(task.cancel, cleanupThread)
            end
            task.wait(CLEANUP_GAP)
        end
    end
end

-- Compat alias for any existing references
local SafeInvokeTracked = SafeInvoke

-- ┌─────────────────────────────────────────────────────────────────┐
-- │                     POWER OF EASE PURCHASE                      │
-- └─────────────────────────────────────────────────────────────────┘
local POE_PRICE    = 10009000
local POE_TP_CF    = CFrame.new(1059.4, 17.2, 1130.3)
local POE_TIMEOUT  = 60
local POE_INTERVAL = 0.2

local function PurchasePowerOfEase()
    local funds = FetchFunds()
    if funds == nil then return end
    if funds < POE_PRICE then return end

    FetchAllNPCIDs()

    local char = Player.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return end

    local returnCF = root.CFrame
    root.CFrame = POE_TP_CF
    task.wait(0.15)

    local bestDist = math.huge
    local bestNPC, bestName

    for name, npc in pairs(NPCs) do
        local store = npc.Parent
        if store and store:FindFirstChild("Counter") then
            local dist = (store.Counter.CFrame.p - root.Position).Magnitude
            if dist < bestDist then
                bestDist = dist
                bestNPC  = npc
                bestName = name
            end
        end
    end

    if not bestNPC then
        root.CFrame = returnCF
        return
    end

    if not bestNPC:FindFirstChild("Dialog") then
        Instance.new("Dialog", bestNPC)
    end

    local npcArg = BuildNPCArg(bestName, bestNPC)
    if not npcArg then
        root.CFrame = returnCF
        return
    end

    local deadline = tick() + POE_TIMEOUT

    while tick() < deadline do
        SafeInvoke(npcArg, "Initiate")
        SafeInvoke(npcArg, "ConfirmPurchase")
        SafeInvoke(npcArg, "EndChat")

        local newFunds = FetchFunds()
        if newFunds and newFunds < funds then break end

        task.wait(POE_INTERVAL)
    end

    task.wait(0.1)
    local returnChar = Player.Character
    local returnRoot = returnChar and returnChar:FindFirstChild("HumanoidRootPart")
    if returnRoot then returnRoot.CFrame = returnCF end
end

-- ┌─────────────────────────────────────────────────────────────────┐
-- │                       PURCHASE SEQUENCE                         │
-- └─────────────────────────────────────────────────────────────────┘
local SPAM_TIMEOUT       = 30
local CYCLE_GAP          = 0.1      -- widened from 0.05 — less server pressure
local INNER_DEADLINE     = 3        -- per-Initiate confirm-spam window
local FAIL_BACKOFF_AFTER = 8
local FAIL_BACKOFF_WAIT  = 0.6
local ID_REFETCH_AFTER   = 16

-- Per-NPC recovery
local NPC_FAIL_THRESHOLD  = 3       -- DoPurchase failures before HardResetNPC
local NPC_NUCLEAR_AFTER   = 2       -- HardResetNPCs before forced respawn (if enabled)
local _npcFailStreak      = {}
local _npcResetStreak     = {}

local function IsSuccessParent(parent)
    if not parent then return false end
    if parent.Name == "PlayerModels" then return true end
    if parent == Player.Backpack     then return true end
    if parent == Player.Character    then return true end
    local current = parent
    while current do
        if current.Name == "PlayerModels" then return true end
        current = current.Parent
    end
    return false
end

local function CheckItemState(mainPart)
    if not mainPart then return "gone" end
    local parent = mainPart.Parent
    if IsSuccessParent(parent) then return "success" end
    if parent == nil then
        task.wait(0.12)
        local newParent = mainPart.Parent
        if IsSuccessParent(newParent) then return "success" end
        if newParent == nil             then return "gone"    end
    end
    return "pending"
end

local function FlushDialog(npcArg, count)
    count = count or 2
    for _ = 1, count do
        SafeInvoke(npcArg, "EndChat")
        task.wait(0.05)
    end
end

local function SpamPurchase(mainPart, npcArg, itemName, npcName)
    local startTime = tick()
    local deadline  = tick() + SPAM_TIMEOUT

    while tick() < deadline do
        local state = CheckItemState(mainPart)
        if state == "success" then return true,  tick() - startTime end
        if state == "gone"    then return false, tick() - startTime end

        -- Open a fresh dialog session
        SafeInvoke(npcArg, "Initiate")
        if _lastInvokeTimedOut then
            -- SafeInvoke already did the synchronous cleanup. Refresh ID
            -- (it might be stale; filter in FetchNPCID prevents poisoning)
            -- and retry the outer loop.
            InvalidateNPCID(npcName)
            local newID = FetchNPCID(npcName)
            if newID then npcArg.ID = newID end
            task.wait(0.2)
            continue
        end

        -- Recheck immediately — Initiate alone can sometimes finalize state
        state = CheckItemState(mainPart)
        if state == "success" then SafeInvoke(npcArg, "EndChat"); return true,  tick() - startTime end
        if state == "gone"    then SafeInvoke(npcArg, "EndChat"); return false, tick() - startTime end

        -- Fire ConfirmPurchase tightly until state changes or window expires
        local innerDeadline = tick() + INNER_DEADLINE
        while tick() < innerDeadline do
            state = CheckItemState(mainPart)
            if state == "success" then
                SafeInvoke(npcArg, "EndChat")
                return true, tick() - startTime
            end
            if state == "gone" then
                SafeInvoke(npcArg, "EndChat")
                return false, tick() - startTime
            end

            SafeInvoke(npcArg, "ConfirmPurchase")

            -- If ConfirmPurchase timed out, cleanup already fired. Bail
            -- out of the inner loop and let the outer loop restart cleanly.
            if _lastInvokeTimedOut then break end

            task.wait(CYCLE_GAP)
        end

        -- Inner loop expired — close session and retry from Initiate
        SafeInvoke(npcArg, "EndChat")
        task.wait(0.2)
    end

    SafeInvoke(npcArg, "EndChat")
    return false, tick() - startTime
end

-- ┌─────────────────────────────────────────────────────────────────┐
-- │                      PURCHASE PART                              │
-- └─────────────────────────────────────────────────────────────────┘
local function PositionForPurchase(mainPart, item, pressedCF)
    local storeName = item.Store
    local config    = StoreConfigs[storeName]
    if not config then return nil, nil end

    local dropCF = ComputeDropCF(storeName, mainPart)
    if not dropCF then return nil, nil end

    local success = _LOT.TeleportMany({ { target = mainPart, goalCF = dropCF } })
    if _LOT.IsBusy() then success = _LOT.WaitForBatch() end
    if not success then return nil, nil end

    local char = Player.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return nil, nil end

    root.CFrame = config.PlayerBuyCF

    local npcArg, resolvedNPCName = GetNPCArgForItem(storeName, mainPart)
    if not npcArg or not npcArg.ID then return nil, nil end

    return npcArg, resolvedNPCName
end

local function DoPurchase(mainPart, item, npcArg, resolvedNPCName, pressedCF)
    local purchased, elapsed = SpamPurchase(mainPart, npcArg, item.Name, resolvedNPCName)

    if purchased then
        if mainPart and mainPart.Parent then
            -- Quick Purchase: if enabled and the item was bought in under 1 second,
            -- skip the LOT ownership pipeline and set CFrame directly.
            -- The item is freshly parented to PlayerModels so the client has
            -- network ownership — a direct CFrame is authoritative and faster.
            -- May cause failures on slow servers where ownership hasn't fully
            -- transferred; toggle off if items slingshot or disappear.
            if _quickPurchase and elapsed < 1 then
                mainPart.CFrame                   = pressedCF
                mainPart.AssemblyLinearVelocity   = Vector3.new()
                mainPart.AssemblyAngularVelocity  = Vector3.new()
            else
                _LOT.TeleportMany({ { target = mainPart, goalCF = pressedCF } })
            end
        end
        local returnChar = Player.Character
        local returnRoot = returnChar and returnChar:FindFirstChild("HumanoidRootPart")
        if returnRoot then
            returnRoot.CFrame = pressedCF * CFrame.new(0, 0, 3)
        end
    end

    return purchased
end

-- ┌─────────────────────────────────────────────────────────────────┐
-- │                     REMOTE ITEM LIST LOADER                     │
-- └─────────────────────────────────────────────────────────────────┘
local function LoadItemList()
    local lm = _G.LoadModule or getgenv().LoadModule
    if type(lm) ~= "function" then
        warn("[Shop] LoadModule not available")
        return nil
    end

    local storeMap = lm("LT2ItemList")
    if not storeMap then return nil end

    local ClientItemInfo = ReplicatedStorage:FindFirstChild("ClientItemInfo")
    if not ClientItemInfo then
        warn("[Shop] ClientItemInfo not found in ReplicatedStorage")
        return nil
    end

    local items = {}
    for _, entry in ipairs(storeMap) do
        local ok, err = pcall(function()
            local folder = ClientItemInfo:FindFirstChild(entry.BoxItemName)
            if not folder then return end

            local nameVal  = folder:FindFirstChild("ItemName")
            local imageVal = folder:FindFirstChild("ItemImage")
            local priceVal = folder:FindFirstChild("Price")

            if not (nameVal and imageVal and priceVal) then
                warn("[Shop] Incomplete ClientItemInfo for:", entry.BoxItemName)
                return
            end

            local price = (function()
                local raw = priceVal.Value
                if type(raw) == "number" then return raw end
                return tonumber(tostring(raw):gsub("[^%d]", "")) or 0
            end)()

            table.insert(items, {
                Name        = nameVal.Value,
                Image       = imageVal.Value,
                Price       = price,
                BoxItemName = entry.BoxItemName,
                Store       = entry.Store,
                IsBlueprint = entry.IsBlueprint == true,
            })
        end)
        if not ok then
            warn("[Shop] Failed to load entry:", entry.BoxItemName, "|", err)
        end
    end

    return #items > 0 and items or nil
end

-- ┌─────────────────────────────────────────────────────────────────┐
-- │                   SHOPITEMS ↔ STORE MATCHER                     │
-- └─────────────────────────────────────────────────────────────────┘
local ShopItemsCache = {}

local function GetShopItemsForStore(storeName)
    if ShopItemsCache[storeName] ~= nil then
        return ShopItemsCache[storeName] or nil
    end

    local config = StoreConfigs[storeName]
    if not config then
        ShopItemsCache[storeName] = false
        return nil
    end

    local npc   = NPCs[config.NPCName]
    local store = npc and npc.Parent
    local anchor

    if store and store:FindFirstChild("Counter") then
        anchor = store.Counter.CFrame.p
    elseif store and store:IsA("Model") then
        local ok, piv = pcall(function() return store:GetPivot().Position end)
        if ok then anchor = piv end
    end

    if not anchor then
        ShopItemsCache[storeName] = false
        return nil
    end

    local stores = workspace:FindFirstChild("Stores")
    if not stores then
        ShopItemsCache[storeName] = false
        return nil
    end

    local bestContainer, bestDist = nil, math.huge

    for _, child in ipairs(stores:GetChildren()) do
        if child.Name ~= "ShopItems" then continue end

        local samplePos
        for _, desc in ipairs(child:GetDescendants()) do
            if desc:IsA("BasePart") then
                samplePos = desc.Position
                break
            end
        end

        if samplePos then
            local dist = (samplePos - anchor).Magnitude
            if dist < bestDist then
                bestDist      = dist
                bestContainer = child
            end
        end
    end

    ShopItemsCache[storeName] = bestContainer or false
    return bestContainer
end

-- ┌─────────────────────────────────────────────────────────────────┐
-- │                      WORLD PATH RESOLVER                        │
-- └─────────────────────────────────────────────────────────────────┘
local function ResolveItemParts(item, limit)
    local stores = workspace:FindFirstChild("Stores")
    if not stores then return {} end

    local results = {}

    local function searchContainer(shopItems)
        for _, box in ipairs(shopItems:GetChildren()) do
            if #results >= limit then break end
            if not (box:IsA("Model") and box.Name == "Box") then continue end

            local nameVal = box:FindFirstChild("BoxItemName")
            if not (nameVal and nameVal:IsA("StringValue")) then continue end
            if nameVal.Value ~= item.BoxItemName then continue end

            local main = box:FindFirstChild("Main")
            if main and main:IsA("BasePart") and not main.Anchored then
                table.insert(results, main)
            end
        end
    end

    local storeName = item.Store
    if storeName then
        local targetContainer = GetShopItemsForStore(storeName)
        if targetContainer then
            searchContainer(targetContainer)
            return results
        end
    end

    for _, child in ipairs(stores:GetChildren()) do
        if #results >= limit then break end
        if child.Name ~= "ShopItems" then continue end
        searchContainer(child)
    end

    return results
end

-- ┌─────────────────────────────────────────────────────────────────┐
-- │              RECOVERY — STUCK NPC ESCALATION                    │
-- └─────────────────────────────────────────────────────────────────┘
local function HardResetNPC(npcArg, npcName)
    warn("[Shop] HardResetNPC for", npcName)

    -- Step out of proximity briefly. Two reasons:
    --   1) Gets us out of the server's 1Hz prompt-fire window for this NPC,
    --      cleaning up the OnClientEvent stream before we refetch the ID.
    --   2) Defensive — if server chat state ties to proximity in any way
    --      not visible in the script, this gives that a chance to act.
    local char    = Player.Character
    local root    = char and char:FindFirstChild("HumanoidRootPart")
    local savedCF = root and root.CFrame
    if root then
        root.CFrame = root.CFrame * CFrame.new(0, 0, 40)
        task.wait(1.0)
    end

    -- Re-fetch the NPC ID from scratch (with the filtered FetchNPCID)
    InvalidateNPCID(npcName)
    local newID = FetchNPCID(npcName)
    if newID then npcArg.ID = newID end

    -- Spam EndChat to clear any pinned server-side dialog state
    for _ = 1, 5 do
        local d = false
        local t = task.spawn(function()
            pcall(function() Remote:InvokeServer(npcArg, "EndChat") end)
            d = true
        end)
        local deadline = tick() + CLEANUP_CALL_BUDGET
        while not d and tick() < deadline do task.wait(0.05) end
        if not d then pcall(task.cancel, t) end
        task.wait(0.3)
    end

    -- Restore position
    local rc = Player.Character
    local rr = rc and rc:FindFirstChild("HumanoidRootPart")
    if rr and savedCF then
        rr.CFrame = savedCF
        task.wait(0.3)
    end
end

local function NuclearReset()
    warn("[Shop] NuclearReset — forcing character respawn to free pinned ChattingPlayer")
    local char = Player.Character
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    if hum then hum.Health = 0 end

    local deadline = tick() + 10
    repeat
        task.wait(0.2)
    until (Player.Character
           and Player.Character:FindFirstChild("HumanoidRootPart"))
       or tick() > deadline
    task.wait(0.5)
end

-- ┌─────────────────────────────────────────────────────────────────┐
-- │                    RESTOCK-AWARE BUY LOOP                       │
-- └─────────────────────────────────────────────────────────────────┘
local RESTOCK_POLL_RATE = 0.5
local RESTOCK_TIMEOUT   = 120

local _isBuying = false

local function RunBuyLoop(item, totalQty, pressedCF, onDone)
    _isBuying = true
    FetchAllNPCIDs()

    local bought       = 0
    local restockTimer = 0

    while bought < totalQty and _isBuying do
        local stillNeed = totalQty - bought
        local parts     = ResolveItemParts(item, stillNeed)

        if #parts == 0 then
            task.wait(RESTOCK_POLL_RATE)
            restockTimer += RESTOCK_POLL_RATE
            if restockTimer >= RESTOCK_TIMEOUT then break end
            continue
        end

        restockTimer = 0

        for _, mainPart in ipairs(parts) do
            if not _isBuying      then break end
            if bought >= totalQty then break end
            if not mainPart or not mainPart.Parent then continue end
            if _LOT.IsBusy() then _LOT.WaitForBatch() end

            local npcArg, resolvedNPCName = PositionForPurchase(mainPart, item, pressedCF)
            if not npcArg then continue end

            local ok     = false
            local giveUp = tick() + 90

            while not ok and _isBuying and tick() < giveUp do
                if not mainPart or not mainPart.Parent then break end

                ok = DoPurchase(mainPart, item, npcArg, resolvedNPCName, pressedCF)

                if ok then
                    -- Success — clear failure tracking for this NPC
                    _npcFailStreak[resolvedNPCName]  = 0
                    _npcResetStreak[resolvedNPCName] = 0
                else
                    _npcFailStreak[resolvedNPCName] =
                        (_npcFailStreak[resolvedNPCName] or 0) + 1

                    if _npcFailStreak[resolvedNPCName] >= NPC_FAIL_THRESHOLD then
                        _npcFailStreak[resolvedNPCName]  = 0
                        _npcResetStreak[resolvedNPCName] =
                            (_npcResetStreak[resolvedNPCName] or 0) + 1

                        if _allowNuclearReset
                           and _npcResetStreak[resolvedNPCName] >= NPC_NUCLEAR_AFTER then
                            _npcResetStreak[resolvedNPCName] = 0
                            NuclearReset()
                            FetchAllNPCIDs()
                            -- Re-position at counter after respawn
                            npcArg, resolvedNPCName =
                                PositionForPurchase(mainPart, item, pressedCF)
                            if not npcArg then break end
                        else
                            HardResetNPC(npcArg, resolvedNPCName)
                            -- HardResetNPC restores position; re-pin at counter
                            local rChar = Player.Character
                            local rRoot = rChar and rChar:FindFirstChild("HumanoidRootPart")
                            local cfg   = StoreConfigs[item.Store]
                            if rRoot and cfg then
                                rRoot.CFrame = cfg.PlayerBuyCF
                                task.wait(0.15)
                            end
                        end
                    else
                        task.wait(0.3)
                    end
                end
            end

            if ok then bought += 1 end
        end
    end

    _isBuying = false
    if onDone then onDone() end
end

-- ┌─────────────────────────────────────────────────────────────────┐
-- │              BLUEPRINT — PURCHASE WITHOUT ITEM TP               │
-- └─────────────────────────────────────────────────────────────────┘
local function PurchaseBlueprintPart(mainPart, item)
    local npcArg, resolvedNPCName = PositionForPurchase(mainPart, item, nil)
    if not npcArg then return false end
    local purchased, _ = SpamPurchase(mainPart, npcArg, item.Name, resolvedNPCName)
    return purchased
end

-- ┌─────────────────────────────────────────────────────────────────┐
-- │              BLUEPRINT — OPEN BOX FROM PLAYERMODELS             │
-- └─────────────────────────────────────────────────────────────────┘
local BOX_OPEN_TIMEOUT = 10

local function OpenBlueprintBox(boxItemName)
    local PlayerModels = workspace:FindFirstChild("PlayerModels")
    if not PlayerModels then return false end

    local deadline = tick() + BOX_OPEN_TIMEOUT

    while tick() < deadline do
        for _, model in ipairs(PlayerModels:GetChildren()) do
            if model:IsA("Model") and model.Name:find("Box Purchased by") then
                local nameVal = model:FindFirstChild("PurchasedBoxItemName")
                if nameVal and nameVal.Value == boxItemName then
                    local char = Player.Character
                    local head = char and char:FindFirstChild("Head")
                    if head then
                        Interact:FireServer(model, "Open box", head.CFrame)
                        task.wait(0.5)
                        return true
                    end
                end
            end
        end
        task.wait(0.2)
    end

    warn("[Blueprints] Timed out waiting for box:", boxItemName)
    return false
end

-- ┌─────────────────────────────────────────────────────────────────┐
-- │                   PURCHASE ALL BLUEPRINTS                       │
-- └─────────────────────────────────────────────────────────────────┘
local _isBuyingBlueprints = false

local function RunBlueprintLoop(ShopItems, onDone)
    _isBuyingBlueprints = true

    FetchAllNPCIDs()

    local char     = Player.Character
    local root     = char and char:FindFirstChild("HumanoidRootPart")
    local returnCF = root and root.CFrame

    local blueprints = {}
    for _, item in ipairs(ShopItems) do
        if item.IsBlueprint then
            table.insert(blueprints, item)
        end
    end

    if #blueprints == 0 then
        warn("[Blueprints] No blueprint items found in item list.")
        _isBuyingBlueprints = false
        if onDone then onDone() end
        return
    end

    print("[Blueprints] Found " .. #blueprints .. " blueprints to purchase.")

    for _, item in ipairs(blueprints) do
        if not _isBuyingBlueprints then break end

        local parts = ResolveItemParts(item, 1)
        if #parts == 0 then
            warn("[Blueprints] No stock found for:", item.Name, "— skipping.")
            continue
        end

        local mainPart = parts[1]
        if not mainPart or not mainPart.Parent then
            warn("[Blueprints] mainPart gone for:", item.Name, "— skipping.")
            continue
        end

        local blueprintsFolder = Player:FindFirstChild("PlayerBlueprints")
            and Player.PlayerBlueprints:FindFirstChild("Blueprints")
        if blueprintsFolder and blueprintsFolder:FindFirstChild(item.BoxItemName) then
            print("[Blueprints] Already owned, skipping:", item.Name)
            continue
        end

        local funds = FetchFunds()
        if funds == nil or funds < item.Price then
            warn("[Blueprints] Not enough funds for:", item.Name, "(need $" .. item.Price .. ")")
            continue
        end

        print("[Blueprints] Purchasing:", item.Name)
        local purchased = PurchaseBlueprintPart(mainPart, item)

        if purchased then
            print("[Blueprints] Purchased! Opening box for:", item.Name)
            local boxName = item.BoxItemName or item.Name
            OpenBlueprintBox(boxName)
        else
            warn("[Blueprints] Failed to purchase:", item.Name)
        end

        task.wait(0.2)
    end

    local returnChar = Player.Character
    local returnRoot = returnChar and returnChar:FindFirstChild("HumanoidRootPart")
    if returnRoot and returnCF then
        returnRoot.CFrame = returnCF
    end

    print("[Blueprints] All done!")
    _isBuyingBlueprints = false
    if onDone then onDone() end
end

-- ┌─────────────────────────────────────────────────────────────────┐
-- │                         MODULE INIT                             │
-- └─────────────────────────────────────────────────────────────────┘
function ShopModule.Init(Tab, lot)
    if lot ~= nil then _LOT = lot end

    _ShopItems = LoadItemList()
    local ShopItems = _ShopItems

    if not ShopItems or #ShopItems == 0 then
        Tab:CreateSection("Hardware Store")
        return
    end

    local SelectedItem = ShopItems[1]
    local Quantity     = 1

    local PurchaseBtn

    local function RefreshFundsCache()
        task.spawn(function()
            local f = FetchFunds()
            if f ~= nil then _cachedFunds = f end
            if PurchaseBtn and SelectedItem and not _isBuying then
                local canAfford = _cachedFunds ~= nil and _cachedFunds >= SelectedItem.Price
                PurchaseBtn:SetDisabled(not canAfford)
            end
        end)
    end

    local function UpdateDisplay()
        if not SelectedItem or not PurchaseBtn then return end
        if _isBuying then return end
        local cost      = SelectedItem.Price * Quantity
        local canAfford = _cachedFunds ~= nil and _cachedFunds >= SelectedItem.Price
        PurchaseBtn:SetText(("$%d"):format(cost))
        PurchaseBtn:SetDisabled(not canAfford)
    end

    local function SetBuyingState(buying)
        if not PurchaseBtn then return end
        if buying then
            PurchaseBtn:SetText("Stop")
            PurchaseBtn:SetDisabled(false)
        else
            RefreshFundsCache()
            UpdateDisplay()
        end
    end

    -- ── Stores ──────────────────────────────────────────────────────
    Tab:CreateSection("Shop")

    local Catalog = Tab:CreateImageSelector("Select an Item", {
        MultiSelect = false,
        VisibleRows = 3,
        SlotSize    = UDim2.new(0, 73, 0, 73),
    }, function(name)
        for _, item in pairs(ShopItems) do
            if item.Name == name then
                SelectedItem = item
                break
            end
        end
        UpdateDisplay()
    end)

    local BlueprintSlotObjs = {}
    local SlotRefs = {}

    for _, item in ipairs(ShopItems) do
        pcall(function()
            local slotObj = Catalog:AddSlot("", item.Name, "$" .. tostring(item.Price))
            SlotRefs[item.Name] = { slotObj = slotObj, item = item }
            if item.IsBlueprint then
                BlueprintSlotObjs[item.Name] = slotObj
            end
        end)
    end

    task.spawn(function()
        for _, item in ipairs(ShopItems) do
            task.wait()
            pcall(function()
                if not item.Image or item.Image == "" then return end
                local ref = SlotRefs[item.Name]
                if not ref or not ref.slotObj.ImageLabel then return end
                ref.slotObj.ImageLabel.Image = item.Image
            end)
        end
    end)

    Tab:CreateSlider("Quantity", 1, 100, 1, function(val)
        Quantity = val
        UpdateDisplay()
    end)

    PurchaseBtn = Tab:CreateAction("Purchase", ("$%d"):format(ShopItems[1].Price), function()
        if _isBuying then
            _isBuying = false
            return
        end

        if not SelectedItem                       then return end
        if _LOT == nil                            then return end
        if not SelectedItem.Store                 then return end
        if not StoreConfigs[SelectedItem.Store]   then return end
        if _LOT.IsBusy()                          then return end

        local funds = FetchFunds()
        if funds == nil               then return end
        if funds < SelectedItem.Price then return end

        local totalCost = SelectedItem.Price * Quantity
        local targetQty = Quantity
        if funds < totalCost then
            targetQty = math.floor(funds / SelectedItem.Price)
        end

        local char      = Player.Character
        local root      = char and char:FindFirstChild("HumanoidRootPart")
        local pressedCF = root and root.CFrame

        SetBuyingState(true)

        task.spawn(function()
            RunBuyLoop(SelectedItem, targetQty, pressedCF, function()
                SetBuyingState(false)
            end)
        end)
    end, false)

    RefreshFundsCache()
    task.spawn(function()
        while true do
            task.wait(3)
            RefreshFundsCache()
        end
    end)

    UpdateDisplay()
    ShopModule.UpdateDisplay = UpdateDisplay

    -- ── Special ─────────────────────────────────────────────────────
    Tab:CreateSection("Special")

    Tab:CreateAction("Power of Ease ($10,009,000)", "Buy", function()
        task.spawn(PurchasePowerOfEase)
    end, false)

    local BlueprintItems = {}
    for _, item in ipairs(ShopItems) do
        if item.IsBlueprint then
            table.insert(BlueprintItems, item)
        end
    end

    local function CheckAllBlueprintsOwned()
        if #BlueprintItems == 0 then return false end
        local playerBP = Player:FindFirstChild("PlayerBlueprints")
        if not playerBP then return false end
        local blueprintsFolder = playerBP:FindFirstChild("Blueprints")
        if not blueprintsFolder then return false end
        local owned = 0
        for _, item in ipairs(BlueprintItems) do
            if blueprintsFolder:FindFirstChild(item.BoxItemName) then
                owned += 1
            end
        end
        return owned >= #BlueprintItems
    end

    local BlueprintBtn

    local function GetTotalBlueprintCost()
        local blueprintsFolder = Player:FindFirstChild("PlayerBlueprints")
            and Player.PlayerBlueprints:FindFirstChild("Blueprints")
        local total = 0
        for _, item in ipairs(BlueprintItems) do
            local owned = blueprintsFolder and blueprintsFolder:FindFirstChild(item.BoxItemName)
            if not owned then
                total += tonumber(item.Price) or 0
            end
        end
        return total
    end

    local function UpdateBlueprintBtnState()
        if not BlueprintBtn then return end
        if _isBuyingBlueprints then return end
        local allOwned = CheckAllBlueprintsOwned()
        BlueprintBtn:SetDisabled(allOwned)
        if allOwned then
            BlueprintBtn:SetText("All Owned")
        else
            local total = GetTotalBlueprintCost()
            if total > 0 then
                BlueprintBtn:SetText("$" .. tostring(total))
            else
                BlueprintBtn:SetText(#BlueprintItems .. " blueprints")
            end
        end
    end

    BlueprintBtn = Tab:CreateAction("Purchase All Blueprints", "Buy", function()
        if _isBuyingBlueprints then
            _isBuyingBlueprints = false
            UpdateBlueprintBtnState()
            return
        end
        BlueprintBtn:SetText("Stop")
        task.spawn(function()
            RunBlueprintLoop(ShopItems, function()
                UpdateBlueprintBtnState()
            end)
        end)
    end, false)

    UpdateBlueprintBtnState()

    -- ── Rukiry Axe ──────────────────────────────────────────────────
    local RUKIRY_ITEMS = {
        { BoxItemName = "CanOfWorms", GoalCF = CFrame.new(317.3, 46.0, 1918.1) },
        { BoxItemName = "BagOfSand",  GoalCF = CFrame.new(319.5, 46.0, 1914.9) },
        { BoxItemName = "LightBulb",  GoalCF = CFrame.new(322.4, 43.6, 1916.4) },
    }

    local RUKIRY_PLAYER_CF = CFrame.new(320.6, 45.8, 1919.2)

    local RukiryBtn
    local _isBuyingRukiry = false

    local function PurchaseRukiryItem(mainPart, item, goalCF)
        local npcArg, resolvedNPCName = PositionForPurchase(mainPart, item, nil)
        if not npcArg then return false end

        local purchased, _ = SpamPurchase(mainPart, npcArg, item.Name, resolvedNPCName)

        if purchased then
            task.wait(0.05)

            local PlayerModels = workspace:FindFirstChild("PlayerModels")
            local existingModels = {}
            if PlayerModels then
                for _, m in ipairs(PlayerModels:GetChildren()) do
                    existingModels[m] = true
                end
            end

            local boxModel = mainPart and mainPart.Parent
            if boxModel and boxModel:IsA("Model") then
                local ch   = Player.Character
                local head = ch and ch:FindFirstChild("Head")
                if head then
                    Interact:FireServer(boxModel, "Open box", head.CFrame)
                end
            end

            local spawnedPart = nil
            local deadline = tick() + 5
            while tick() < deadline do
                task.wait(0.1)
                if PlayerModels then
                    for _, m in ipairs(PlayerModels:GetChildren()) do
                        if not existingModels[m] and m:IsA("Model") then
                            local itemNameVal = m:FindFirstChild("ItemName")
                            if not (itemNameVal and itemNameVal.Value == item.BoxItemName) then continue end
                            local ownerFolder = m:FindFirstChild("Owner")
                            local ownerString = ownerFolder and ownerFolder:FindFirstChild("OwnerString")
                            if not (ownerString and ownerString.Value == Player.Name) then continue end
                            local foundMain = m:FindFirstChild("Main")
                            if foundMain then
                                spawnedPart = foundMain
                                break
                            end
                        end
                    end
                end
                if spawnedPart then break end
            end

            if spawnedPart and spawnedPart.Parent then
                _LOT.TeleportMany({ { target = spawnedPart, goalCF = goalCF } })
                if _LOT.IsBusy() then _LOT.WaitForBatch() end
            else
                warn("[Rukiry] Could not find spawned item after box open")
            end
        end

        return purchased
    end

    local function RunRukiryLoop()
        _isBuyingRukiry = true
        FetchAllNPCIDs()

        local returnChar = Player.Character
        local returnRoot = returnChar and returnChar:FindFirstChild("HumanoidRootPart")
        local rukiryReturnCF = returnRoot and returnRoot.CFrame

        for _, rukiryItem in ipairs(RUKIRY_ITEMS) do
            if not _isBuyingRukiry then break end

            local itemDef = nil
            for _, shopItem in ipairs(ShopItems) do
                if shopItem.BoxItemName == rukiryItem.BoxItemName then
                    itemDef = shopItem
                    break
                end
            end

            if not itemDef then
                warn("[Rukiry] Item not found in list:", rukiryItem.BoxItemName)
                continue
            end

            local funds = FetchFunds()
            if funds == nil or funds < itemDef.Price then
                warn("[Rukiry] Not enough funds for:", itemDef.Name, "(need $" .. itemDef.Price .. ")")
                continue
            end

            local parts = ResolveItemParts(itemDef, 1)
            if #parts == 0 then
                warn("[Rukiry] No stock found for:", itemDef.Name)
                continue
            end

            local mainPart = parts[1]
            if not mainPart or not mainPart.Parent then
                warn("[Rukiry] mainPart gone for:", itemDef.Name)
                continue
            end

            print("[Rukiry] Purchasing:", itemDef.Name)
            local purchased = PurchaseRukiryItem(mainPart, itemDef, rukiryItem.GoalCF)

            if purchased then
                print("[Rukiry] Placed:", itemDef.Name)
            else
                warn("[Rukiry] Failed:", itemDef.Name)
            end

            task.wait(0.2)
        end

        local retChar = Player.Character
        local retRoot = retChar and retChar:FindFirstChild("HumanoidRootPart")
        if retRoot then retRoot.CFrame = RUKIRY_PLAYER_CF end

        print("[Rukiry] Waiting for axe to spawn...")
        local axeModel    = nil
        local axeDeadline = tick() + 20
        while tick() < axeDeadline do
            task.wait(0.2)
            local PlayerModels = workspace:FindFirstChild("PlayerModels")
            if not PlayerModels then continue end

            local ch   = Player.Character
            local root = ch and ch:FindFirstChild("HumanoidRootPart")

            for _, m in ipairs(PlayerModels:GetChildren()) do
                if not (m:IsA("Model") and m.Name == "Model") then continue end
                local toolName = m:FindFirstChild("ToolName")
                if not (toolName and toolName.Value == "Rukiryaxe") then continue end
                local ownerFolder = m:FindFirstChild("Owner")
                local ownerString = ownerFolder and ownerFolder:FindFirstChild("OwnerString")
                if not (ownerString and ownerString.Value == "") then continue end
                local lastInteraction = ownerFolder and ownerFolder:FindFirstChild("LastInteraction")
                if not (lastInteraction and lastInteraction.Value == 0) then continue end
                if root then
                    local handle = m:FindFirstChild("Handle") or m.PrimaryPart
                    if handle and (handle.Position - root.Position).Magnitude > 50 then continue end
                end
                axeModel = m
                break
            end

            if axeModel then break end
        end

        if axeModel then
            -- The axe is unowned, so we CAN'T reliably drag it to us — the server
            -- reverts CFrame changes from non-owners. Instead bring OUR character
            -- to the axe (always authoritative), claim it with the drag remote,
            -- fire the pickup, and confirm the loose model actually left the world.
            local function AxeGone()
                return (not axeModel.Parent) or (not axeModel:IsDescendantOf(workspace))
            end

            print("[Rukiry] Found axe — moving to it and picking up...")
            local picked   = false
            local deadline = tick() + 8

            while tick() < deadline and _isBuyingRukiry and not picked do
                local handle = axeModel:FindFirstChild("Handle") or axeModel.PrimaryPart
                if not handle then break end

                local rc = Player.Character
                local rr = rc and rc:FindFirstChild("HumanoidRootPart")
                if rr then
                    rr.CFrame = handle.CFrame + Vector3.new(0, 3, 0)
                    rr.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
                end
                task.wait(0.1)

                -- Claim the axe via the drag remote, then fire the pickup.
                for _ = 1, 8 do
                    pcall(DragRemote.FireServer, DragRemote, axeModel)
                    task.wait()
                end
                local h = axeModel:FindFirstChild("Handle") or axeModel.PrimaryPart
                if h then
                    Interact:FireServer(axeModel, "Pick up tool", h.CFrame)
                end
                task.wait(0.3)

                if AxeGone() then picked = true end
            end

            if picked then
                print("[Rukiry] Axe picked up!")
            else
                warn("[Rukiry] Could not confirm axe pickup — it may still be on the ground.")
            end

            task.wait(0.1)
            local rc2 = Player.Character
            local rr2 = rc2 and rc2:FindFirstChild("HumanoidRootPart")
            if rr2 and rukiryReturnCF then
                rr2.CFrame = rukiryReturnCF
                print("[Rukiry] Returned to original position.")
            end
        else
            warn("[Rukiry] Axe did not spawn within timeout")
        end

        print("[Rukiry] Done!")
        _isBuyingRukiry = false
        RukiryBtn:SetText("$7,400")
    end

    RukiryBtn = Tab:CreateAction("Purchase Rukiry Axe", "$7,400", function()
        if _isBuyingRukiry then
            _isBuyingRukiry = false
            RukiryBtn:SetText("$7,400")
            return
        end
        RukiryBtn:SetText("Stop")
        task.spawn(RunRukiryLoop)
    end, false)

    -- ── Settings ────────────────────────────────────────────────────
    Tab:CreateSection("Settings")

    local QuickPurchaseToggle = Tab:CreateToggle("Quick Purchase", false, function(state)
        _quickPurchase = state
    end)

    QuickPurchaseToggle:AddTooltip(
        "If an item is purchased within 1 second of being teleported to\n" ..
        "the counter, its CFrame is set directly instead of using LOT.\n" ..
        "Faster, but may cause failures on slow servers.\n\n" ..
        "⚠ Warning: this may cause failures."
    )

    local NuclearToggle = Tab:CreateToggle("Force Respawn on Stuck NPC", false, function(state)
        _allowNuclearReset = state
    end)

    NuclearToggle:AddTooltip(
        "If an NPC stays stuck after multiple soft resets, force a\n" ..
        "character respawn to free the server-side ChattingPlayer pin."
    )

    -- ── Blueprint slot watcher ──────────────────────────────────────
    local function GetBlueprintsFolder()
        local playerBP = Player:FindFirstChild("PlayerBlueprints")
        return playerBP and playerBP:FindFirstChild("Blueprints")
    end

    local function UpdateBlueprintSlots()
        local bpFolder = GetBlueprintsFolder()
        for _, item in ipairs(BlueprintItems) do
            local owned = bpFolder ~= nil and bpFolder:FindFirstChild(item.BoxItemName) ~= nil
            local slotObj = BlueprintSlotObjs[item.Name]
            if slotObj then slotObj:SetEnabled(not owned) end
        end
    end

    local _bpFolderConns = {}

    local function WireBlueprintFolder(folder)
        for _, c in ipairs(_bpFolderConns) do c:Disconnect() end
        _bpFolderConns = {}
        if not folder then return end
        table.insert(_bpFolderConns, folder.ChildAdded:Connect(function()
            UpdateBlueprintSlots()
            UpdateBlueprintBtnState()
        end))
        table.insert(_bpFolderConns, folder.ChildRemoved:Connect(function()
            UpdateBlueprintSlots()
            UpdateBlueprintBtnState()
        end))
    end

    local function WatchPlayerBlueprints()
        local playerBP = Player:FindFirstChild("PlayerBlueprints")
        if not playerBP then
            Player.ChildAdded:Connect(function(child)
                if child.Name ~= "PlayerBlueprints" then return end
                local sub = child:FindFirstChild("Blueprints")
                if sub then
                    WireBlueprintFolder(sub)
                    UpdateBlueprintSlots()
                    UpdateBlueprintBtnState()
                else
                    child.ChildAdded:Connect(function(subchild)
                        if subchild.Name == "Blueprints" then
                            WireBlueprintFolder(subchild)
                            UpdateBlueprintSlots()
                            UpdateBlueprintBtnState()
                        end
                    end)
                end
            end)
            return
        end

        local folder = playerBP:FindFirstChild("Blueprints")
        if folder then
            WireBlueprintFolder(folder)
        else
            playerBP.ChildAdded:Connect(function(child)
                if child.Name == "Blueprints" then
                    WireBlueprintFolder(child)
                    UpdateBlueprintSlots()
                    UpdateBlueprintBtnState()
                end
            end)
        end

        Player.ChildRemoved:Connect(function(child)
            if child.Name == "PlayerBlueprints" then
                for _, c in ipairs(_bpFolderConns) do c:Disconnect() end
                _bpFolderConns = {}
                UpdateBlueprintSlots()
                UpdateBlueprintBtnState()
                WatchPlayerBlueprints()
            end
        end)
    end

    WatchPlayerBlueprints()
    UpdateBlueprintSlots()
    UpdateBlueprintBtnState()
end

-- ┌─────────────────────────────────────────────────────────────────┐
-- │                         PUBLIC API                              │
-- └─────────────────────────────────────────────────────────────────┘
function ShopModule.GetItems()
    return _ShopItems
end

function ShopModule.PurchaseItem(itemName, quantity, pressedCF, onDone)
    if _isBuying               then return false, "already buying"    end
    if not _ShopItems          then return false, "not initialised"   end

    local item
    for _, i in ipairs(_ShopItems) do
        if i.Name == itemName then item = i; break end
    end

    if not item                     then return false, "item not found"    end
    if not item.Store               then return false, "item has no store" end
    if not StoreConfigs[item.Store] then return false, "no store config"   end

    quantity  = math.max(1, quantity or 1)
    pressedCF = pressedCF or (function()
        local c = Player.Character
        local r = c and c:FindFirstChild("HumanoidRootPart")
        return r and r.CFrame
    end)()

    task.spawn(function()
        RunBuyLoop(item, quantity, pressedCF, onDone)
    end)

    return true
end

function ShopModule.PurchaseSingleBlueprint(boxItemName)
    if _isBuying then return false, "already buying" end
    if not _ShopItems then
        _ShopItems = LoadItemList()
        if not _ShopItems then return false, "item list unavailable" end
    end

    local pb = Player:FindFirstChild("PlayerBlueprints")
    local bf = pb and pb:FindFirstChild("Blueprints")
    if bf and bf:FindFirstChild(boxItemName) then return true, "already owned" end

    local item
    for _, i in ipairs(_ShopItems) do
        if i.BoxItemName == boxItemName and i.IsBlueprint then item = i; break end
    end
    if not item then return false, "blueprint not found in shop" end

    local funds = FetchFunds()
    if not funds then return false, "could not check funds" end
    if funds < item.Price then return false, "insufficient funds (need $" .. item.Price .. ")" end

    local parts = ResolveItemParts(item, 1)
    if #parts == 0 then return false, "no stock in store" end
    local mainPart = parts[1]
    if not mainPart or not mainPart.Parent then return false, "item unavailable" end

    FetchAllNPCIDs()
    local purchased = PurchaseBlueprintPart(mainPart, item)
    if not purchased then return false, "purchase failed" end

    local opened = OpenBlueprintBox(boxItemName)
    if not opened then return false, "box open failed (blueprint may still be acquired)" end

    return true, "purchased"
end

return ShopModule