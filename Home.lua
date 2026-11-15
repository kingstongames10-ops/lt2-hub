local HomeModule = {}

function HomeModule.Init(Tab, Library)
    local Player            = game:GetService("Players").LocalPlayer
    local TeleportService   = game:GetService("TeleportService")
    local HttpService       = game:GetService("HttpService")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")

    local function ForceSaveBeforeLeave()
        local loadSaveRequests = ReplicatedStorage:FindFirstChild("LoadSaveRequests")
        local currentSlot = Player:FindFirstChild("CurrentSaveSlot")
                         or (Player:FindFirstChild("Data") and Player.Data:FindFirstChild("CurrentSaveSlot"))
        if not (loadSaveRequests and currentSlot and currentSlot.Value ~= -1) then return end

        local RequestSaveRemote = loadSaveRequests:FindFirstChild("RequestSave")
        if not RequestSaveRemote then return end

        Library:Notify("Dynxe LT2", "Saving plot before leaving...")
        pcall(function()
            RequestSaveRemote:InvokeServer(currentSlot.Value)
        end)
        task.wait(0.5)
    end

    Tab:CreateSection("Server Management")

    local function ServerHop(sortOrder, label)
        ForceSaveBeforeLeave()
        Library:Notify("Dynxe LT2", "Searching for " .. label .. " server...")
        local api = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=%s&limit=100"):format(game.PlaceId, sortOrder)
        local ok, result = pcall(function()
            return HttpService:JSONDecode(game:HttpGet(api))
        end)
        if not ok or not result or not result.data then
            Library:Notify("Error 100", "Failed to fetch server list.")
            return
        end
        for _, s in ipairs(result.data) do
            if s.playing < s.maxPlayers and s.id ~= game.JobId then
                TeleportService:TeleportToPlaceInstance(game.PlaceId, s.id, Player)
                return
            end
        end
        Library:Notify("Error 101", "No suitable server found.")
    end

    Tab:CreateAction("Rejoin Server", "Rejoin", function()
        ForceSaveBeforeLeave()
        TeleportService:Teleport(game.PlaceId, Player)
    end)

    local HopRow = Tab:CreateRow()
    HopRow:CreateAction("Descending", "Join", function() ServerHop("Asc",  "least populated") end)
    HopRow:CreateAction("Ascending",  "Join", function() ServerHop("Desc", "most populated")  end)

    Tab:CreateSection("Community & Support")

    Tab:CreateAction("Discord Server", "Copy", function()
        setclipboard("https://discord.gg/bSaWYeaw7Q")
        Library:Notify("Dynxe LT2", "Discord link copied!")
    end)
    Tab:CreateAction("Dynxe Services", "Copy", function()
        setclipboard("https://dynxe.services/")
        Library:Notify("Dynxe LT2", "Website link copied!")
    end)
    Tab:CreateAction("Donate", "Copy", function()
        setclipboard("https://ko-fi.com/dynxe")
        Library:Notify("Dynxe LT2", "Donation link copied!")
    end):AddTooltip("Donations go directly to server hosting and development costs for Dynxe!")
end

return HomeModule