local Theme = {
    MainBG      = Color3.fromRGB(20, 20, 30),
    RowBG       = Color3.fromRGB(30, 30, 45),
    SidebarBG   = Color3.fromRGB(13, 13, 20),
    AccentBlue  = Color3.fromRGB(30, 120, 255),
    FilledBtn   = Color3.fromRGB(20, 90, 210),
    Text        = Color3.fromRGB(255, 255, 255),
    SubText     = Color3.fromRGB(180, 180, 195),
    Border      = Color3.fromRGB(40, 40, 60),
    DropShadow  = Color3.fromRGB(8, 8, 14),
}

local Scale = {
    UIScale = .9,
}

local Fonts = {
    Body   = Enum.Font.GothamMedium,
    Bold   = Enum.Font.GothamBold,
    Button = Enum.Font.GothamBold,
}

local TextSizes = {
    Offset     =  0,
    SectionMin = 13,
    BodyMin    = 12,
    ButtonMin  = 12,
}

local Player    = game:GetService("Players").LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local DynxeTheme = {}

local enabled          = true
local watching         = {}
local propertyConns    = {}
local originals        = {}
local originalScales   = {}

local TRACKED_PROPS = {
    "BackgroundColor3", "BackgroundTransparency", "BorderSizePixel",
    "TextColor3", "Font", "TextSize",
}

local function SaveOriginals(obj)
    if originals[obj] then return end
    local saved = {}
    for _, prop in ipairs(TRACKED_PROPS) do
        local ok, val = pcall(function() return obj[prop] end)
        if ok then saved[prop] = val end
    end
    originals[obj] = saved
end

local function RestoreOriginals(obj)
    local saved = originals[obj]
    if not saved then return end
    for prop, val in pairs(saved) do
        pcall(function() obj[prop] = val end)
    end
end

local function ApplyUIScale(screenGui)
    if not screenGui:IsA("ScreenGui") then return end
    local existing = screenGui:FindFirstChildOfClass("UIScale")
    if existing then
        if originalScales[screenGui] == nil then
            originalScales[screenGui] = existing.Scale
        end
        existing.Scale = Scale.UIScale
    else
        if originalScales[screenGui] == nil then
            originalScales[screenGui] = false
        end
        local s       = Instance.new("UIScale")
        s.Name        = "DynxeUIScale"
        s.Scale       = Scale.UIScale
        s.Parent      = screenGui
    end
end

local function RemoveUIScale(screenGui)
    if not screenGui:IsA("ScreenGui") then return end
    local orig = originalScales[screenGui]
    if orig == false then
        local s = screenGui:FindFirstChild("DynxeUIScale")
        if s then s:Destroy() end
    elseif orig then
        local existing = screenGui:FindFirstChildOfClass("UIScale")
        if existing then existing.Scale = orig end
    end
    originalScales[screenGui] = nil
end

local function BuildApplier(obj)
    if obj:IsA("Frame") or obj:IsA("ScrollingFrame") then
        local nameLower = obj.Name:lower()
        local color

        if nameLower:match("sidebar") or nameLower:match("nav") then
            color = Theme.SidebarBG
        elseif nameLower:match("shadow") or nameLower:match("drop") then
            color = Color3.fromRGB(0, 0, 0)
        elseif obj.Name == "Main" or nameLower:match("container")
            or nameLower:match("window") or nameLower:match("panel") then
            color = Theme.MainBG
        elseif nameLower:match("row") or nameLower:match("item")
            or nameLower:match("entry") or nameLower:match("cell") then
            color = Theme.RowBG
        else
            color = Theme.MainBG
        end

        local isShadow = nameLower:match("shadow") or nameLower:match("drop")

        return function()
            obj.BorderSizePixel = 0
            obj.BackgroundColor3 = color
            if isShadow then obj.BackgroundTransparency = 0.6 end
        end

    elseif obj:IsA("TextButton") then
        local nameLower = obj.Name:lower()
        local textLower = obj.Text and obj.Text:lower() or ""
        local bgColor, textColor, bgTransparency

        if textLower == "tp" or textLower == "plot" then
            bgColor = Theme.FilledBtn
            textColor = Theme.Text
            bgTransparency = 0
        elseif textLower:match("select") or nameLower:match("select")
            or nameLower:match("teleport") or textLower:match("teleport")
            or nameLower:match("^tp$") then
            bgColor = Color3.fromRGB(0, 0, 0)
            textColor = Theme.AccentBlue
            bgTransparency = 1
        else
            bgColor = Theme.RowBG
            textColor = Theme.Text
            bgTransparency = 0
        end

        return function()
            obj.BorderSizePixel = 0
            obj.Font = Fonts.Button
            obj.TextSize = math.max(TextSizes.ButtonMin, obj.TextSize) + TextSizes.Offset
            obj.BackgroundColor3 = bgColor
            obj.BackgroundTransparency = bgTransparency
            obj.TextColor3 = textColor
        end

    elseif obj:IsA("ImageButton") then
        return function()
            obj.BackgroundColor3 = Theme.SidebarBG
            obj.BackgroundTransparency = 0
            obj.BorderSizePixel = 0
        end

    elseif obj:IsA("TextLabel") then
        local nameLower = obj.Name:lower()
        local textVal   = obj.Text or ""

        if nameLower == "dropshadow" or nameLower:match("drop_shadow") then
            return function()
                obj.BackgroundTransparency = 1
                obj.TextColor3 = Theme.DropShadow
                obj.Font = Fonts.Body
            end
        end

        local isHeader = nameLower:match("section") or nameLower:match("heading")
            or nameLower:match("header") or nameLower:match("title")
            or (textVal == textVal:upper() and #textVal > 2)
            or obj.TextSize >= 18

        local isSub = nameLower:match("sub") or nameLower:match("hint")
            or nameLower:match("desc")

        local textColor = isHeader and Theme.AccentBlue
                       or isSub    and Theme.SubText
                       or Theme.Text
        local font      = isHeader and Fonts.Bold or Fonts.Body
        local minSize   = isHeader and TextSizes.SectionMin or TextSizes.BodyMin

        return function()
            obj.BackgroundTransparency = 1
            obj.TextColor3 = textColor
            obj.Font = font
            obj.TextSize = math.max(minSize, obj.TextSize) + TextSizes.Offset
        end

    elseif obj:IsA("ImageLabel") then
        return function()
            obj.BackgroundTransparency = 1
        end
    end

    return nil
end

local function ThemeAndWatch(obj)
    if watching[obj] then return end
    if not enabled then return end

    local applier = BuildApplier(obj)
    if not applier then return end

    SaveOriginals(obj)
    watching[obj] = true
    applier()

    local reapplying = false

    local function onReset()
        if reapplying or not enabled then return end
        task.delay(0.15, function()
            if not obj or not obj.Parent or not enabled then return end
            reapplying = true
            applier()
            reapplying = false
        end)
    end

    if obj:IsA("GuiObject") then
        local c = obj:GetPropertyChangedSignal("BackgroundColor3"):Connect(onReset)
        table.insert(propertyConns, c)
    end
    if obj:IsA("TextLabel") or obj:IsA("TextButton") then
        local c1 = obj:GetPropertyChangedSignal("TextColor3"):Connect(onReset)
        local c2 = obj:GetPropertyChangedSignal("Font"):Connect(onReset)
        table.insert(propertyConns, c1)
        table.insert(propertyConns, c2)
    end

    local dc = obj.Destroying:Connect(function()
        watching[obj]  = nil
        originals[obj] = nil
    end)
    table.insert(propertyConns, dc)
end

local function ThemeAll(parent)
    for _, child in ipairs(parent:GetChildren()) do
        if child:IsA("ScreenGui") then ApplyUIScale(child) end
    end
    for _, child in ipairs(parent:GetDescendants()) do
        ThemeAndWatch(child)
    end
end

function DynxeTheme.Enable()
    if enabled then return end
    enabled = true
    ThemeAll(PlayerGui)
end

function DynxeTheme.Disable()
    if not enabled then return end
    enabled = false

    -- Disconnect all per-element watchers
    for _, conn in ipairs(propertyConns) do
        if conn and conn.Connected then conn:Disconnect() end
    end
    propertyConns = {}

    -- Restore every element to its original look
    for obj, _ in pairs(originals) do
        if obj and obj.Parent then
            RestoreOriginals(obj)
        end
    end
    originals = {}
    watching  = {}

    -- Undo UIScale on all ScreenGuis
    for _, child in ipairs(PlayerGui:GetChildren()) do
        if child:IsA("ScreenGui") then
            RemoveUIScale(child)
        end
    end
    originalScales = {}
end

function DynxeTheme.IsEnabled()
    return enabled
end

PlayerGui.DescendantAdded:Connect(function(descendant)
    if not enabled then return end
    task.wait(0.1)
    ThemeAndWatch(descendant)
    if descendant:IsA("ScreenGui") then
        ApplyUIScale(descendant)
    end
end)
ThemeAll(PlayerGui)

_G.DynxeTheme = DynxeTheme
return DynxeTheme
