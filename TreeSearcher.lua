local TreeSearcher = {}

function TreeSearcher.Init(Tab, Library)
    local Players          = game:GetService("Players")
    local TeleportService  = game:GetService("TeleportService")
    local HttpService      = game:GetService("HttpService")
    local UserInputService = game:GetService("UserInputService")
    local CoreGui          = game:GetService("CoreGui")
    local TweenService     = game:GetService("TweenService")
    local player           = Players.LocalPlayer

    local FOLDER      = "Dynxe"
    local STATE_FILE  = FOLDER .. "/cc_state.json"
    local BOOTSTRAP_FILE = FOLDER .. "/cc_bootstrap.lua"
    local QUEUE_LINE  = "pcall(function() loadstring(readfile('Dynxe/cc_bootstrap.lua'))() end)"
    local HUD_NAME    = "TreeSearcherHUD"

    local LOAD_WAIT   = 6
    local RETRY_WAIT  = 5
    local HOP_TIMEOUT = 20

    local SIZE_THRESHOLDS = {
        CaveCrawler = { Small = 0, Medium = 1000, Large = 2000 },
        LoneCave    = { Small = 0, Medium = 1000, Large = 2000 },
    }

    if not isfolder(FOLDER) then makefolder(FOLDER) end

    local function ReadState()
        local ok, data = pcall(readfile, STATE_FILE)
        if not ok or not data or data == "" then return nil end
        local ok2, decoded = pcall(HttpService.JSONDecode, HttpService, data)
        return ok2 and decoded or nil
    end

    local function WriteState(state)
        local ok, encoded = pcall(HttpService.JSONEncode, HttpService, state)
        if ok then pcall(writefile, STATE_FILE, encoded) end
    end

    local function SetActive(active)
        local state = ReadState() or {}
        state.active = active
        WriteState(state)
    end

    local function DestroyHUD()
        local existing = CoreGui:FindFirstChild(HUD_NAME)
        if existing then existing:Destroy() end
    end

    local function CreateHUD(treeType)
        DestroyHUD()
        local gui = Instance.new("ScreenGui")
        gui.Name            = HUD_NAME
        gui.ZIndexBehavior  = Enum.ZIndexBehavior.Sibling
        gui.DisplayOrder    = 998
        gui.ResetOnSpawn    = false
        gui.IgnoreGuiInset  = true
        gui.Parent          = CoreGui

        local bar = Instance.new("Frame")
        bar.Name                   = "Bar"
        bar.Size                   = UDim2.new(1, 0, 0, 58)
        bar.Position               = UDim2.new(0, 0, 0.9, -29)
        bar.BackgroundColor3       = Color3.fromRGB(0, 0, 0)
        bar.BackgroundTransparency = 0.45
        bar.BorderSizePixel        = 0
        bar.Parent                 = gui

        local topLine = Instance.new("Frame")
        topLine.Size             = UDim2.new(1, 0, 0, 1)
        topLine.BackgroundColor3 = Color3.fromRGB(74, 120, 255)
        topLine.BackgroundTransparency = 0.5
        topLine.BorderSizePixel  = 0
        topLine.Parent           = bar

        local botLine = Instance.new("Frame")
        botLine.Size             = UDim2.new(1, 0, 0, 1)
        botLine.Position         = UDim2.new(0, 0, 1, -1)
        botLine.BackgroundColor3 = Color3.fromRGB(74, 120, 255)
        botLine.BackgroundTransparency = 0.5
        botLine.BorderSizePixel  = 0
        botLine.Parent           = bar

        local topRow = Instance.new("Frame")
        topRow.Name                   = "TopRow"
        topRow.Size                   = UDim2.new(1, 0, 0, 28)
        topRow.Position               = UDim2.new(0, 0, 0, 2)
        topRow.BackgroundTransparency = 1
        topRow.Parent                 = bar

        local badge = Instance.new("TextLabel")
        badge.Size                   = UDim2.new(0, 160, 1, 0)
        badge.Position               = UDim2.new(0, 16, 0, 0)
        badge.BackgroundTransparency = 1
        badge.Text                   = "TREE SEARCHER"
        badge.TextColor3             = Color3.fromRGB(74, 120, 255)
        badge.Font                   = Enum.Font.GothamBold
        badge.TextSize               = 13
        badge.TextXAlignment         = Enum.TextXAlignment.Left
        badge.Parent                 = topRow

        local treeLabel = Instance.new("TextLabel")
        treeLabel.Size               = UDim2.new(1, -340, 1, 0)
        treeLabel.Position           = UDim2.new(0, 180, 0, 0)
        treeLabel.BackgroundTransparency = 1
        treeLabel.Text               = treeType or "Unknown"
        treeLabel.TextColor3         = Color3.fromRGB(220, 220, 220)
        treeLabel.Font               = Enum.Font.GothamMedium
        treeLabel.TextSize           = 13
        treeLabel.TextXAlignment     = Enum.TextXAlignment.Center
        treeLabel.Parent             = topRow

        local f1hint = Instance.new("TextLabel")
        f1hint.Size                  = UDim2.new(0, 140, 1, 0)
        f1hint.AnchorPoint           = Vector2.new(1, 0)
        f1hint.Position              = UDim2.new(1, -16, 0, 0)
        f1hint.BackgroundTransparency = 1
        f1hint.Text                  = "F1 / Backspace to stop"
        f1hint.TextColor3            = Color3.fromRGB(100, 100, 110)
        f1hint.Font                  = Enum.Font.Gotham
        f1hint.TextSize              = 12
        f1hint.TextXAlignment        = Enum.TextXAlignment.Right
        f1hint.Parent                = topRow

        local div = Instance.new("Frame")
        div.Size             = UDim2.new(1, -32, 0, 1)
        div.Position         = UDim2.new(0, 16, 0, 30)
        div.BackgroundColor3 = Color3.fromRGB(60, 60, 70)
        div.BorderSizePixel  = 0
        div.Parent           = bar

        local statusLabel = Instance.new("TextLabel")
        statusLabel.Name                 = "StatusLabel"
        statusLabel.Size                 = UDim2.new(1, -32, 0, 24)
        statusLabel.Position             = UDim2.new(0, 16, 0, 32)
        statusLabel.BackgroundTransparency = 1
        statusLabel.Text                 = "Initializing..."
        statusLabel.TextColor3           = Color3.fromRGB(180, 180, 190)
        statusLabel.Font                 = Enum.Font.Gotham
        statusLabel.TextSize             = 12
        statusLabel.TextXAlignment       = Enum.TextXAlignment.Center
        statusLabel.Parent               = bar
    end

    local function SetHUDStatus(msg)
        local gui = CoreGui:FindFirstChild(HUD_NAME)
        if not gui then return end
        local bar   = gui:FindFirstChild("Bar")
        local label = bar and bar:FindFirstChild("StatusLabel")
        if label then label.Text = msg end
    end

    local function SetHUDFound(posStr, treeType)
        local gui = CoreGui:FindFirstChild(HUD_NAME)
        if not gui then return end
        local bar = gui:FindFirstChild("Bar")
        if not bar then return end
        TweenService:Create(bar, TweenInfo.new(0.4), {
            BackgroundColor3 = Color3.fromRGB(15, 55, 20)
        }):Play()
        local label = bar:FindFirstChild("StatusLabel")
        if label then
            label.Text       = treeType .. " found!  Position: " .. posStr .. "  |  F1 / Backspace to dismiss"
            label.TextColor3 = Color3.fromRGB(120, 230, 130)
        end
    end

    local BOOTSTRAP_SRC = [=[
task.wait(2)
local HttpService = game:GetService("HttpService")
local ok, raw = pcall(readfile, "Dynxe/cc_state.json")
if not ok or not raw or raw == "" then return end
local ok2, state = pcall(HttpService.JSONDecode, HttpService, raw)
if not ok2 or not state or state.active ~= true then return end

-- inline hopper using state values
local Players          = game:GetService("Players")
local TeleportService  = game:GetService("TeleportService")
local UserInputService = game:GetService("UserInputService")
local CoreGui          = game:GetService("CoreGui")
local TweenService     = game:GetService("TweenService")
local player           = Players.LocalPlayer
local PLACE_ID         = game.PlaceId

local treeClass = state.treeType or "CaveCrawler"
local minVolume = state.minVolume or 0
local QUEUE_LINE  = "pcall(function() loadstring(readfile('Dynxe/cc_bootstrap.lua'))() end)"
local LOAD_WAIT   = 6
local RETRY_WAIT  = 5
local HOP_TIMEOUT = 20
local HUD_NAME    = "TreeSearcherHUD"

if getgenv()._ccRunning then return end
getgenv()._ccRunning = true

local function SaveActive(val)
    local ok3, raw2 = pcall(readfile, "Dynxe/cc_state.json")
    local st = {}
    if ok3 and raw2 then
        local ok4, d = pcall(HttpService.JSONDecode, HttpService, raw2)
        if ok4 and d then st = d end
    end
    st.active = val
    local ok5, enc = pcall(HttpService.JSONEncode, HttpService, st)
    if ok5 then pcall(writefile, "Dynxe/cc_state.json", enc) end
end

local function DestroyHUD()
    local e = CoreGui:FindFirstChild(HUD_NAME)
    if e then e:Destroy() end
end

local function CreateHUD(tt)
    DestroyHUD()
    local gui = Instance.new("ScreenGui")
    gui.Name = HUD_NAME; gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true; gui.DisplayOrder = 998
    gui.Parent = CoreGui
    local bar = Instance.new("Frame", gui)
    bar.Name = "Bar"
    bar.Size = UDim2.new(1,0,0,58)
    bar.Position = UDim2.new(0,0,0.9,-29)
    bar.BackgroundColor3 = Color3.fromRGB(0,0,0)
    bar.BackgroundTransparency = 0.45
    bar.BorderSizePixel = 0
    local sl = Instance.new("TextLabel", bar)
    sl.Name = "StatusLabel"
    sl.Size = UDim2.new(1,-32,0,24)
    sl.Position = UDim2.new(0,16,0,32)
    sl.BackgroundTransparency = 1
    sl.Text = "Scanning for " .. tt .. "..."
    sl.TextColor3 = Color3.fromRGB(180,180,190)
    sl.Font = Enum.Font.Gotham
    sl.TextSize = 12
    sl.TextXAlignment = Enum.TextXAlignment.Center
end

local function SetStatus(msg)
    local g = CoreGui:FindFirstChild(HUD_NAME)
    local b = g and g:FindFirstChild("Bar")
    local l = b and b:FindFirstChild("StatusLabel")
    if l then l.Text = msg end
end

local running = true
CreateHUD(treeClass)

UserInputService.InputBegan:Connect(function(input, processed)
    if not processed and (input.KeyCode == Enum.KeyCode.F1 or input.KeyCode == Enum.KeyCode.Backspace) then
        running = false
        getgenv()._ccRunning = nil
        SaveActive(false)
        DestroyHUD()
    end
end)

local function GetTreeVolume(model)
    local total = 0
    for _, part in ipairs(model:GetChildren()) do
        if part.Name == "WoodSection" and part:IsA("BasePart") then
            total += part.Size.X * part.Size.Y * part.Size.Z
        end
    end
    return total
end

local function FindTree(cls)
    for _, folder in ipairs(workspace:GetChildren()) do
        if folder.Name:lower():match("treeregion") then
            for _, model in ipairs(folder:GetChildren()) do
                if model:IsA("Model") then
                    local tc = model:FindFirstChild("TreeClass")
                    if tc and tc:IsA("StringValue") and tc.Value == cls then
                        if minVolume > 0 and GetTreeVolume(model) < minVolume then continue end
                        return true, model
                    end
                end
            end
        end
    end
    return false, nil
end

local function SafeGet(url)
    local ok6, res = pcall(function() return game:HttpGet(url) end)
    return (ok6 and res and res ~= "") and res or nil
end

local function FetchServers()
    local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100"):format(PLACE_ID)
    local body = SafeGet(url)
    if not body then return {} end
    local ok7, dec = pcall(HttpService.JSONDecode, HttpService, body)
    return (ok7 and type(dec) == "table" and dec.data) or {}
end

local function ArmAndHop()
    local servers = FetchServers()
    local currentId = game.JobId
    local cands = {}
    for _, s in ipairs(servers) do
        if s.id ~= currentId and type(s.playing) == "number" and type(s.maxPlayers) == "number" and s.playing < s.maxPlayers then
            table.insert(cands, s)
        end
    end
    if #cands == 0 or not queue_on_teleport then return false end
    SaveActive(true)
    queue_on_teleport(QUEUE_LINE)
    local ok8 = pcall(TeleportService.TeleportToPlaceInstance, TeleportService, PLACE_ID, cands[math.random(1,#cands)].id, player)
    if not ok8 then SaveActive(false) return false end
    return true
end

task.wait(LOAD_WAIT)

while running do
    SetStatus("Scanning for " .. treeClass .. "...")
    local found, treeModel = FindTree(treeClass)
    if found then
        local pos = treeModel and treeModel:GetPivot().Position or Vector3.zero
        local posStr = ("%.1f, %.1f, %.1f"):format(pos.X, pos.Y, pos.Z)
        SetStatus(treeClass .. " found! " .. posStr .. " | F1 to dismiss")
        running = false
        getgenv()._ccRunning = nil
        SaveActive(false)
        break
    end
    if not running then break end
    SetStatus("Not found. Hopping...")
    local hopped = ArmAndHop()
    if hopped then
        local deadline = tick() + HOP_TIMEOUT
        while running and tick() < deadline do task.wait(1) end
    else
        SetStatus("No servers. Retrying...")
        task.wait(RETRY_WAIT)
    end
end
]=]

    Tab:CreateSection("Tree Server Search")

    local TREE_OPTIONS = { "CaveCrawler", "LoneCave", "BlueSpruce", "Spooky", "SpookyNeon" }
    local DISABLED     = { BlueSpruce = true, Spooky = false, SpookyNeon = false }

    local selectedTree = "CaveCrawler"
    local selectedSize = "Small"
    local searchActive = false
    local startBtn

    local treeDropdown = Tab:CreateDropdown("Target Tree", TREE_OPTIONS, "CaveCrawler", function(sel)
        if not DISABLED[sel] then selectedTree = sel end
    end)
    for name in pairs(DISABLED) do
        treeDropdown:SetOptionDisabled(name, true)
    end

    Tab:CreateDropdown("Size", { "Small", "Medium", "Large", "I DONT CARE (any)" }, "Small", function(sel)
        selectedSize = sel
    end)

    local function GetTreeVolume(model)
        local total = 0
        for _, part in ipairs(model:GetChildren()) do
            if part.Name == "WoodSection" and part:IsA("BasePart") then
                total += part.Size.X * part.Size.Y * part.Size.Z
            end
        end
        return total
    end

    local function FindTree(cls)
        local treeThresholds = SIZE_THRESHOLDS[cls] or { Small = 0, Medium = 0, Large = 0 }
        local minVol = treeThresholds[selectedSize] or 0
        for _, folder in ipairs(workspace:GetChildren()) do
            if folder.Name:lower():match("treeregion") then
                for _, model in ipairs(folder:GetChildren()) do
                    if model:IsA("Model") then
                        local tc = model:FindFirstChild("TreeClass")
                        if tc and tc:IsA("StringValue") and tc.Value == cls then
                            if minVol > 0 and GetTreeVolume(model) < minVol then continue end
                            return true, model
                        end
                    end
                end
            end
        end
        return false, nil
    end

    local function SafeHttpGet(url)
        local ok, res = pcall(function() return game:HttpGet(url) end)
        if ok and res and res ~= "" then return res end
        return nil
    end

    local function FetchServers()
        local url  = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100"):format(game.PlaceId)
        local body = SafeHttpGet(url)
        if not body then return {} end
        local ok, decoded = pcall(HttpService.JSONDecode, HttpService, body)
        return (ok and type(decoded) == "table" and decoded.data) or {}
    end

    local function WriteFiles()
        if not isfolder(FOLDER) then makefolder(FOLDER) end
        local treeThresholds = SIZE_THRESHOLDS[selectedTree] or { Small = 0, Medium = 0, Large = 0 }
        local threshold = treeThresholds[selectedSize] or 0
        -- single state file
        WriteState({
            active    = true,
            treeType  = selectedTree,
            minVolume = threshold,
        })
        pcall(writefile, BOOTSTRAP_FILE, BOOTSTRAP_SRC)
    end

    local function StopSearch()
        if not searchActive then return end
        searchActive = false
        getgenv()._ccRunning = nil
        SetActive(false)
        if startBtn then startBtn:SetText("Start") end
        treeDropdown:SetDisabled(false)
        DestroyHUD()
    end

    local function ArmNextHop()
        if not queue_on_teleport then
            SetHUDStatus("queue_on_teleport unavailable - search cannot persist across servers")
            return false
        end
        SetActive(true)
        queue_on_teleport(QUEUE_LINE)
        return true
    end

    local function HopToServer()
        local servers    = FetchServers()
        local currentId  = game.JobId
        local candidates = {}
        for _, s in ipairs(servers) do
            if s.id ~= currentId
            and type(s.playing) == "number"
            and type(s.maxPlayers) == "number"
            and s.playing < s.maxPlayers then
                table.insert(candidates, s)
            end
        end
        if #candidates == 0 then
            SetHUDStatus("No available servers found. Retrying...")
            return false
        end
        SetHUDStatus("Hopping to next server...")
        if not ArmNextHop() then return false end
        local target = candidates[math.random(1, #candidates)]
        local ok = pcall(TeleportService.TeleportToPlaceInstance,
            TeleportService, game.PlaceId, target.id, player)
        if not ok then
            SetHUDStatus("Teleport failed. Retrying...")
            SetActive(false)
            return false
        end
        return true
    end

    UserInputService.InputBegan:Connect(function(input, processed)
        if processed then return end
        if input.KeyCode == Enum.KeyCode.F1 or input.KeyCode == Enum.KeyCode.Backspace then
            if searchActive then StopSearch() else DestroyHUD() end
        end
    end)

    local function OnStartStop()
        if searchActive then StopSearch() return end
        if getgenv()._ccRunning then
            SetHUDStatus("A search is already running.")
            return
        end

        searchActive = true
        if startBtn then startBtn:SetText("Stop") end
        treeDropdown:SetDisabled(true)

        WriteFiles()
        CreateHUD(selectedTree)

        local treeThresholds = SIZE_THRESHOLDS[selectedTree] or { Small = 0, Medium = 0, Large = 0 }
        local minVol  = treeThresholds[selectedSize] or 0
        local sizeTag = minVol > 0 and (" | " .. selectedSize .. " vol >= " .. minVol) or " | Any size"
        SetHUDStatus("Starting search for " .. selectedTree .. sizeTag .. "...")

        task.spawn(function()
            getgenv()._ccRunning = true
            SetHUDStatus("Waiting for world to finish loading...")
            task.wait(LOAD_WAIT)

            while searchActive and getgenv()._ccRunning do
                local treeT = SIZE_THRESHOLDS[selectedTree] or { Small = 0, Medium = 0, Large = 0 }
                local minV  = treeT[selectedSize] or 0
                local sTag  = minV > 0 and (" | min vol " .. minV) or ""
                SetHUDStatus("Scanning for " .. selectedTree .. sTag .. "...")

                local found, treeModel = FindTree(selectedTree)

                if found then
                    local pos    = treeModel and treeModel:GetPivot().Position or Vector3.zero
                    local posStr = ("%.1f, %.1f, %.1f"):format(pos.X, pos.Y, pos.Z)
                    SetHUDFound(posStr, selectedTree)
                    searchActive = false
                    getgenv()._ccRunning = nil
                    SetActive(false)
                    if startBtn then startBtn:SetText("Start") end
                    treeDropdown:SetDisabled(false)
                    break
                end

                if not searchActive then break end
                SetHUDStatus(selectedTree .. " not found here. Hopping...")

                local hopped = HopToServer()
                if hopped then
                    local deadline = tick() + HOP_TIMEOUT
                    while searchActive and getgenv()._ccRunning and tick() < deadline do
                        task.wait(1)
                    end
                    if searchActive and getgenv()._ccRunning then
                        SetHUDStatus("Teleport timed out. Retrying hop...")
                    end
                else
                    task.wait(RETRY_WAIT)
                end
            end

            getgenv()._ccRunning = nil
        end)
    end

    startBtn = Tab:CreateAction("Search for Tree", "Start", OnStartStop)
end

return TreeSearcher
