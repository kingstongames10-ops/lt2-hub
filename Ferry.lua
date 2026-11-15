-- ============================================================================
-- Ferry.lua  —  LT2 ferry departure tracker
-- ----------------------------------------------------------------------------
-- Game-specific module. Watches Workspace.Ferry.TimeToDeparture and pushes the
-- countdown into the shared header status line via the UI library:
--   Window:SetHeaderStatus(text, color)
--
-- Init signature: Ferry.Init(Window)  (passed HubWindow from main.lua)
-- ============================================================================

local Ferry = {}

function Ferry.Init(Window)
    if not (Window and Window.SetHeaderStatus) then
        warn("[Ferry] A Window with SetHeaderStatus is required")
        return
    end

    local Theme     = Window.Theme or {}
    local WarnColor = Theme.Warning       or Color3.fromRGB(100, 155, 255)
    local DimColor  = Theme.TextSecondary or Color3.fromRGB(120, 120, 130)

    -- Immediate placeholder so the header isn't blank while we wait.
    Window:SetHeaderStatus("Ferry: --", DimColor)

    task.spawn(function()
        local FerryObj = game.Workspace:WaitForChild("Ferry", 10)
        if not FerryObj then
            Window:ClearHeaderStatus()
            return
        end
        local TimeToDeparture = FerryObj:WaitForChild("TimeToDeparture", 10)
        if not TimeToDeparture then
            Window:ClearHeaderStatus()
            return
        end

        local function Update()
            local val = TimeToDeparture.Value
            if val <= 0 then
                Window:SetHeaderStatus("Ferry has Departed", DimColor)
            elseif val <= 10 then
                Window:SetHeaderStatus("Ferry Departs: " .. val .. "s", WarnColor)
            else
                Window:SetHeaderStatus("Ferry Departs: " .. val .. "s", DimColor)
            end
        end

        Update()
        TimeToDeparture.Changed:Connect(Update)
    end)
end

return Ferry
