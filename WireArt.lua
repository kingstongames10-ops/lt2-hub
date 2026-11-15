-- Blueprints.lua Module
local Blueprints = {}

-- LOT is optional; passed in from the host script when available.
-- It exposes: LOT.TeleportObjectTo(part, cframe)  LOT.IsBusy()  LOT.WaitForBatch()
function Blueprints.Init(Tab, Library, LOT)
    local Players           = game:GetService("Players")
    local RunService        = game:GetService("RunService")
    local UserInputService  = game:GetService("UserInputService")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local GuiService        = game:GetService("GuiService")
    local CoreGui           = game:GetService("CoreGui")
    local DestroyStructure = ReplicatedStorage:FindFirstChild("Interaction")
        and ReplicatedStorage.Interaction:FindFirstChild("DestroyStructure")

    local ClientPlacedStructure  = nil
    local ClientPlacedWire       = nil
    local ClientPlacedBlueprint  = nil
    task.spawn(function()
        ClientPlacedStructure = ReplicatedStorage
            :WaitForChild("PlaceStructure")
            :WaitForChild("ClientPlacedStructure")
        ClientPlacedWire = ReplicatedStorage
            :WaitForChild("PlaceStructure")
            :WaitForChild("ClientPlacedWire")
        ClientPlacedBlueprint = ReplicatedStorage
            :WaitForChild("PlaceStructure")
            :WaitForChild("ClientPlacedBlueprint")
    end)

    local LocalPlayer = Players.LocalPlayer
    local Character   = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
    local Mouse       = LocalPlayer:GetMouse()

    -- ================================================================
    --  STATE
    -- ================================================================
    local Settings     = { Scale = 2, Spacing = 2 }
    local PlaceMode    = false
    local Placing      = false
    local WireRotation = CFrame.new()

    local SelectedWires      = {}
    local SelectedStructures = {}
    local SelectedFurniture  = {}
    local SelectedBlueprints = {}
    local SelectionBoxes     = {}
    local ClickSelectMode    = false
    local GroupSelectMode    = false
    local placementWires  = {}
    local MoveMode       = false
    local moveWires      = {}
    local moveStrokes    = {}
    local moveStructures = {}  -- {model, offsetPos, cf, itemName, treeValue}
    local moveFurniture  = {}  -- {model, offsetPos, cf, itemName}
    local moveBlueprints = {}  -- {model, offsetPos, cf, itemName}
    local movePreviewModels = {}  -- clones shown during move preview; cleared on StopPlacing

    -- Pending structure/furniture data from a loaded file.
    local pendingStructures = {}  -- array of {itemName, cf, treeValue}
    local pendingFurniture  = {}  -- array of {itemName, cf}
    local pendingIsWorldSpace = false

    -- Grid snap
    local snapToGrid = true
    local GRID_SIZE  = 0.5

    -- Object selection toggles
    local selectStructures = true
    local selectFurniture  = true
    local selectWires      = true
    local selectBlueprints = true
    local groupByTreeValue = false

    local BlueprintMode  = false
    local blueprintWires = {}
    local blueprintTypes = {}
    local usePropertyOrigin = false
    local BlueprintBuild = nil
    local GetPlayerProperty, GetPropertyCenter, GetPropertySquares, PointInSquares, StrokeInsideProperty
    local SetWireLength
    local MergeWrappedLines

    -- Lasso state
    local LassoMode      = false
    local LassoDragging  = false
    local LassoStartPos  = nil
    local LassoGui       = nil
    local LassoFrame     = nil

    local PreviewModel    = Instance.new("Model")
    PreviewModel.Name     = "WireArtPreview"
    PreviewModel.Parent   = workspace

    local BLUE        = Color3.fromRGB(74, 120, 255)
    local DEFAULT_MAX = 69.89

    -- ================================================================
    --  PLANK SELECTION STATE
    -- ================================================================
    local allPlanks           = {}    -- all owned planks (every TreeClass), scanned on Build File
    local filteredPlanks      = {}    -- planks that pass the Y-size range filter
    local plankFilterMin      = 1
    local plankFilterMax      = 2
    local plankIndex          = 1     -- round-robin cursor into filteredPlanks
    local plankSelectionBoxes = {}
    local plankOutlineConns   = {}
    local plankRangeSlider    = nil   -- UI range slider reference

    -- ================================================================
    --  GRID SNAP
    -- ================================================================
    local function SnapToGrid(pos)
        if not snapToGrid then return pos end
        local g = GRID_SIZE
        return Vector3.new(
            math.round(pos.X / g) * g,
            pos.Y,
            math.round(pos.Z / g) * g
        )
    end

    -- ================================================================
    --  WIRE TYPE HELPER
    -- ================================================================
    local function GetWireTypeName(wireObj)
        if not wireObj then return nil end
        local itemName = wireObj:FindFirstChild("ItemName")
                      or wireObj:FindFirstChild("PurchasedBoxItemName")
        if itemName and itemName.Value and itemName.Value ~= "" then
            return itemName.Value
        end
        return nil
    end

    -- ================================================================
    --  WIRE MAX-LENGTH HELPER
    -- ================================================================
    local function GetWireMaxLength(wireObj)
        local ClientItemInfo = ReplicatedStorage:FindFirstChild("ClientItemInfo")
        if not ClientItemInfo then return DEFAULT_MAX end
        local itemName = wireObj:FindFirstChild("ItemName")
                      or wireObj:FindFirstChild("PurchasedBoxItemName")
        if not itemName then return DEFAULT_MAX end
        local info = ClientItemInfo:FindFirstChild(itemName.Value, true)
        if not info then return DEFAULT_MAX end
        local maxLen = info:FindFirstChild("MaxLength") or info:FindFirstChild("MaxDistance")
        if maxLen and maxLen.Value and maxLen.Value > 0 then
            return maxLen.Value
        end
        return DEFAULT_MAX
    end

    -- ================================================================
    --  STRUCTURE / FURNITURE HELPERS
    -- ================================================================
    local function GetItemName(model)
        local obj = model:FindFirstChild("ItemName")
        if obj and tostring(obj.Value) ~= "" then return tostring(obj.Value) end
        local boxed = model:FindFirstChild("PurchasedBoxItemName")
        if boxed and tostring(boxed.Value) ~= "" then return tostring(boxed.Value) end
        return model.Name
    end

    local function GetStructureCFrame(model)
        return (model:FindFirstChild("MainCFrame")         and model.MainCFrame.Value)
            or (model:FindFirstChild("BuildDependentWood") and model.BuildDependentWood.CFrame)
            or (model.PrimaryPart                          and model.PrimaryPart.CFrame)
            or model:GetPivot()
    end

    local function GetStructureTreeValue(model)
        local bwc = model:FindFirstChild("BlueprintWoodClass")
        if bwc and bwc.Value and bwc.Value ~= "" then
            return bwc.Value
        end
        return nil
    end

    local function IsOwnedByLocalPlayer(model)
        local ownerFolder = model:FindFirstChild("Owner")
        local ownerString = ownerFolder and ownerFolder:FindFirstChild("OwnerString")
        return ownerString and ownerString.Value == LocalPlayer.Name
    end

    local function GetOwnedStructures()
        local pm = workspace:FindFirstChild("PlayerModels")
        if not pm then return {} end
        local results = {}
        for _, model in ipairs(pm:GetChildren()) do
            local typeVal = model:FindFirstChild("Type")
            if not typeVal or typeVal.Value ~= "Structure" then continue end
            if model:FindFirstChild("PurchasedBoxItemName") then continue end
            if IsOwnedByLocalPlayer(model) then
                table.insert(results, model)
            end
        end
        return results
    end

    local function GetOwnedFurniture()
        local pm = workspace:FindFirstChild("PlayerModels")
        if not pm then return {} end
        local results = {}
        for _, model in ipairs(pm:GetChildren()) do
            local typeVal = model:FindFirstChild("Type")
            if not typeVal or typeVal.Value ~= "Furniture" then continue end
            if model:FindFirstChild("PurchasedBoxItemName") then continue end
            if IsOwnedByLocalPlayer(model) then
                table.insert(results, model)
            end
        end
        return results
    end

    local function GetOwnedWires()
        local pm = workspace:FindFirstChild("PlayerModels")
        if not pm then return {} end
        local results = {}
        for _, model in ipairs(pm:GetChildren()) do
            local typeVal  = model:FindFirstChild("Type")
            local owner    = model:FindFirstChild("Owner")
            local ownerStr = owner and owner:FindFirstChild("OwnerString")
            if typeVal and typeVal.Value == "Wire"
            and ownerStr and ownerStr.Value == LocalPlayer.Name
            and not model:FindFirstChild("PurchasedBoxItemName") then
                table.insert(results, model)
            end
        end
        return results
    end

    -- ================================================================
    --  PLANK HELPERS  (ported from BuildModule)
    -- ================================================================
    local function ClearPlankOutlines()
        for _, conn in ipairs(plankOutlineConns) do conn:Disconnect() end
        plankOutlineConns = {}
        for _, box in ipairs(plankSelectionBoxes) do
            if box and box.Parent then box:Destroy() end
        end
        plankSelectionBoxes = {}
    end

    local function DrawPlankOutlines()
        ClearPlankOutlines()
        for _, entry in ipairs(filteredPlanks) do
            if entry.part and entry.part.Parent then
                local box               = Instance.new("SelectionBox")
                box.Adornee             = entry.part
                box.Color3              = Color3.fromRGB(74, 120, 255)
                box.LineThickness       = 0.03
                box.SurfaceColor3       = Color3.fromRGB(74, 120, 255)
                box.SurfaceTransparency = 0.75
                box.Parent              = CoreGui
                table.insert(plankSelectionBoxes, box)

                local conn = entry.part.Destroying:Connect(function()
                    box:Destroy()
                    for i, e in ipairs(filteredPlanks) do
                        if e.part == entry.part then table.remove(filteredPlanks, i); break end
                    end
                    for i, e in ipairs(allPlanks) do
                        if e.part == entry.part then table.remove(allPlanks, i); break end
                    end
                    plankIndex = math.max(1, math.min(plankIndex, math.max(1, #filteredPlanks)))
                end)
                table.insert(plankOutlineConns, conn)
            end
        end
    end

    -- Scans every owned Plank model regardless of TreeClass.
    -- Called automatically when Build File is triggered.
    local function ScanAllOwnedPlanks()
        local pm = workspace:FindFirstChild("PlayerModels")
        local result = {}
        if not pm then return result end
        for _, model in ipairs(pm:GetChildren()) do
            if model.Name == "Plank" and model:IsA("Model") and IsOwnedByLocalPlayer(model) then
                local tc   = model:FindFirstChild("TreeClass")
                local part = model:FindFirstChild("Main") or model:FindFirstChildWhichIsA("BasePart")
                if part and part:IsA("BasePart") then
                    local sz  = part.Size
                    local vol = math.floor(sz.X * sz.Y * sz.Z * 10 + 0.5) / 10
                    table.insert(result, {
                        model     = model,
                        part      = part,
                        volume    = vol,
                        treeClass = tc and tc:IsA("StringValue") and tc.Value or "",
                    })
                end
            end
        end
        return result
    end

    local function ApplyPlankYFilter()
        filteredPlanks = {}
        for _, e in ipairs(allPlanks) do
            if e.volume >= plankFilterMin and e.volume <= plankFilterMax then
                table.insert(filteredPlanks, e)
            end
        end
        plankIndex = 1
        DrawPlankOutlines()
    end

    -- Returns the next available plank entry for a given treeClass (or any class if nil).
    -- Advances the round-robin cursor and returns nil if no matching plank exists.
    local function GetNextPlankForClass(treeClass)
        if #filteredPlanks == 0 then return nil end
        -- If a specific tree class is requested, try to find a matching plank.
        if treeClass and treeClass ~= "" then
            -- Search from current index forward (wrap around once)
            local startIdx = plankIndex
            for attempt = 1, #filteredPlanks do
                local idx = ((startIdx - 1 + attempt - 1) % #filteredPlanks) + 1
                local entry = filteredPlanks[idx]
                if entry and entry.part and entry.part.Parent then
                    if entry.treeClass == treeClass then
                        plankIndex = (idx % #filteredPlanks) + 1
                        return entry
                    end
                end
            end
            -- No type match found; fall back to any available plank
        end
        -- Round-robin any plank
        for attempt = 1, #filteredPlanks do
            local idx = ((plankIndex - 1 + attempt - 1) % #filteredPlanks) + 1
            local entry = filteredPlanks[idx]
            if entry and entry.part and entry.part.Parent then
                plankIndex = (idx % #filteredPlanks) + 1
                return entry
            end
        end
        return nil
    end

    -- ================================================================
    --  CFRAME SERIALIZATION HELPERS
    -- ================================================================
    local function CFrameToString(cf)
        local c = {cf:GetComponents()}
        local parts = {}
        for _, v in ipairs(c) do
            local s = string.format("%.7g", v)
            table.insert(parts, s)
        end
        return table.concat(parts, ", ")
    end

    local function StringToCFrame(s)
        local nums = {}
        for n in s:gmatch("[^,]+") do
            table.insert(nums, tonumber(n:match("^%s*(.-)%s*$")))
        end
        if #nums == 12 then
            return CFrame.new(table.unpack(nums))
        elseif #nums == 3 then
            return CFrame.new(nums[1], nums[2], nums[3])
        end
        return nil
    end

    -- ================================================================
    --  SELECTION HELPERS
    -- ================================================================
    local function UpdateSelectionVisuals()
        for _, box in ipairs(SelectionBoxes) do box:Destroy() end
        SelectionBoxes = {}
        local function addBox(model)
            if model and model.Parent then
                local box         = Instance.new("SelectionBox")
                box.Color3        = BLUE
                box.LineThickness = 0.05
                box.Adornee       = model
                box.Parent        = workspace
                table.insert(SelectionBoxes, box)
            end
        end
        for _, w in ipairs(SelectedWires)      do addBox(w) end
        for _, s in ipairs(SelectedStructures) do addBox(s) end
        for _, f in ipairs(SelectedFurniture)  do addBox(f) end
        for _, b in ipairs(SelectedBlueprints) do addBox(b) end
    end

    local function ClearSelection()
        SelectedWires      = {}
        SelectedStructures = {}
        SelectedFurniture  = {}
        SelectedBlueprints = {}
        structureUseIndex  = {}
        UpdateSelectionVisuals()
    end

    local function FindWireModelFromPart(part)
        if not part then return nil end
        local pm = workspace:FindFirstChild("PlayerModels")
        if not pm then return nil end
        local cur = part
        while cur and cur.Parent ~= pm do cur = cur.Parent end
        if not cur or not cur:IsA("Model") then return nil end
        local typeVal = cur:FindFirstChild("Type")
        if not typeVal or typeVal.Value ~= "Wire" then return nil end
        return cur
    end

    local function FindStructureModelFromPart(part)
        if not part then return nil end
        local pm = workspace:FindFirstChild("PlayerModels")
        if not pm then return nil end
        local cur = part
        while cur and cur.Parent ~= pm do cur = cur.Parent end
        if not cur or not cur:IsA("Model") then return nil end
        local typeVal = cur:FindFirstChild("Type")
        if not typeVal or (typeVal.Value ~= "Structure" and typeVal.Value ~= "Vehicle Spot") then return nil end
        return cur
    end

    local function FindFurnitureModelFromPart(part)
        if not part then return nil end
        local pm = workspace:FindFirstChild("PlayerModels")
        if not pm then return nil end
        local cur = part
        while cur and cur.Parent ~= pm do cur = cur.Parent end
        if not cur or not cur:IsA("Model") then return nil end
        local typeVal = cur:FindFirstChild("Type")
        if not typeVal or typeVal.Value ~= "Furniture" then return nil end
        if cur:FindFirstChild("PurchasedBoxItemName") then return nil end
        return cur
    end

    local function FindBlueprintModelFromPart(part)
        if not part then return nil end
        local pm = workspace:FindFirstChild("PlayerModels")
        if not pm then return nil end
        local cur = part
        while cur and cur.Parent ~= pm do cur = cur.Parent end
        if not cur or not cur:IsA("Model") then return nil end
        local typeVal = cur:FindFirstChild("Type")
        if not typeVal or typeVal.Value ~= "Blueprint" then return nil end
        return cur
    end

    -- ================================================================
    --  LASSO ENGINE
    -- ================================================================
    local function InitLassoGui()
        if LassoGui then LassoGui:Destroy() end
        local sg = Instance.new("ScreenGui")
        sg.Name           = "WireArtLassoGui"
        sg.ResetOnSpawn   = false
        sg.IgnoreGuiInset = true
        sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        sg.Parent         = game:GetService("CoreGui")

        local frame = Instance.new("Frame")
        frame.BackgroundColor3       = Color3.fromRGB(60, 130, 255)
        frame.BackgroundTransparency = 0.75
        frame.BorderSizePixel        = 0
        frame.Visible                = false
        frame.ZIndex                 = 10
        frame.Parent                 = sg

        local stroke           = Instance.new("UIStroke")
        stroke.Color           = Color3.fromRGB(120, 180, 255)
        stroke.Thickness       = 1.5
        stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        stroke.Parent          = frame

        LassoGui   = sg
        LassoFrame = frame
    end

    local function UpdateLassoFrame(currentPos)
        if not LassoFrame or not LassoStartPos then return end
        local minX = math.min(LassoStartPos.X, currentPos.X)
        local minY = math.min(LassoStartPos.Y, currentPos.Y)
        local maxX = math.max(LassoStartPos.X, currentPos.X)
        local maxY = math.max(LassoStartPos.Y, currentPos.Y)
        LassoFrame.Position = UDim2.fromOffset(minX, minY)
        LassoFrame.Size     = UDim2.fromOffset(maxX - minX, maxY - minY)
        LassoFrame.Visible  = true
    end

    local function ProjectToScreen(worldPos)
        local Camera = workspace.CurrentCamera
        local inset  = GuiService:GetGuiInset()
        local screenPos, onScreen = Camera:WorldToScreenPoint(worldPos)
        if not onScreen or screenPos.Z <= 0 then return nil end
        return Vector2.new(screenPos.X + inset.X, screenPos.Y + inset.Y)
    end

    local function SelectWiresInLassoRect(startPos, endPos)
        local minX = math.min(startPos.X, endPos.X)
        local minY = math.min(startPos.Y, endPos.Y)
        local maxX = math.max(startPos.X, endPos.X)
        local maxY = math.max(startPos.Y, endPos.Y)
        if (maxX - minX) < 6 or (maxY - minY) < 6 then return end

        local pm = workspace:FindFirstChild("PlayerModels")
        if not pm then return end

        local seen = {}

        local function trySelect(model, targetList)
            if seen[model] then return end
            seen[model] = true

            local worldPos
            local okBB, cf = pcall(model.GetBoundingBox, model)
            if okBB and cf then
                worldPos = cf.Position
            else
                local firstPart = model:FindFirstChildWhichIsA("BasePart")
                worldPos = firstPart and firstPart.Position
            end
            if not worldPos then return end

            local sp = ProjectToScreen(worldPos)
            if not sp then return end
            if sp.X >= minX and sp.X <= maxX and sp.Y >= minY and sp.Y <= maxY then
                local idx = table.find(targetList, model)
                if idx then table.remove(targetList, idx)
                else table.insert(targetList, model) end
            end
        end

        for _, model in ipairs(pm:GetChildren()) do
            if not model:IsA("Model") then continue end
            local isBoxed = model:FindFirstChild("PurchasedBoxItemName") ~= nil
            local typeVal = model:FindFirstChild("Type")
            if not typeVal then continue end
            -- Boxed structures and boxed wires are selectable; boxed furniture/blueprints are not.
            if typeVal.Value == "Wire"      and selectWires      then trySelect(model, SelectedWires) end
            if (typeVal.Value == "Structure" or typeVal.Value == "Vehicle Spot") and selectStructures then trySelect(model, SelectedStructures) end
            if typeVal.Value == "Furniture" and selectFurniture  and not isBoxed then trySelect(model, SelectedFurniture) end
            if typeVal.Value == "Blueprint" and selectBlueprints and not isBoxed then trySelect(model, SelectedBlueprints) end
        end

        UpdateSelectionVisuals()
    end

    -- ================================================================
    --  WIRE HELPERS
    -- ================================================================
    local function GetOwnedBoxedWires()
        local wires = {}
        local pm    = workspace:FindFirstChild("PlayerModels")
        if not pm then
            Library:Notify("Blueprints", "PlayerModels not found!")
            return wires
        end
        for _, model in pairs(pm:GetChildren()) do
            local typeVal   = model:FindFirstChild("Type")
            local owner     = model:FindFirstChild("Owner")
            local ownerStr  = owner and owner:FindFirstChild("OwnerString")
            local boxedName = model:FindFirstChild("PurchasedBoxItemName")
            if typeVal   and typeVal.Value  == "Wire"
            and ownerStr and ownerStr.Value == LocalPlayer.Name
            and boxedName then
                table.insert(wires, model)
            end
        end
        Library:Notify("Blueprints", "Found " .. #wires .. " boxed wires!")
        return wires
    end

    local function GetWireInfo(wireObj)
        local itemName = wireObj:FindFirstChild("ItemName")
                      or wireObj:FindFirstChild("PurchasedBoxItemName")
        if not itemName then return nil end
        local ClientItemInfo = ReplicatedStorage:FindFirstChild("ClientItemInfo")
        return ClientItemInfo and ClientItemInfo:FindFirstChild(itemName.Value, true)
    end

    -- Same pattern as GetWireInfo but for structure/boxed-structure objects.
    local function GetStructureInfo(srcModel)
        local itemName = srcModel:FindFirstChild("ItemName")
                      or srcModel:FindFirstChild("PurchasedBoxItemName")
        if not itemName then return nil end
        local ClientItemInfo = ReplicatedStorage:FindFirstChild("ClientItemInfo")
        return ClientItemInfo and ClientItemInfo:FindFirstChild(itemName.Value, true)
    end

    -- ================================================================
    --  PROPERTY HELPER
    -- ================================================================
    function GetPlayerProperty()
        local Properties = workspace:FindFirstChild("Properties")
        if not Properties then return nil end
        for _, prop in ipairs(Properties:GetChildren()) do
            local owner = prop:FindFirstChild("Owner")
            if not owner then continue end
            -- ObjectValue whose .Value is the Player instance
            if owner:IsA("ObjectValue") and owner.Value == LocalPlayer then
                return prop
            end
            -- StringValue or folder containing an OwnerString StringValue
            if owner:IsA("StringValue") and owner.Value == LocalPlayer.Name then
                return prop
            end
            local ownerStr = owner:FindFirstChild("OwnerString")
            if ownerStr and ownerStr:IsA("StringValue") and ownerStr.Value == LocalPlayer.Name then
                return prop
            end
        end
        return nil
    end

    function GetPropertyCenter()
        local prop = GetPlayerProperty()
        if not prop then return nil end
        local origin = prop:FindFirstChild("OriginSquare", true)
        if origin then
            if origin:IsA("BasePart") then
                return origin.Position
            elseif origin:IsA("Model") then
                if origin.PrimaryPart then return origin.PrimaryPart.Position end
                local ok, cf = pcall(origin.GetBoundingBox, origin)
                if ok and cf then return cf.Position end
            end
        end
        if prop.PrimaryPart then return prop.PrimaryPart.Position end
        if prop:IsA("Model") then
            local ok, cf = pcall(prop.GetBoundingBox, prop)
            if ok and cf then return cf.Position end
        end
        return nil
    end

    function GetPropertySquares()
        local prop = GetPlayerProperty()
        if not prop then return nil end
        local rects = {}
        for _, child in ipairs(prop:GetChildren()) do
            if child:IsA("BasePart")
            and (child.Name == "Square" or child.Name == "OriginSquare") then
                local pos     = child.Position
                local halfX   = child.Size.X * 0.5
                local halfZ   = child.Size.Z * 0.5
                table.insert(rects, {
                    minX = pos.X - halfX, maxX = pos.X + halfX,
                    minZ = pos.Z - halfZ, maxZ = pos.Z + halfZ,
                })
            end
        end
        if #rects == 0 then return nil end
        return rects
    end

    function PointInSquares(x, z, rects)
        local EPS = 0.01
        for _, r in ipairs(rects) do
            if x >= r.minX - EPS and x <= r.maxX + EPS
            and z >= r.minZ - EPS and z <= r.maxZ + EPS then
                return true
            end
        end
        return false
    end

    function StrokeInsideProperty(stroke, rects)
        for _, pt in ipairs(stroke) do
            if not PointInSquares(pt.X, pt.Z, rects) then return false end
        end
        return true
    end

    -- ================================================================
    --  WIRE POINTS EXTRACTION
    -- ================================================================
    local function GetWirePoints(wireObj)
        if not wireObj or not wireObj.Parent then return nil end
        local end1 = wireObj:FindFirstChild("End1")
        local end2 = wireObj:FindFirstChild("End2")
        if not (end1 and end1:IsA("BasePart") and end2 and end2:IsA("BasePart")) then
            return nil
        end
        local middle = {}
        for _, child in ipairs(wireObj:GetChildren()) do
            if child:IsA("BasePart") then
                local n = child.Name:match("^Point(%d+)$")
                if n then table.insert(middle, { idx = tonumber(n), part = child }) end
            end
        end
        table.sort(middle, function(a, b) return a.idx < b.idx end)
        local pts = { end1.Position }
        for _, m in ipairs(middle) do table.insert(pts, m.part.Position) end
        table.insert(pts, end2.Position)
        return pts
    end

    local function GetSelectionAnchor(wires)
        local minX, maxX = math.huge, -math.huge
        local minY       = math.huge
        local minZ, maxZ = math.huge, -math.huge
        local any = false
        for _, w in ipairs(wires) do
            local pts = GetWirePoints(w)
            if pts then
                for _, p in ipairs(pts) do
                    if p.X < minX then minX = p.X end
                    if p.X > maxX then maxX = p.X end
                    if p.Y < minY then minY = p.Y end
                    if p.Z < minZ then minZ = p.Z end
                    if p.Z > maxZ then maxZ = p.Z end
                    any = true
                end
            end
        end
        if not any then return nil end
        return Vector3.new((minX + maxX) * 0.5, minY, (minZ + maxZ) * 0.5)
    end

    local function BuildMoveStrokes(wires)
        local anchor = GetSelectionAnchor(wires)
        if not anchor then return nil, "Could not read wire points" end
        local strokes = {}
        local validWires = {}
        for _, w in ipairs(wires) do
            local pts = GetWirePoints(w)
            if pts and #pts >= 2 then
                local offsets = {}
                for _, p in ipairs(pts) do table.insert(offsets, p - anchor) end
                table.insert(strokes, offsets)
                table.insert(validWires, w)
            end
        end
        if #strokes == 0 then return nil, "No readable wires" end
        return strokes, nil, validWires
    end

    -- ================================================================
    --  BLUEPRINT TEXT BUILD / PARSE
    -- ================================================================
    local function BuildBlueprintText(wires, structures, furniture, relativeToProperty)
        local origin
        if relativeToProperty then
            origin = GetPropertyCenter()
            if not origin then
                return nil, "No owned property found for relative export"
            end
        end

        local function fmt(n)
            local s = string.format("%.7g", n)
            if s == "-0" then s = "0" end
            return s
        end

        -- Compute ONE shared origin from ALL content: wires + structures + furniture
        local sharedOrigin = origin
        if not sharedOrigin then
            local sx, sy, sz, cnt = 0, 0, 0, 0
            for _, w in ipairs(wires or {}) do
                local pts = GetWirePoints(w)
                if pts then
                    for _, p in ipairs(pts) do
                        sx += p.X; sy += p.Y; sz += p.Z; cnt += 1
                    end
                end
            end
            for _, s in ipairs(structures or {}) do
                local c = GetStructureCFrame(s)
                if c then sx += c.Position.X; sy += c.Position.Y; sz += c.Position.Z; cnt += 1 end
            end
            for _, f in ipairs(furniture or {}) do
                local c = f:GetPivot()
                sx += c.Position.X; sy += c.Position.Y; sz += c.Position.Z; cnt += 1
            end
            sharedOrigin = cnt > 0 and Vector3.new(sx/cnt, sy/cnt, sz/cnt) or Vector3.new()
        end

        local function cfRelative(cf)
            return CFrame.new(cf.Position - sharedOrigin) * (CFrame.new(cf.Position):Inverse() * cf)
        end

        local lines = {}
        if relativeToProperty then
            table.insert(lines, "true")
        end

        -- Wires
        local wireLines = {}
        for _, w in ipairs(wires or {}) do
            local pts = GetWirePoints(w)
            if pts and #pts >= 2 then
                local typeName = GetWireTypeName(w) or ""
                local parts    = { typeName }
                local ref = sharedOrigin
                for _, p in ipairs(pts) do
                    local rel = p - ref
                    table.insert(parts, fmt(rel.X) .. "," .. fmt(rel.Y) .. "," .. fmt(rel.Z))
                end
                table.insert(wireLines, table.concat(parts, " | "))
            end
        end
        local hasOther = (#(structures or {}) + #(furniture or {})) > 0
        if #wireLines > 0 then
            if hasOther then table.insert(lines, "[Wires]") end
            for _, l in ipairs(wireLines) do table.insert(lines, l) end
        end

        -- Structures
        if structures and #structures > 0 then

            if groupByTreeValue then
                local groups = {}
                local groupOrder = {}
                for _, s in ipairs(structures) do
                    local tv = GetStructureTreeValue(s) or "(none)"
                    if not groups[tv] then
                        groups[tv] = {}
                        table.insert(groupOrder, tv)
                    end
                    table.insert(groups[tv], s)
                end
                for _, tv in ipairs(groupOrder) do
                    table.insert(lines, "-- " .. tv)
                    for _, s in ipairs(groups[tv]) do
                        local cf = GetStructureCFrame(s)
                        if not cf then continue end
                        local name = GetItemName(s)
                        local tv2  = GetStructureTreeValue(s) or ""
                        table.insert(lines, name .. " | " .. CFrameToString(cfRelative(cf)) .. " | " .. tv2)
                    end
                end
            else
                for _, s in ipairs(structures) do
                    local cf = GetStructureCFrame(s)
                    if not cf then continue end
                    local name = GetItemName(s)
                    local tv   = GetStructureTreeValue(s) or ""
                    table.insert(lines, name .. " | " .. CFrameToString(cfRelative(cf)) .. " | " .. tv)
                end
            end
        end

        -- Furniture
        if furniture and #furniture > 0 then
            for _, f in ipairs(furniture) do
                local cf   = f:GetPivot()
                local name = GetItemName(f)
                table.insert(lines, name .. " | " .. CFrameToString(cfRelative(cf)))
            end
        end

        if #lines == 0 or (#lines == 1 and lines[1] == "true") then
            return nil, "Nothing to export in selection"
        end

        return table.concat(lines, "\n"), nil
    end

    -- Parse a combined file back into tables
    local function ParseCombinedBlueprint(input)
        local wires      = {}
        local wireTypes  = {}
        local structures = {}
        local furniture  = {}
        local skipped    = 0
        local useProperty = false
        local currentSection = "wires"

        local function trim(s) return s:match("^%s*(.-)%s*$") or "" end

        local vars = {}

        local function substituteVars(text)
            return (text:gsub("%$([%a_][%w_]*)", function(name)
                local v = vars[name]
                if v == nil then return "$" .. name end
                return tostring(v)
            end))
        end

        local function matchVarLine(line)
            if line:find("|", 1, true) then return nil end
            local name, value = line:match("^([%a_][%w_]*)%s*=%s*(.+)$")
            if not name then return nil end
            local raw = trim(value)
            local q = raw:match('^"(.*)"$') or raw:match("^'(.*)'$")
            if q then return name, q end
            local n = tonumber(raw)
            if n then return name, n end
            return name, raw
        end

        local normalized = input
            :gsub("\r\n", "\0"):gsub("\r", "\0"):gsub("\n", "\0")

        -- First pass: collect variable definitions
        local headerLocked = false
        local lines = {}
        for line in (normalized .. "\0"):gmatch("([^\0]*)\0") do
            line = trim(line)
            if line ~= "" then
                if not headerLocked then
                    local name, val = matchVarLine(line)
                    if name then
                        vars[name] = val
                    else
                        headerLocked = true
                        table.insert(lines, line)
                    end
                else
                    table.insert(lines, line)
                end
            end
        end

        lines = MergeWrappedLines(lines)

        for _, line in ipairs(lines) do
            line = trim(line)
            if line == "" or line:sub(1,2) == "--" then continue end

            if (line:lower() == "true" or line:lower() == "false") and not line:find("|", 1, true) then
                useProperty = (line:lower() == "true")
                continue
            end

            local sectionHeader = line:match("^%[(.-)%]$")
            if sectionHeader then
                local sl = sectionHeader:lower()
                if sl == "wires"      then currentSection = "wires"
                elseif sl == "structures" then currentSection = "structures"
                elseif sl == "furniture"  then currentSection = "furniture"
                end
                continue
            end

            local fields = {}
            for f in (line .. " | "):gmatch("([^|]*)|") do
                table.insert(fields, trim(f))
            end

            -- Auto-detect section when no header is present:
            -- If we're in "wires" but field 2 looks like a 12-number CFrame, treat as struct/furniture.
            if currentSection == "wires" and #fields >= 2 then
                local f2nums = 0
                for _ in fields[2]:gmatch("[^,]+") do f2nums += 1 end
                if f2nums == 12 then
                    -- 3+ fields = structure (has treeValue slot); 2 fields = furniture
                    if #fields >= 3 then
                        currentSection = "structures"
                    else
                        currentSection = "furniture"
                    end
                end
            end

            if currentSection == "wires" then
                if #fields < 3 then skipped += 1; continue end
                local typeField = (fields[1] ~= "") and fields[1] or nil
                local pts = {}
                for i = 2, #fields do
                    if fields[i] == "" then continue end
                    local xs, ys, zs = fields[i]:match("^([^,]+),([^,]+),([^,]+)$")
                    if xs then
                        local x, y, z = tonumber(xs), tonumber(ys), tonumber(zs)
                        if x and y and z then table.insert(pts, Vector3.new(x, y, z)) end
                    end
                end
                if #pts >= 2 then
                    table.insert(wires, pts)
                    table.insert(wireTypes, typeField)
                else skipped += 1 end
                -- Reset auto-detect after each wire entry
                currentSection = "wires"

            elseif currentSection == "structures" then
                if #fields < 2 then skipped += 1; continue end
                local name = substituteVars(fields[1])
                local cf   = StringToCFrame(substituteVars(fields[2]))
                if not name or name == "" or not cf then skipped += 1; continue end
                local tv = (fields[3] and fields[3] ~= "") and fields[3] or nil
                table.insert(structures, { itemName = name, cf = cf, treeValue = tv })
                currentSection = "wires"  -- reset for next headerless line

            elseif currentSection == "furniture" then
                if #fields < 2 then skipped += 1; continue end
                local name = substituteVars(fields[1])
                local cf   = StringToCFrame(substituteVars(fields[2]))
                if not name or name == "" or not cf then skipped += 1; continue end
                table.insert(furniture, { itemName = name, cf = cf })
                currentSection = "wires"  -- reset for next headerless line
            end
        end

        if useProperty then
            local propCenter = GetPropertyCenter()
            if propCenter then
                for _, entry in ipairs(structures) do
                    local rel = entry.cf
                    entry.cf = CFrame.new(propCenter + rel.Position) * (CFrame.new(rel.Position):Inverse() * rel)
                end
                for _, entry in ipairs(furniture) do
                    local rel = entry.cf
                    entry.cf = CFrame.new(propCenter + rel.Position) * (CFrame.new(rel.Position):Inverse() * rel)
                end
            end
        end

        return wires, wireTypes, structures, furniture, skipped, useProperty
    end

    -- ================================================================
    --  STROKE MAX-LENGTH CHECK
    -- ================================================================
    local function StrokeExceedsMax(stroke, maxDist)
        local total = 0
        for i = 2, #stroke do total += (stroke[i] - stroke[i-1]).Magnitude end
        return total > maxDist
    end

    -- ================================================================
    --  TYPE-AWARE WIRE ASSIGNMENT
    -- ================================================================
    local function AssignWiresByType(typesNeeded, wirePool)
        local buckets   = {}
        local anyBucket = {}
        local used      = {}

        for _, w in ipairs(wirePool) do
            if w and w.Parent then
                local tname = GetWireTypeName(w)
                if tname then
                    buckets[tname] = buckets[tname] or {}
                    table.insert(buckets[tname], w)
                else
                    table.insert(anyBucket, w)
                end
            end
        end

        local needCount = {}
        local anyCount  = 0
        for _, tname in ipairs(typesNeeded) do
            if tname and tname ~= "" then
                needCount[tname] = (needCount[tname] or 0) + 1
            else anyCount += 1 end
        end

        local missing = {}
        for tname, need in pairs(needCount) do
            local have = (buckets[tname] and #buckets[tname]) or 0
            if have < need then table.insert(missing, { type = tname, need = need, have = have }) end
        end
        local leftoverForAny = #anyBucket
        for tname, need in pairs(needCount) do
            local have = (buckets[tname] and #buckets[tname]) or 0
            if have > need then leftoverForAny += (have - need) end
        end
        if leftoverForAny < anyCount then
            table.insert(missing, { type = "(any)", need = anyCount, have = leftoverForAny })
        end
        if #missing > 0 then return nil, false, missing end

        local assignments = {}
        for i, tname in ipairs(typesNeeded) do
            if tname and tname ~= "" then
                local bucket = buckets[tname]
                local picked
                if bucket then
                    for j = 1, #bucket do
                        local w = bucket[j]
                        if w and w.Parent and not used[w] then
                            picked = w; used[w] = true; break
                        end
                    end
                end
                assignments[i] = picked
            end
        end
        local function takeAny()
            for _, w in ipairs(anyBucket) do
                if w and w.Parent and not used[w] then used[w] = true; return w end
            end
            for _, bucket in pairs(buckets) do
                for _, w in ipairs(bucket) do
                    if w and w.Parent and not used[w] then used[w] = true; return w end
                end
            end
            return nil
        end
        for i, tname in ipairs(typesNeeded) do
            if (not tname) or tname == "" then assignments[i] = takeAny() end
        end

        return assignments, true, nil
    end

    local function FormatMissingReport(missing)
        local parts = {}
        for _, m in ipairs(missing) do
            table.insert(parts, m.type .. ": need " .. m.need .. ", have " .. m.have)
        end
        return "Missing wires — " .. table.concat(parts, "; ")
    end

    -- ================================================================
    --  LETTER DEFINITIONS
    -- ================================================================
    local function GetLetterPoints(letter, origin)
        local s  = Settings.Scale
        local t  = s
        local m  = s * 0.5
        local b  = 0
        local l  = -s * 0.4
        local r  =  s * 0.4
        local c  =  0
        local v3 = Vector3.new

        local function o(tbl)
            local out = {}
            for _, v in ipairs(tbl) do table.insert(out, origin + v) end
            return out
        end
        local function OS(...)
            return {o({...})}
        end
        local function OM(...)
            local result = {}
            for _, stroke in ipairs({...}) do table.insert(result, o(stroke)) end
            return result
        end

        local map = {
            A = OS(v3(l,b,0),v3(c,t,0),v3(r,b,0), v3((c+r)/2,m,0),v3((c+l)/2,m,0)),
            B = OS(v3(l,b,0),v3(l,t,0),v3(r*.6,t,0),v3(r,t*.75,0),v3(r*.6,m,0),v3(l,m,0),v3(r*.6,m,0),v3(r,m*.4,0),v3(r*.6,b,0),v3(l,b,0)),
            C = OS(v3(r,t,0),v3(l,t,0),v3(l,b,0),v3(r,b,0)),
            D = OS(v3(l,t,0),v3(l,b,0),v3(r,b+m*.3,0),v3(r,t-m*.3,0),v3(l,t,0)),
            E = OS(v3(r,t,0),v3(l,t,0),v3(l,b,0),v3(r,b,0), v3(l,b,0),v3(l,m,0),v3(r*.7,m,0)),
            F = OS(v3(l,b,0),v3(l,t,0),v3(r,t,0), v3(l,t,0),v3(l,m,0),v3(r*.7,m,0)),
            G = OS(v3(r,t,0),v3(l,t,0),v3(l,b,0),v3(r,b,0),v3(r,m,0),v3(c,m,0)),
            H = OS(v3(l,t,0),v3(l,b,0), v3(l,m,0),v3(r,m,0), v3(r,t,0),v3(r,b,0)),
            I = OS(v3(l,t,0),v3(r,t,0), v3(c,t,0),v3(c,b,0), v3(l,b,0),v3(r,b,0)),
            J = OS(v3(l,t,0),v3(r,t,0), v3(c,t,0),v3(c,b+m*.2,0),v3(l*.7,b,0),v3(l,b+m*.2,0)),
            K = OS(v3(l,t,0),v3(l,b,0), v3(l,m,0),v3(r,t,0), v3(l,m,0),v3(r,b,0)),
            L = OS(v3(l,t,0),v3(l,b,0),v3(r,b,0)),
            M = OS(v3(l,b,0),v3(l,t,0),v3(c,m,0),v3(r,t,0),v3(r,b,0)),
            N = OS(v3(l,b,0),v3(l,t,0),v3(r,b,0),v3(r,t,0)),
            O = OS(v3(l,t,0),v3(r,t,0),v3(r,b,0),v3(l,b,0),v3(l,t,0)),
            P = OS(v3(l,b,0),v3(l,t,0),v3(r,t,0),v3(r,m,0),v3(l,m,0)),
            Q = OS(v3(l,t,0),v3(r,t,0),v3(r,b,0),v3(l,b,0),v3(l,t,0), v3(r*.3,b+m*.3,0),v3(r,b,0)),
            R = OS(v3(l,b,0),v3(l,t,0),v3(r,t,0),v3(r,m,0),v3(l,m,0), v3(r,b,0)),
            S = OS(v3(r,t,0),v3(l,t,0),v3(l,m,0),v3(r,m,0),v3(r,b,0),v3(l,b,0)),
            T = OS(v3(l,t,0),v3(r,t,0), v3(c,t,0),v3(c,b,0)),
            U = OS(v3(l,t,0),v3(l,b,0),v3(r,b,0),v3(r,t,0)),
            V = OS(v3(l,t,0),v3(c,b,0),v3(r,t,0)),
            W = OS(v3(l,t,0),v3(l*.5,b,0),v3(c,m,0),v3(r*.5,b,0),v3(r,t,0)),
            X = OS(v3(l,t,0),v3(r,b,0), v3(c,m,0),v3(l,b,0),v3(r,t,0)),
            Y = OS(v3(l,t,0),v3(c,m,0),v3(r,t,0), v3(c,m,0),v3(c,b,0)),
            Z = OS(v3(l,t,0),v3(r,t,0),v3(l,b,0),v3(r,b,0)),
            ["0"] = OS(v3(l,t,0),v3(r,t,0),v3(r,b,0),v3(l,b,0),v3(l,t,0),v3(r,b,0)),
            ["1"] = OS(v3(l,t*.7,0), v3(c,t,0), v3(c,b,0), v3(l,b,0), v3(r,b,0)),
            ["2"] = OS(v3(l,t*.8,0),v3(r*.6,t,0),v3(r,t*.5,0),v3(l,m*.3,0),v3(l,b,0),v3(r,b,0)),
            ["3"] = OS(v3(l,t,0),v3(r,t,0),v3(r,m,0),v3(l*.4,m,0), v3(r,m,0),v3(r,b,0),v3(l,b,0)),
            ["4"] = OS(v3(l,t,0),v3(l,m,0),v3(r,m,0), v3(r,t,0),v3(r,b,0)),
            ["5"] = OS(v3(r,t,0),v3(l,t,0),v3(l,m,0),v3(r,m,0),v3(r,b,0),v3(l,b,0)),
            ["6"] = OS(v3(r,t,0),v3(l,t,0),v3(l,b,0),v3(r,b,0),v3(r,m,0),v3(l*.2,m,0)),
            ["7"] = OS(v3(l,t,0), v3(r,t,0), v3(r*.3,m,0), v3(l*.45,m,0), v3(r*.3,m,0), v3(l*.2,b,0)),
            ["8"] = OS(v3(c,m,0),v3(l,m*1.3,0),v3(l,t,0),v3(r,t,0),v3(r,m*1.3,0),v3(c,m,0),v3(l,m*.7,0),v3(l,b,0),v3(r,b,0),v3(r,m*.7,0),v3(c,m,0)),
            ["9"] = OS(v3(r,b,0),v3(r,t,0),v3(l,t,0),v3(l,m,0),v3(r,m,0)),
            ["-"]  = OS(v3(l*.8,m,0), v3(r*.8,m,0)),
            ["_"]  = OS(v3(l,b,0), v3(r,b,0)),
            ["="]  = OM({v3(l*.8,m+s*.15,0), v3(r*.8,m+s*.15,0)},{v3(l*.8,m-s*.15,0), v3(r*.8,m-s*.15,0)}),
            ["+"]  = OM({v3(l*.8,m,0),  v3(r*.8,m,0)},{v3(c,t*.85,0), v3(c,s*.08,0)}),
            ["["]  = OS(v3(r*.55,t,0),v3(l*.55,t,0),v3(l*.55,b,0),v3(r*.55,b,0)),
            ["]"]  = OS(v3(l*.55,t,0),v3(r*.55,t,0),v3(r*.55,b,0),v3(l*.55,b,0)),
            ["\\"] = OS(v3(l,t,0),v3(r,b,0)),
            ["|"]  = OS(v3(c,t,0),v3(c,b,0)),
            [";"]  = OM({v3(c,m*1.45,0), v3(l*.12,m*1.2,0)},{v3(c,m*.75,0),  v3(l*.4,s*.06,0)}),
            [":"]  = OM({v3(c - 0.25, m*1.45, 0), v3(c + 0.25, m*1.45, 0)},{v3(c - 0.25, m*.55,  0), v3(c + 0.25, m*.55,  0)}),
            ["'"]  = OS(v3(c,t,0),v3(c,t*.72,0)),
            ['"']  = OM({v3(l*.42,t,0), v3(l*.42,t*.72,0)},{v3(r*.42,t,0), v3(r*.42,t*.72,0)}),
            [","]  = OS(v3(c,m*.3,0),v3(l*.4,s*.05,0)),
            ["<"]  = OS(v3(r*.7,t,0),v3(l,m,0),v3(r*.7,b,0)),
            [">"]  = OS(v3(l*.7,t,0),v3(r,m,0),v3(l*.7,b,0)),
            ["."]  = OS(v3(l*.2,s*.1,0),v3(r*.2,s*.1,0)),
            ["/"]  = OS(v3(l,b,0),v3(r,t,0)),
            ["?"]  = OM({v3(l,t*.8,0),v3(c,t,0),v3(r,t*.8,0),v3(r,m*1.5,0),v3(c,m*1.1,0),v3(c,m*.5,0)},{v3(l*.2,s*.1,0), v3(r*.2,s*.1,0)}),
            ["!"]  = OM({v3(c,t,0),    v3(c,m*.55,0)},{v3(l*.22,s*.1,0), v3(r*.22,s*.1,0)}),
            ["#"]  = OM({v3(l*.3,t*.9,0),   v3(l*.3,s*.08,0)},{v3(r*.3,t*.9,0),   v3(r*.3,s*.08,0)},{v3(l*.82,m*1.35,0),v3(r*.82,m*1.35,0)},{v3(l*.82,m*.65,0), v3(r*.82,m*.65,0)}),
            ["^"]  = OS(v3(l*.75,m,0),v3(c,t,0),v3(r*.75,m,0)),
        }

        return map[letter:upper()] or map[letter]
    end

    -- ================================================================
    --  PREVIEW POOL
    -- ================================================================
    local linePool    = {}
    local ballPool    = {}
    local activeLines = {}
    local activeBalls = {}
    local lineIndex   = 0
    local ballIndex   = 0

    local function BeginPreview()  lineIndex = 0; ballIndex = 0 end

    local function EndPreview()
        for i = lineIndex + 1, #activeLines do
            local p = activeLines[i]
            if p.Size.Z ~= 0 then p.Size = Vector3.new(0, 0, 0) end
        end
        for i = ballIndex + 1, #activeBalls do
            local p = activeBalls[i]
            if p.Size.X ~= 0 then p.Size = Vector3.new(0, 0, 0) end
        end
    end

    local function AcquireLine()
        lineIndex += 1
        local part = activeLines[lineIndex]
        if not part then
            part = table.remove(linePool)
            if not part then
                part            = Instance.new("Part")
                part.Anchored   = true
                part.CanCollide = false
                part.CastShadow = false
                part.Material   = Enum.Material.Neon
                part.Color = Color3.fromRGB(27, 42, 53)
            end
            activeLines[lineIndex] = part
        end
        part.Parent = PreviewModel
        return part
    end

    local function AcquireBall()
        ballIndex += 1
        local part = activeBalls[ballIndex]
        if not part then
            part = table.remove(ballPool)
            if not part then
                part            = Instance.new("Part")
                part.Anchored   = true
                part.CanCollide = false
                part.Shape      = Enum.PartType.Ball
                part.Material   = Enum.Material.Neon
                part.Color = Color3.fromRGB(27, 42, 53)
                part.Size       = Vector3.new(0.2, 0.2, 0.2)
            end
            activeBalls[ballIndex] = part
        end
        part.Parent = PreviewModel
        return part
    end

    local function ClearPreview()
        for i = 1, #activeLines do
            local p = activeLines[i]; p.Parent = nil; table.insert(linePool, p)
        end
        for i = 1, #activeBalls do
            local p = activeBalls[i]; p.Parent = nil; table.insert(ballPool, p)
        end
        table.clear(activeLines); table.clear(activeBalls)
        lineIndex = 0; ballIndex = 0
    end

    local function DrawPreviewLine(a, b)
        local dist = (b - a).Magnitude
        if dist < 0.01 then return end
        local part  = AcquireLine()
        part.Size   = Vector3.new(0.15, 0.15, dist)
        part.CFrame = CFrame.new((a + b) / 2, b)
    end

    local function DrawPreviewBall(pos)
        local part  = AcquireBall()
        part.CFrame = CFrame.new(pos)
        if part.Size.X == 0 then part.Size = Vector3.new(0.3, 0.3, 0.3) end
    end

    local function DrawLetterPreview(strokes)
        for _, stroke in ipairs(strokes) do
            for i, point in ipairs(stroke) do
                if i < #stroke then DrawPreviewLine(point, stroke[i + 1]) end
                if i > 1 and i < #stroke then DrawPreviewBall(point) end
            end
        end
    end

    local function RotateStrokes(rawStrokes, letterOrigin)
        local rotated = {}
        for _, stroke in ipairs(rawStrokes) do
            local rotatedStroke = {}
            for _, pt in ipairs(stroke) do
                local offset        = pt - letterOrigin
                local rotatedOffset = WireRotation:VectorToWorldSpace(offset)
                table.insert(rotatedStroke, letterOrigin + rotatedOffset)
            end
            table.insert(rotated, rotatedStroke)
        end
        return rotated
    end

    function MergeWrappedLines(lineList)
        local merged = {}
        for _, line in ipairs(lineList) do
            local trimmed = line:match("^%s*(.-)%s*$") or ""
            local isContinuation = false
            if trimmed:sub(1, 1) == "|" then
                isContinuation = true
            else
                local firstField = (trimmed:match("^([^|]*)") or ""):match("^%s*(.-)%s*$") or ""
                isContinuation = firstField:match("^%-?%d[%d%.]*%s*,%s*%-?%d[%d%.]*%s*,%s*%-?%d[%d%.]*$") ~= nil
            end
            if isContinuation and #merged > 0 then
                merged[#merged] = merged[#merged] .. " | " .. trimmed
            else
                table.insert(merged, line)
            end
        end
        return merged
    end

    -- ================================================================
    --  BLUEPRINT PARSER  (wire-only legacy format)
    -- ================================================================
    local function ParseBlueprint(input)
        local parsed      = {}
        local types       = {}
        local skipped     = 0
        local MIN_DIST    = 0
        local useProperty = false
        local vars        = {}

        local normalized = input
            :gsub("\r\n", "\0"):gsub("\r", "\0"):gsub("\n", "\0"):gsub("||", "\0")

        local function trim(s) return s:match("^%s*(.-)%s*$") or "" end

        local function isBoolHeader(line)
            if line:find("|", 1, true) then return false end
            local low = line:lower()
            return low == "true" or low == "false"
        end

        local function matchVarLine(line)
            if line:find("|", 1, true) then return nil end
            local name, value = line:match("^([%a_][%w_]*)%s*=%s*(.+)$")
            if not name then return nil end
            return name, trim(value)
        end

        local function coerceValue(raw)
            local q = raw:match('^"(.*)"$') or raw:match("^'(.*)'$")
            if q then return q end
            local n = tonumber(raw)
            if n then return n end
            return raw
        end

        local function substituteVars(text)
            return (text:gsub("%$([%a_][%w_]*)", function(name)
                local v = vars[name]
                if v == nil then return "$" .. name end
                return tostring(v)
            end))
        end

        local function evalNumeric(expr)
            local n = tonumber(expr)
            if n then return n end
            local pos = 1
            local function peek()
                while pos <= #expr and expr:sub(pos, pos):match("%s") do pos += 1 end
                return expr:sub(pos, pos)
            end
            local function consume() local c = peek(); pos += 1; return c end
            local parseExpr
            local function parseNumber()
                local start = pos
                while pos <= #expr do
                    local c = expr:sub(pos, pos)
                    if c:match("[%d%.]") then pos += 1 else break end
                end
                return tonumber(expr:sub(start, pos - 1))
            end
            local function parsePrimary()
                local c = peek()
                if c == "(" then consume(); local v = parseExpr(); if peek() ~= ")" then return nil end; consume(); return v
                elseif c == "-" then consume(); local v = parsePrimary(); if v == nil then return nil end; return -v
                elseif c == "+" then consume(); return parsePrimary()
                elseif c:match("[%d%.]") then return parseNumber() end
                return nil
            end
            local function parseTerm()
                local v = parsePrimary(); if v == nil then return nil end
                while true do
                    local c = peek()
                    if c == "*" or c == "/" then
                        consume(); local rhs = parsePrimary(); if rhs == nil then return nil end
                        if c == "*" then v = v * rhs else if rhs == 0 then return nil end; v = v / rhs end
                    else break end
                end
                return v
            end
            parseExpr = function()
                local v = parseTerm(); if v == nil then return nil end
                while true do
                    local c = peek()
                    if c == "+" or c == "-" then
                        consume(); local rhs = parseTerm(); if rhs == nil then return nil end
                        if c == "+" then v = v + rhs else v = v - rhs end
                    else break end
                end
                return v
            end
            local result = parseExpr()
            if peek() ~= "" then return nil end
            return result
        end

        local headerLocked = false
        local pendingWireLines = {}

        for wireDef in (normalized .. "\0"):gmatch("([^\0]*)\0") do
            wireDef = trim(wireDef)
            if wireDef ~= "" then
                if not headerLocked and isBoolHeader(wireDef) then
                    useProperty = (wireDef:lower() == "true")
                elseif not headerLocked then
                    local name, rawValue = matchVarLine(wireDef)
                    if name then vars[name] = coerceValue(rawValue)
                    else headerLocked = true; table.insert(pendingWireLines, wireDef) end
                else table.insert(pendingWireLines, wireDef) end
            end
        end

        pendingWireLines = MergeWrappedLines(pendingWireLines)

        for _, wireDef in ipairs(pendingWireLines) do
            local raw       = {}
            local typeField = nil
            local partIndex = 0
            for part in (wireDef .. "|"):gmatch("([^|]*)|") do
                part = trim(part); partIndex += 1
                if partIndex == 1 then
                    if part ~= "" then
                        local sub = substituteVars(part)
                        local unq = sub:match('^"(.*)"$') or sub:match("^'(.*)'$") or sub
                        if unq ~= "" then typeField = unq end
                    end
                elseif part ~= "" then
                    local sub = substituteVars(part)
                    local xs, ys, zs = sub:match("^([^,]+),([^,]+),([^,]+)$")
                    if xs then
                        local x = evalNumeric(trim(xs))
                        local y = evalNumeric(trim(ys))
                        local z = evalNumeric(trim(zs))
                        if x and y and z then table.insert(raw, Vector3.new(x, y, z)) end
                    end
                end
            end

            if #raw < 2 then skipped += 1
            else
                local points = { raw[1] }
                for i = 2, #raw do
                    if (raw[i] - raw[i-1]).Magnitude >= MIN_DIST then table.insert(points, raw[i]) end
                end
                if #points < 2 then skipped += 1
                else table.insert(parsed, points); table.insert(types, typeField) end
            end
        end

        return parsed, types, skipped, useProperty
    end

    -- ── Text art preview ──
    local function UpdatePreview(origin, word)
        if not word or word == "" then return end
        local maxDist = DEFAULT_MAX
        if placementWires and placementWires[1] then
            maxDist = GetWireMaxLength(placementWires[1])
        end
        local rects = GetPropertySquares()
        local posIndex = 0
        for i = 1, #word do
            local ch = word:sub(i, i)
            if ch ~= " " then
                local letterOrigin = origin + WireRotation:VectorToWorldSpace(
                    Vector3.new(posIndex * Settings.Spacing, 0, 0)
                )
                local rawStrokes = GetLetterPoints(ch, letterOrigin)
                if rawStrokes then
                    local rotated = RotateStrokes(rawStrokes, letterOrigin)
                    for _, stroke in ipairs(rotated) do
                        local lengthOk = not StrokeExceedsMax(stroke, maxDist)
                        local boundsOk = (not rects) or StrokeInsideProperty(stroke, rects)
                        if lengthOk and boundsOk then DrawLetterPreview({stroke}) end
                    end
                end
            end
            posIndex += 1
        end
    end

    -- ── Blueprint preview ──
    local function UpdateBlueprintPreview(origin)
        local rects = GetPropertySquares()
        for i, offsetStroke in ipairs(blueprintWires) do
            local maxDist = DEFAULT_MAX
            local assignedWire = placementWires[i]
            if assignedWire then maxDist = GetWireMaxLength(assignedWire) end
            local worldStroke = {}
            for _, offset in ipairs(offsetStroke) do
                table.insert(worldStroke, origin + WireRotation:VectorToWorldSpace(offset))
            end
            local lengthOk = not StrokeExceedsMax(worldStroke, maxDist)
            local boundsOk = (not rects) or StrokeInsideProperty(worldStroke, rects)
            if lengthOk and boundsOk then DrawLetterPreview({worldStroke}) end
        end
    end

    -- ================================================================
    --  RAYCAST
    -- ================================================================
    local RayParams      = RaycastParams.new()
    RayParams.FilterType = Enum.RaycastFilterType.Exclude

    local function GetCursorWorldPos()
        RayParams.FilterDescendantsInstances = {PreviewModel, Character}
        local unitRay = workspace.CurrentCamera:ScreenPointToRay(Mouse.X, Mouse.Y)
        local result  = workspace:Raycast(unitRay.Origin, unitRay.Direction * 500, RayParams)
        if result then return result.Position end
        local t = -unitRay.Origin.Y / unitRay.Direction.Y
        if t and t > 0 then return unitRay.Origin + unitRay.Direction * t end
        return unitRay.Origin + unitRay.Direction * 50
    end

    -- ================================================================
    --  PLACE LOGIC
    -- ================================================================
    local function FireWire(wireObj, points, Info)
        DrawLetterPreview({points})
        local attempts = 0
        repeat
            ReplicatedStorage.PlaceStructure.ClientPlacedWire:FireServer(
                Info, points, LocalPlayer, wireObj, true
            )
            task.wait(0.25)
            attempts += 1
        until wireObj.Parent == nil or attempts >= 10
        ClearPreview()
        task.wait(0.2)
    end

    local currentWord   = ""
    local ActionElement = nil
    local MoveElement   = nil
    local PreviewActive = false

    local keepSelection    = false
    local exportToProperty = false

    local function PruneDeadWires()
        local alive = {}
        for _, wire in ipairs(SelectedWires) do
            if wire and wire.Parent then table.insert(alive, wire) end
        end
        SelectedWires = alive
        local aliveS = {}
        for _, s in ipairs(SelectedStructures) do
            if s and s.Parent then table.insert(aliveS, s) end
        end
        SelectedStructures = aliveS
        local aliveF = {}
        for _, f in ipairs(SelectedFurniture) do
            if f and f.Parent then table.insert(aliveF, f) end
        end
        SelectedFurniture = aliveF
        local aliveB = {}
        for _, b in ipairs(SelectedBlueprints) do
            if b and b.Parent then table.insert(aliveB, b) end
        end
        SelectedBlueprints = aliveB
        UpdateSelectionVisuals()
    end

    local function StopPlacing()
        PlaceMode      = false
        Placing        = false
        PreviewActive  = false
        BlueprintMode  = false
        MoveMode       = false
        WireRotation   = CFrame.new()
        placementWires = {}
        blueprintWires = {}
        blueprintTypes = {}
        moveWires      = {}
        moveStrokes    = {}
        moveStructures = {}
        moveFurniture  = {}
        moveBlueprints = {}
        for _, clone in ipairs(movePreviewModels) do
            pcall(function() clone:Destroy() end)
        end
        movePreviewModels  = {}
        pendingStructures  = {}
        pendingFurniture   = {}
        pendingIsWorldSpace = false
        usePropertyOrigin = false
        ClearPreview()
        ClearPlankOutlines()
        structureUseIndex = {}
        LassoDragging = false
        if LassoFrame then LassoFrame.Visible = false end
        if not keepSelection then
            ClearSelection()
        else
            PruneDeadWires()
        end
        if ActionElement then
            ActionElement:SetText("Start")
            ActionElement:SetDisabled(false)
        end
        if BlueprintBuild then
            BlueprintBuild:SetText("Start")
            BlueprintBuild:SetDisabled(false)
        end
        if MoveElement then
            MoveElement:SetText("Move")
            MoveElement:SetDisabled(false)
        end
    end

    local function StartPlacing()
        local word = currentWord:upper():gsub("[^A-Z0-9 %-_=+%[%]\\|;:'\",./<>?!#%^]", "")
        if word:gsub(" ", "") == "" then
            Library:Notify("Blueprints", "Enter some text first!")
            return
        end
        if #SelectedWires == 0 then
            Library:Notify("Blueprints", "No wires selected! Use Click Selection or Select All first.", 4)
            return
        end
        placementWires = SelectedWires
        local needed = 0
        for i = 1, #word do
            local ch = word:sub(i,i)
            if ch ~= " " then
                local strokes = GetLetterPoints(ch, Vector3.new())
                needed += (strokes and #strokes or 1)
            end
        end
        if #placementWires < needed then
            Library:Notify("Blueprints", "Need " .. needed .. " wires, selected " .. #placementWires .. "!")
            return
        end
        PlaceMode     = true
        PreviewActive = true
        Library:Notify("Blueprints", "Preview active — left-click to place!")
        if ActionElement then ActionElement:SetText("Cancel") end
    end

    -- ================================================================
    --  PLACEMENT HELPERS (structures, furniture, blueprints)
    -- ================================================================
    local PLACE_TIMEOUT = 8

    local function PlaceWithConfirmation(pm, fireFunc, matchFunc, excludeSet, timeout)
        timeout = timeout or PLACE_TIMEOUT

        local before = {}
        for _, m in ipairs(pm:GetChildren()) do
            before[m] = true
        end

        local deadline  = tick() + timeout
        local retryAt   = 0

        while tick() < deadline do
            if tick() >= retryAt then
                fireFunc()
                retryAt = tick() + 1
            end

            for _, m in ipairs(pm:GetChildren()) do
                if before[m] then continue end
                if excludeSet and excludeSet[m] then continue end
                if matchFunc(m) then
                    if excludeSet then excludeSet[m] = true end
                    return true, m
                end
            end

            task.wait()
        end

        return false, nil
    end

    local function PlaceOneStructure(srcModel, newCF, treeValue, destroyAfter, excludeSet)
        if not ClientPlacedStructure then return false end
        if not srcModel or not srcModel.Parent then return false end
        local itemName = GetItemName(srcModel)

        local pm = workspace:FindFirstChild("PlayerModels")
        if not pm then return false end

        local function fireFunc()
            ClientPlacedStructure:FireServer(itemName, newCF, LocalPlayer, treeValue or false, srcModel, true)
        end
        local function matchFunc(m)
            local typeVal = m:FindFirstChild("Type")
            if not typeVal or (typeVal.Value ~= "Structure" and typeVal.Value ~= "Vehicle Spot") then return false end
            if m:FindFirstChild("PurchasedBoxItemName") then return false end
            local ownerFolder = m:FindFirstChild("Owner")
            local ownerStr    = ownerFolder and ownerFolder:FindFirstChild("OwnerString")
            if not ownerStr or ownerStr.Value ~= LocalPlayer.Name then return false end
            local iname = m:FindFirstChild("ItemName")
            if iname and iname.Value ~= "" and iname.Value ~= itemName then return false end
            return true
        end

        local ok, newModel = PlaceWithConfirmation(pm, fireFunc, matchFunc, excludeSet)
        if not ok then
            warn(("[Blueprints] Structure timed out: %s"):format(itemName))
            return false
        end

        if destroyAfter and srcModel and srcModel.Parent and DestroyStructure then
            pcall(DestroyStructure.FireServer, DestroyStructure, srcModel)
        end
        return true
    end

    -- Places a boxed (PurchasedBox) structure at a specific CFrame.
    --
    -- Correct signature found in reference's Spawn Building section:
    --   FireServer(itemName, newCF, LocalPlayer, nil, srcModel, false, true)
    --   6th arg = false, 7th arg = true — different from placed structures (true, no 7th).
    -- Confirmation: the box disappears from PlayerModels (srcModel.Parent == nil).
    local function PlaceOneBoxedStructure(srcModel, newCF)
        if not ClientPlacedStructure then return false end
        if not srcModel or not srcModel.Parent then return false end
        local itemName = GetItemName(srcModel)
        local attempts = 0
        repeat
            ClientPlacedStructure:FireServer(itemName, newCF, LocalPlayer, nil, srcModel, false, true)
            task.wait(0.25)
            attempts += 1
        until srcModel.Parent == nil or attempts >= 10
        if srcModel.Parent ~= nil then
            warn(("[Blueprints] Boxed structure timed out: %s"):format(itemName))
            return false
        end
        return true
    end
    local function PlaceOneFurniture(srcModel, newCF, destroyAfter, excludeSet)
        if not ClientPlacedStructure then return false end
        if not srcModel or not srcModel.Parent then return false end
        local itemName = GetItemName(srcModel)

        local pm = workspace:FindFirstChild("PlayerModels")
        if not pm then return false end

        local function fireFunc()
            ClientPlacedStructure:FireServer(itemName, newCF, LocalPlayer, false, srcModel, true)
        end
        local function matchFunc(m)
            local typeVal = m:FindFirstChild("Type")
            if not typeVal or typeVal.Value ~= "Furniture" then return false end
            if m:FindFirstChild("PurchasedBoxItemName") then return false end
            local ownerFolder = m:FindFirstChild("Owner")
            local ownerStr    = ownerFolder and ownerFolder:FindFirstChild("OwnerString")
            if not ownerStr or ownerStr.Value ~= LocalPlayer.Name then return false end
            local iname = m:FindFirstChild("ItemName")
            if iname and iname.Value ~= "" and iname.Value ~= itemName then return false end
            return true
        end

        local ok, newModel = PlaceWithConfirmation(pm, fireFunc, matchFunc, excludeSet)
        if not ok then
            warn(("[Blueprints] Furniture timed out: %s"):format(itemName))
            return false
        end

        if destroyAfter and srcModel and srcModel.Parent and DestroyStructure then
            pcall(DestroyStructure.FireServer, DestroyStructure, srcModel)
        end
        return true
    end

    -- ================================================================
    --  PlaceOneBlueprintFromFile
    --  Places a blueprint via ClientPlacedBlueprint and, once confirmed,
    --  teleports a matching plank into it via LOT.
    --  This is ONLY used by the Build File path — NOT by Move Selection.
    -- ================================================================
    local function PlaceOneBlueprintFromFile(itemName, newCF, treeValue, excludeSet)
        if not ClientPlacedBlueprint then return false, nil end

        local pm = workspace:FindFirstChild("PlayerModels")
        if not pm then return false, nil end

        local function fireFunc()
            ClientPlacedBlueprint:FireServer(itemName, newCF, LocalPlayer)
        end
        local function matchFunc(m)
            local typeVal = m:FindFirstChild("Type")
            if not typeVal or typeVal.Value ~= "Blueprint" then return false end
            local ownerFolder = m:FindFirstChild("Owner")
            local ownerStr    = ownerFolder and ownerFolder:FindFirstChild("OwnerString")
            if not ownerStr or ownerStr.Value ~= LocalPlayer.Name then return false end
            local iname = m:FindFirstChild("ItemName")
            if iname and iname.Value ~= "" and iname.Value ~= itemName then return false end
            return true
        end

        local ok, newModel = PlaceWithConfirmation(pm, fireFunc, matchFunc, excludeSet)
        if not ok then
            warn(("[Blueprints] Blueprint timed out (file build): %s"):format(itemName))
            return false, nil
        end

        -- Auto-fill: teleport plank to blueprint once via LOT, then pin it
        -- in place by directly setting CFrame every 0.1s until the blueprint
        -- disappears (filled) or times out (60s). Direct CFrame avoids physics
        -- so elevated blueprints don't drop the plank to the floor.
        if LOT and newModel and newModel.Parent then
            local entry = GetNextPlankForClass(treeValue)
            if entry then
                local function getBlueprintCenter(bp)
                    if bp.PrimaryPart then return bp.PrimaryPart.Position end
                    local sum, count = Vector3.new(), 0
                    for _, p in ipairs(bp:GetDescendants()) do
                        if p:IsA("BasePart") then sum += p.Position; count += 1 end
                    end
                    return count > 0 and (sum / count) or Vector3.new()
                end

                -- Initial teleport via LOT to get the plank to the right place
                LOT.TeleportObjectTo(entry.part, CFrame.new(getBlueprintCenter(newModel)))
                if LOT.WaitForBatch then LOT.WaitForBatch() end

                -- Pin loop: keep CFrame-locking the plank until blueprint is gone
                local deadline = tick() + 3
                while newModel and newModel.Parent and tick() < deadline do
                    if entry.part and entry.part.Parent then
                        local target = getBlueprintCenter(newModel)
                        entry.part.CFrame    = CFrame.new(target)
                        entry.part.Velocity  = Vector3.zero
                        entry.part.RotVelocity = Vector3.zero
                    end
                    task.wait(0.1)
                end
            else
                warn(("[Blueprints] No filtered plank for class '%s'"):format(tostring(treeValue)))
            end
        end

        return true, newModel
    end

    -- Original PlaceOneBlueprint kept for Move Selection (no plank fill)
    local function PlaceOneBlueprint(srcModel, newCF, destroyAfter, excludeSet)
        if not ClientPlacedBlueprint then return false end
        if not srcModel or not srcModel.Parent then return false end
        local itemName = GetItemName(srcModel)

        local pm = workspace:FindFirstChild("PlayerModels")
        if not pm then return false end

        local function fireFunc()
            ClientPlacedBlueprint:FireServer(itemName, newCF, LocalPlayer)
        end
        local function matchFunc(m)
            local typeVal = m:FindFirstChild("Type")
            if not typeVal or typeVal.Value ~= "Blueprint" then return false end
            local ownerFolder = m:FindFirstChild("Owner")
            local ownerStr    = ownerFolder and ownerFolder:FindFirstChild("OwnerString")
            if not ownerStr or ownerStr.Value ~= LocalPlayer.Name then return false end
            local iname = m:FindFirstChild("ItemName")
            if iname and iname.Value ~= "" and iname.Value ~= itemName then return false end
            return true
        end

        local ok, newModel = PlaceWithConfirmation(pm, fireFunc, matchFunc, excludeSet)
        if not ok then
            warn(("[Blueprints] Blueprint timed out: %s"):format(itemName))
            return false
        end

        if destroyAfter and srcModel and srcModel.Parent and DestroyStructure then
            pcall(DestroyStructure.FireServer, DestroyStructure, srcModel)
        end
        return true
    end

    -- FindSourceStructure: returns a selected structure matching itemName.
    -- Only searches SelectedStructures — never grabs unselected objects from the plot.
    -- Uses round-robin so each selected instance is consumed once per build.
    -- Returns nil if nothing selected matches (caller will skip that entry).
    local structureUseIndex = {}  -- tracks next index per itemName within SelectedStructures
    local function FindSourceStructure(itemName)
        if #SelectedStructures == 0 then return nil end
        local startIdx = structureUseIndex[itemName] or 1
        for attempt = 1, #SelectedStructures do
            local idx = ((startIdx - 1 + attempt - 1) % #SelectedStructures) + 1
            local model = SelectedStructures[idx]
            if model and model.Parent and GetItemName(model) == itemName then
                structureUseIndex[itemName] = (idx % #SelectedStructures) + 1
                return model
            end
        end
        return nil
    end

    local function FindSourceFurniture(itemName)
        local pm = workspace:FindFirstChild("PlayerModels")
        if not pm then return nil end
        for _, model in ipairs(pm:GetChildren()) do
            local typeVal = model:FindFirstChild("Type")
            if not typeVal or typeVal.Value ~= "Furniture" then continue end
            if model:FindFirstChild("PurchasedBoxItemName") then continue end
            if not IsOwnedByLocalPlayer(model) then continue end
            if GetItemName(model) == itemName then return model end
        end
        return nil
    end

    -- ================================================================
    --  UI ELEMENTS
    -- ================================================================
    InitLassoGui()

    Tab:CreateSection("Selection Tools")

    local ClickToggle, LassoToggle, GroupSelectToggle

    ClickToggle = Tab:CreateToggle("Click Selection", false, function(val)
        ClickSelectMode = val
        if val then
            if LassoMode then
                LassoMode     = false
                LassoDragging = false
                if LassoFrame then LassoFrame.Visible = false end
                if LassoToggle then LassoToggle:SetState(false) end
            end
            if GroupSelectMode then
                GroupSelectMode = false
                if GroupSelectToggle then GroupSelectToggle:SetState(false) end
            end
        end
    end)

    GroupSelectToggle = Tab:CreateToggle("Group Selection", false, function(val)
        GroupSelectMode = val
        if val then
            if ClickSelectMode then
                ClickSelectMode = false
                if ClickToggle then ClickToggle:SetState(false) end
            end
            if LassoMode then
                LassoMode     = false
                LassoDragging = false
                if LassoFrame then LassoFrame.Visible = false end
                if LassoToggle then LassoToggle:SetState(false) end
            end
        end
    end)

    LassoToggle = Tab:CreateToggle("Lasso Tool", false, function(val)
        LassoMode = val
        if val then
            if ClickSelectMode then
                ClickSelectMode = false
                if ClickToggle then ClickToggle:SetState(false) end
            end
            if GroupSelectMode then
                GroupSelectMode = false
                if GroupSelectToggle then GroupSelectToggle:SetState(false) end
            end
        else
            LassoDragging = false
            if LassoFrame then LassoFrame.Visible = false end
        end
    end)

    local SelectRow = Tab:CreateRow()
    SelectRow:CreateAction("Clear Selection", "Clear", ClearSelection)
    MoveElement = SelectRow:CreateAction("Move Selection", "Move", function()
        if PlaceMode or Placing then StopPlacing(); return end

        local hasWires  = #SelectedWires > 0
        local hasStruct = #SelectedStructures > 0
        local hasFurn   = #SelectedFurniture > 0
        local hasBP     = #SelectedBlueprints > 0

        if not hasWires and not hasStruct and not hasFurn and not hasBP then
            Library:Notify("Blueprints", "No items selected!"); return
        end

        local anchorPos = Vector3.new()
        local anchorCount = 0
        for _, w in ipairs(SelectedWires) do
            local pts = GetWirePoints(w)
            if pts and #pts > 0 then
                anchorPos = anchorPos + pts[1]
                anchorCount += 1
            end
        end
        for _, s in ipairs(SelectedStructures) do
            local cf = GetStructureCFrame(s)
            if cf then anchorPos = anchorPos + cf.Position; anchorCount += 1 end
        end
        for _, f in ipairs(SelectedFurniture) do
            local cf = f:GetPivot()
            anchorPos = anchorPos + cf.Position; anchorCount += 1
        end
        for _, b in ipairs(SelectedBlueprints) do
            local cf = GetStructureCFrame(b) or b:GetPivot()
            if cf then anchorPos = anchorPos + cf.Position; anchorCount += 1 end
        end
        if anchorCount == 0 then Library:Notify("Blueprints", "Could not compute selection anchor.", 4); return end
        anchorPos = anchorPos / anchorCount

        if hasWires then
            local _, err, validWires = BuildMoveStrokes(SelectedWires)
            if not validWires then Library:Notify("Blueprints", err or "Could not prepare wire move", 4); return end
            moveWires      = validWires
            placementWires = validWires
            blueprintTypes = {}
        end

        local lowestY = math.huge

        local function GetItemBBInfo(model, getCFFunc)
            local placedCF = getCFFunc()
            if not placedCF then return nil end
            local ok, bbCF, bbSize = pcall(function() return model:GetBoundingBox() end)
            local bottomY, halfH, halfX, halfZ
            if ok and bbSize then
                -- bbSize is along the model's LOCAL axes. For rotated models
                -- (e.g. a wall lying on its long side) bbSize.Y is NOT the world
                -- vertical extent, so project the 8 OBB corners into world space
                -- and take the true min/max world Y.
                local hx, hy, hz = bbSize.X * 0.5, bbSize.Y * 0.5, bbSize.Z * 0.5
                local minWY, maxWY = math.huge, -math.huge
                for _, sx in ipairs({-1, 1}) do
                    for _, sy in ipairs({-1, 1}) do
                        for _, sz in ipairs({-1, 1}) do
                            local wy = (bbCF * CFrame.new(sx*hx, sy*hy, sz*hz)).Position.Y
                            if wy < minWY then minWY = wy end
                            if wy > maxWY then maxWY = wy end
                        end
                    end
                end
                bottomY = minWY
                halfH   = (maxWY - minWY) * 0.5
                halfX   = hx
                halfZ   = hz
            else
                halfH, halfX, halfZ = 1, 1, 1
                bottomY = placedCF.Position.Y - halfH
            end
            return { cf = placedCF, bottomY = bottomY, halfH = halfH, halfX = halfX, halfZ = halfZ }
        end

        local structInfos   = {}
        local furnInfos     = {}

        for _, s in ipairs(SelectedStructures) do
            local info = GetItemBBInfo(s, function() return GetStructureCFrame(s) end)
            if info then
                table.insert(structInfos, { model = s, info = info })
                if info.bottomY < lowestY then lowestY = info.bottomY end
            end
        end
        for _, f in ipairs(SelectedFurniture) do
            local info = GetItemBBInfo(f, function() return f:GetPivot() end)
            if info then
                table.insert(furnInfos, { model = f, info = info })
                if info.bottomY < lowestY then lowestY = info.bottomY end
            end
        end

        local bpInfos = {}
        for _, b in ipairs(SelectedBlueprints) do
            local placedCF = GetStructureCFrame(b) or b:GetPivot()
            if placedCF then
                local info = {
                    cf      = placedCF,
                    bottomY = placedCF.Position.Y,
                    halfH   = 0,
                    halfX   = 4,
                    halfZ   = 4,
                }
                table.insert(bpInfos, { model = b, info = info })
                if info.bottomY < lowestY then lowestY = info.bottomY end
            end
        end

        if lowestY == math.huge then lowestY = anchorPos.Y end

        if hasWires then
            blueprintWires = {}
            for _, w in ipairs(moveWires) do
                local pts = GetWirePoints(w)
                if pts then
                    local offsets = {}
                    for _, p in ipairs(pts) do
                        offsets[#offsets+1] = Vector3.new(
                            p.X - anchorPos.X,
                            p.Y - lowestY,
                            p.Z - anchorPos.Z
                        )
                    end
                    blueprintWires[#blueprintWires+1] = offsets
                end
            end
        end

        moveStructures = {}
        for _, entry in ipairs(structInfos) do
            local s   = entry.model
            local inf = entry.info
            local xzOff  = Vector3.new(inf.cf.Position.X - anchorPos.X, 0, inf.cf.Position.Z - anchorPos.Z)
            local yAbove = inf.cf.Position.Y - lowestY
            table.insert(moveStructures, {
                model      = s,
                offsetPos  = inf.cf.Position - anchorPos,
                xzOffset   = xzOff,
                yAbove     = yAbove,
                halfH      = inf.halfH,
                halfX      = inf.halfX,
                halfZ      = inf.halfZ,
                cf         = inf.cf,
                itemName   = GetItemName(s),
                treeValue  = GetStructureTreeValue(s),
            })
        end

        moveFurniture = {}
        for _, entry in ipairs(furnInfos) do
            local f   = entry.model
            local inf = entry.info
            local xzOff  = Vector3.new(inf.cf.Position.X - anchorPos.X, 0, inf.cf.Position.Z - anchorPos.Z)
            local yAbove = inf.cf.Position.Y - lowestY
            table.insert(moveFurniture, {
                model      = f,
                offsetPos  = inf.cf.Position - anchorPos,
                xzOffset   = xzOff,
                yAbove     = yAbove,
                halfH      = inf.halfH,
                halfX      = inf.halfX,
                halfZ      = inf.halfZ,
                cf         = inf.cf,
                itemName   = GetItemName(f),
            })
        end

        moveBlueprints = {}
        for _, entry in ipairs(bpInfos) do
            local b   = entry.model
            local inf = entry.info
            local xzOff  = Vector3.new(inf.cf.Position.X - anchorPos.X, 0, inf.cf.Position.Z - anchorPos.Z)
            local yAbove = inf.cf.Position.Y - lowestY
            table.insert(moveBlueprints, {
                model      = b,
                offsetPos  = inf.cf.Position - anchorPos,
                xzOffset   = xzOff,
                yAbove     = yAbove,
                halfH      = inf.halfH,
                halfX      = inf.halfX,
                halfZ      = inf.halfZ,
                cf         = inf.cf,
                itemName   = GetItemName(b),
                isBlueprint = true,
            })
        end

        usePropertyOrigin = false

        for _, clone in ipairs(movePreviewModels) do pcall(function() clone:Destroy() end) end
        movePreviewModels = {}

        local function MakePreviewClone(model)
            local clone = model:Clone()
            for _, part in ipairs(clone:GetDescendants()) do
                if part:IsA("BasePart") then
                    part.CanCollide = false
                    part.CastShadow = false
                    part.Anchored   = true
                end
            end
            if clone:IsA("BasePart") then
                clone.CanCollide = false
                clone.CastShadow = false
                clone.Anchored   = true
            end
            clone.Parent = PreviewModel
            return clone
        end

        for _, entry in ipairs(moveStructures) do
            local clone = MakePreviewClone(entry.model)
            table.insert(movePreviewModels, clone)
            entry.previewClone = clone
        end
        for _, entry in ipairs(moveFurniture) do
            local clone = MakePreviewClone(entry.model)
            table.insert(movePreviewModels, clone)
            entry.previewClone = clone
        end
        for _, entry in ipairs(moveBlueprints) do
            local clone = MakePreviewClone(entry.model)
            table.insert(movePreviewModels, clone)
            entry.previewClone = clone
        end

        MoveMode      = true
        BlueprintMode = hasWires
        PlaceMode     = true
        PreviewActive = true
        MoveElement:SetText("Cancel")
        Library:Notify("Blueprints", "Move preview — left-click to place.", 3)
    end)

-- ================================================================
    --  PLANK FILL SECTION
    -- ================================================================
    Tab:CreateSection("Plank Fill")

    -- Static list of every plank type — no scanning, no lag. Selecting a type
    -- the player doesn't own (within the Settings Y range) turns off + disables
    -- the Click-to-Fill toggle and disables the Fill button.
    -- NOTE: these must match your planks' TreeClass values exactly (case-sensitive).
    local PLANK_TYPES = {
        "Generic", "Cherry", "Birch", "Oak", "Walnut", "Koa", "Pine", "Palm", "Fir",
        "Volcano", "Frost", "GreenSwampy", "GoldSwampy",
        "SnowGlow", "CaveCrawler", "LoneCave", "Spook", "Sinister",
    }

    local clickFillMode     = false
    local selectedPlankType = PLANK_TYPES[1]

    local fillRunning = false
    local fillCancel  = false

    local PlankTypeDropdown
    local FillAllBtn
    local ClickFillToggle

    local function GetBlueprintCenter(bp)
        if bp.PrimaryPart then return bp.PrimaryPart.Position end
        local sum, count = Vector3.new(), 0
        for _, p in ipairs(bp:GetDescendants()) do
            if p:IsA("BasePart") then sum += p.Position; count += 1 end
        end
        return count > 0 and (sum / count) or Vector3.new()
    end

    -- TP a plank into a blueprint via LOT and pin it for 1s.
    local function FillBlueprintWithPlank(bp, entry)
        if not LOT then return false end
        if not (bp and bp.Parent and entry and entry.part and entry.part.Parent) then return false end
        LOT.TeleportObjectTo(entry.part, CFrame.new(GetBlueprintCenter(bp)))
        if LOT.WaitForBatch then LOT.WaitForBatch() end
        local deadline = tick() + 1
        while bp and bp.Parent and tick() < deadline do
            if entry.part and entry.part.Parent then
                entry.part.CFrame      = CFrame.new(GetBlueprintCenter(bp))
                entry.part.Velocity    = Vector3.zero
                entry.part.RotVelocity = Vector3.zero
            end
            task.wait(0.1)
        end
        return true
    end

    -- Cheap, on-demand check: does the player own a plank of `cls` within the
    -- Settings Y range? Doesn't touch filteredPlanks/outlines, so no lag.
    local function PlayerHasPlankType(cls)
        local pm = workspace:FindFirstChild("PlayerModels")
        if not pm then return false end
        for _, model in ipairs(pm:GetChildren()) do
            if model.Name == "Plank" and model:IsA("Model") and IsOwnedByLocalPlayer(model) then
                local tc   = model:FindFirstChild("TreeClass")
                local part = model:FindFirstChild("Main") or model:FindFirstChildWhichIsA("BasePart")
                if part and part:IsA("BasePart") then
                    local tcv = (tc and tc:IsA("StringValue") and tc.Value) or ""
                    local sz  = part.Size
                    local vol = math.floor(sz.X * sz.Y * sz.Z * 10 + 0.5) / 10
                    if tcv == cls and vol >= plankFilterMin and vol <= plankFilterMax then
                        return true
                    end
                end
            end
        end
        return false
    end

    -- Returns whether the selected type is owned, but never disables the UI.
    -- The button/toggle stay enabled regardless; fill actions notify if empty.
    local function ValidateSelectedType()
        return selectedPlankType and PlayerHasPlankType(selectedPlankType)
    end

    PlankTypeDropdown = Tab:CreateDropdown("Plank Type", PLANK_TYPES, PLANK_TYPES[1], function(val)
        selectedPlankType = val
        ValidateSelectedType()
    end)

    local PlankFillRow = Tab:CreateRow()
    FillAllBtn = PlankFillRow:CreateAction("Fill Blueprints", "Start", function()
        -- Clicking while a fill is in progress = Stop.
        if fillRunning then
            fillCancel = true
            return
        end

        if not LOT then
            Library:Notify("Blueprints", "LOT not available — cannot fill.", 4); return
        end
        if not ValidateSelectedType() then
            Library:Notify("Blueprints", "No '" .. tostring(selectedPlankType) .. "' planks in the Y range.", 5); return
        end
        local cls = selectedPlankType
        local pm = workspace:FindFirstChild("PlayerModels")
        if not pm then Library:Notify("Blueprints", "PlayerModels not found.", 4); return end
        local blueprints = {}
        for _, m in ipairs(pm:GetChildren()) do
            local typeVal = m:FindFirstChild("Type")
            if typeVal and typeVal.Value == "Blueprint" and IsOwnedByLocalPlayer(m) then
                table.insert(blueprints, m)
            end
        end
        if #blueprints == 0 then
            ClearPlankOutlines()
            Library:Notify("Blueprints", "No blueprints to fill.", 4); return
        end
        -- Only highlight/prepare planks once we know there's something to fill.
        allPlanks = ScanAllOwnedPlanks()
        ApplyPlankYFilter()

        fillRunning = true
        fillCancel  = false
        FillAllBtn:SetText("Stop")

        task.spawn(function()
            local filled = 0
            for _, bp in ipairs(blueprints) do
                if fillCancel then break end
                if bp.Parent then
                    local entry = GetNextPlankForClass(cls)
                    if not entry then
                        Library:Notify("Blueprints", "Ran out of matching planks in Y range.", 4)
                        break
                    end
                    if FillBlueprintWithPlank(bp, entry) then filled += 1 end
                end
            end
            local cancelled = fillCancel
            fillRunning = false
            fillCancel  = false
            FillAllBtn:SetText("Start")
            ClearPlankOutlines()
            Library:Notify("Blueprints",
                (cancelled and "Stopped — filled %d/%d blueprint(s)." or "Filled %d/%d blueprint(s)."):format(filled, #blueprints), 4)
        end)
    end)
    ClickFillToggle = PlankFillRow:CreateToggle("Click to Fill", false, function(val)
        clickFillMode = val
        if val then
            allPlanks = ScanAllOwnedPlanks()
            ApplyPlankYFilter()
        else
            ClearPlankOutlines()
        end
    end)

    ValidateSelectedType()

    -- ================================================================
    --  TEXT ART SECTION
    -- ================================================================
    Tab:CreateSection("Wire Text Art")
    local WordInput = Tab:CreateInput("Text Field", "Enter...", function(text)
        text = text:upper():gsub("[^A-Z0-9 %-_=+%[%]\\|;:\'\",./<>?!#%^]", "")
        currentWord = text
        WordInput:SetText(text)
    end)
    local ScaleSlider = Tab:CreateSlider("Scale", 2, 10, Settings.Scale, function(val)
        Settings.Scale = val
    end, 1)
    local SpacingSlider = Tab:CreateSlider("Spacing", 1, 12, Settings.Spacing, function(val)
        Settings.Spacing = val
    end, 1)
    ActionElement = Tab:CreateAction("Process", "Start", function()
        if PlaceMode then StopPlacing() else StartPlacing() end
    end)

    -- ================================================================
    --  CUSTOM INPUT / FILE SECTION
    -- ================================================================
    Tab:CreateSection("Blueprint Builder")

    local BLUEPRINT_FOLDER = "Dynxe/Blueprints"
    local LEGACY_FOLDER    = "Dynxe/WireArt"  -- old name; auto-migrated on load
    
    -- ================================================================
    --  ENSURE FOLDER STRUCTURE EXISTS (guaranteed on module init)
    -- ================================================================
    if isfolder and makefolder then
        -- Create main Dynxe folder if missing
        if not isfolder("Dynxe") then
            pcall(makefolder, "Dynxe")
        end
        -- Create Blueprints subfolder if missing
        if not isfolder(BLUEPRINT_FOLDER) then
            pcall(makefolder, BLUEPRINT_FOLDER)
        end
    end
    
    pcall(function()
        if not (isfolder and makefolder) then return end

        -- One-time migration: if an old "WireArt" folder exists, copy its
        -- contents into "Blueprints" verbatim (same file names, same data).
        -- Existing files in Blueprints are NEVER overwritten, then the old
        -- folder is removed once everything has been copied over.
        if isfolder(LEGACY_FOLDER) and listfiles and readfile and writefile then
            local function migrate(folder)
                local ok, entries = pcall(listfiles, folder)
                if not ok or type(entries) ~= "table" then return end
                for _, path in ipairs(entries) do
                    if type(path) == "string" then
                        local isDir = pcall(function() return isfolder(path) end) and isfolder(path)
                        if isDir then
                            migrate(path)  -- recurse into any subfolders
                        else
                            local rel = path:match("WireArt[/\\](.+)$") or path:match("([^/\\]+)$")
                            if rel then
                                local dest = BLUEPRINT_FOLDER .. "/" .. rel
                                -- recreate nested subfolders if the file lived in one
                                local subDir = dest:match("^(.*)[/\\][^/\\]+$")
                                if subDir and not isfolder(subDir) then
                                    pcall(makefolder, subDir)
                                end
                                local exists = false
                                if isfile then
                                    local iok, ires = pcall(isfile, dest)
                                    exists = iok and ires
                                end
                                if not exists then
                                    local rok, data = pcall(readfile, path)
                                    if rok and data ~= nil then
                                        pcall(writefile, dest, data)
                                    end
                                end
                            end
                        end
                    end
                end
            end
            migrate(LEGACY_FOLDER)
            if delfolder then pcall(delfolder, LEGACY_FOLDER) end
        end
    end)

    local function ScanBlueprintFiles()
        local files = {}
        local seen = {}
        local function scan(folder)
            local ok, result = pcall(function()
                if listfiles then return listfiles(folder) end
                return {}
            end)
            if not ok or not result then return end
            for _, path in ipairs(result) do
                if type(path) == "string" then
                    local isDir = pcall(function() return isfolder and isfolder(path) end) and isfolder(path)
                    if isDir then
                        scan(path)
                    elseif path:lower():match("%.txt$") or path:lower():match("%.dynxe$") then
                        local rel = path:match("Blueprints[/\\](.+)$") or path:match("WireArt[/\\](.+)$") or path:match("([^/\\]+)$") or path
                        if not seen[rel] then
                            seen[rel] = true
                            table.insert(files, rel)
                        end
                    end
                end
            end
        end
        scan(BLUEPRINT_FOLDER)
        table.sort(files, function(a, b) return a:lower() < b:lower() end)
        return files
    end

    local selectedFile = nil
    local fileList = ScanBlueprintFiles()
    if #fileList == 0 then table.insert(fileList, "No files found") end

    local FileDropdown = Tab:CreateDropdown("Blueprint File", fileList, fileList[1], function(val)
        selectedFile = (val ~= "No files found") and val or nil
    end)
    if fileList[1] and fileList[1] ~= "No files found" then
        selectedFile = fileList[1]
    end

    local BuildRow = Tab:CreateRow()
    BuildRow:CreateAction("Refresh Files", "Refresh", function()
        fileList = ScanBlueprintFiles()
        if #fileList == 0 then fileList = {"No files found"}; selectedFile = nil
        else selectedFile = fileList[1] end
        FileDropdown:SetOptions(fileList)
        Library:Notify("Blueprints", "Found " .. (selectedFile and #fileList or 0) .. " blueprint file(s)", 3)
    end)

    -- ================================================================
    --  BuildFilePlacementData
    -- ================================================================
    local function BuildFilePlacementData(structEntries, furnEntries, isPropertyMode, wireOrigin, sharedLowestY)
        for _, clone in ipairs(movePreviewModels) do pcall(function() clone:Destroy() end) end
        movePreviewModels = {}
        moveStructures    = {}
        moveFurniture     = {}

        local function MakePreviewClone(model)
            local clone = model:Clone()
            for _, part in ipairs(clone:GetDescendants()) do
                if part:IsA("BasePart") then
                    part.CanCollide = false; part.CastShadow = false; part.Anchored = true
                end
            end
            if clone:IsA("BasePart") then
                clone.CanCollide = false; clone.CastShadow = false; clone.Anchored = true
            end
            clone.Parent = PreviewModel
            return clone
        end

        local function FindPreviewSource(itemName)
            local pm = workspace:FindFirstChild("PlayerModels")
            if not pm then return nil end
            for _, m in ipairs(pm:GetChildren()) do
                local typeVal = m:FindFirstChild("Type")
                if typeVal and (typeVal.Value == "Blueprint" or typeVal.Value == "Structure" or typeVal.Value == "Vehicle Spot")
                and IsOwnedByLocalPlayer(m)
                and GetItemName(m) == itemName then
                    return m
                end
            end
            return nil
        end

        if isPropertyMode then
            for _, entry in ipairs(structEntries) do
                local src = FindPreviewSource(entry.itemName)
                local clone = src and MakePreviewClone(src) or nil
                table.insert(moveStructures, {
                    isFileBuild    = true,
                    isPropertyMode = true,
                    worldCF        = entry.cf,
                    cf             = entry.cf,
                    itemName       = entry.itemName,
                    treeValue      = entry.treeValue,
                    xzOffset       = Vector3.new(0, 0, 0),
                    yAbove         = 0,
                    halfH          = 1, halfX = 1, halfZ = 1,
                    previewClone   = clone,
                })
                if clone then
                    table.insert(movePreviewModels, clone)
                    pcall(function()
                        if clone.PrimaryPart then clone:SetPrimaryPartCFrame(entry.cf)
                        else clone:PivotTo(entry.cf) end
                    end)
                end
            end

            for _, entry in ipairs(furnEntries) do
                local src = FindSourceFurniture(entry.itemName)
                if not src then continue end
                local clone = MakePreviewClone(src)
                table.insert(moveFurniture, {
                    model          = src,
                    xzOffset       = Vector3.new(0, 0, 0),
                    yAbove         = 0,
                    halfH          = 1, halfX = 1, halfZ = 1,
                    worldCF        = entry.cf,
                    cf             = entry.cf,
                    itemName       = entry.itemName,
                    isFileBuild    = true,
                    isPropertyMode = true,
                    previewClone   = clone,
                })
                table.insert(movePreviewModels, clone)
                pcall(function()
                    if clone.PrimaryPart then clone:SetPrimaryPartCFrame(entry.cf)
                    else clone:PivotTo(entry.cf) end
                end)
            end

        else
            -- ── ROBUST BOTTOM-ANCHORING ──────────────────────────────────────
            -- Don't predict pivot-to-bottom from a source model — that breaks when
            -- the live source's orientation differs from the saved CFrame (e.g. a
            -- vehicle spot upright on the plot vs. saved flat). Instead POSITION each
            -- clone at its saved CFrame using the SAME method the render loop uses,
            -- then measure its real world-space bottom. The lowest measured bottom is
            -- the floor that lands at the cursor. With wires present, sharedLowestY is
            -- the agreed baseline so structures stay aligned to the wires.
            local function PositionClone(clone, cf)
                pcall(function()
                    if clone.PrimaryPart then clone:SetPrimaryPartCFrame(cf) else clone:PivotTo(cf) end
                end)
            end

            local function MeasuredBottomY(clone, cf)
                PositionClone(clone, cf)
                local ok, bbCF, bbSize = pcall(function() return clone:GetBoundingBox() end)
                if not (ok and bbCF and bbSize) then return cf.Position.Y end
                local hx, hy, hz = bbSize.X * 0.5, bbSize.Y * 0.5, bbSize.Z * 0.5
                local minWY = math.huge
                for _, sx in ipairs({-1, 1}) do
                    for _, sy in ipairs({-1, 1}) do
                        for _, sz in ipairs({-1, 1}) do
                            local wy = (bbCF * CFrame.new(sx*hx, sy*hy, sz*hz)).Position.Y
                            if wy < minWY then minWY = wy end
                        end
                    end
                end
                return minWY
            end

            local structItems, furnItems = {}, {}
            local groupBottomRelY = sharedLowestY or math.huge

            for _, entry in ipairs(structEntries) do
                local src   = FindPreviewSource(entry.itemName)
                local clone = src and MakePreviewClone(src) or nil
                if clone and not sharedLowestY then
                    local botY = MeasuredBottomY(clone, entry.cf)
                    if botY < groupBottomRelY then groupBottomRelY = botY end
                end
                table.insert(structItems, { entry = entry, clone = clone })
            end
            for _, entry in ipairs(furnEntries) do
                local src = FindSourceFurniture(entry.itemName)
                if src then
                    local clone = MakePreviewClone(src)
                    if not sharedLowestY then
                        local botY = MeasuredBottomY(clone, entry.cf)
                        if botY < groupBottomRelY then groupBottomRelY = botY end
                    end
                    table.insert(furnItems, { entry = entry, clone = clone, src = src })
                end
            end
            if groupBottomRelY == math.huge then groupBottomRelY = 0 end

            for _, it in ipairs(structItems) do
                local entry, clone = it.entry, it.clone
                local relPos = entry.cf.Position
                table.insert(moveStructures, {
                    isFileBuild = true,
                    xzOffset    = wireOrigin and Vector3.new(relPos.X - wireOrigin.X, 0, relPos.Z - wireOrigin.Z) or Vector3.new(relPos.X, 0, relPos.Z),
                    yAbove      = relPos.Y - groupBottomRelY,
                    halfH = 1, halfX = 1, halfZ = 1,
                    cf = entry.cf, relCF = entry.cf,
                    itemName = entry.itemName, treeValue = entry.treeValue,
                    previewClone = clone,
                })
                if clone then table.insert(movePreviewModels, clone) end
            end
            for _, it in ipairs(furnItems) do
                local entry, clone, src = it.entry, it.clone, it.src
                local relPos = entry.cf.Position
                table.insert(moveFurniture, {
                    model = src,
                    xzOffset = wireOrigin and Vector3.new(relPos.X - wireOrigin.X, 0, relPos.Z - wireOrigin.Z) or Vector3.new(relPos.X, 0, relPos.Z),
                    yAbove = relPos.Y - groupBottomRelY,
                    halfH = 1, halfX = 1, halfZ = 1,
                    cf = entry.cf, relCF = entry.cf,
                    itemName = entry.itemName, isFileBuild = true,
                    previewClone = clone,
                })
                table.insert(movePreviewModels, clone)
            end
        end
    end

    BlueprintBuild = BuildRow:CreateAction("Build File", "Start", function()
        if PlaceMode or Placing then StopPlacing(); return end

        local function hasCFrameLine(txt)
            for line in (txt .. "\n"):gmatch("([^\n]*)\n") do
                local f2 = line:match("^[^|]+|([^|]+)")
                if f2 then
                    local nums = 0
                    for _ in f2:gmatch("[^,]+") do nums += 1 end
                    if nums == 12 then return true end
                end
            end
            return false
        end

        if not selectedFile then
            Library:Notify("Blueprints", "No blueprint file selected" .. BLUEPRINT_FOLDER .. "/", 5)
            return
        end

        local filePath = BLUEPRINT_FOLDER .. "/" .. selectedFile
        local clipText = nil
        local readOk, readResult = pcall(function()
            if not readfile then return nil, "no readfile" end
            return readfile(filePath)
        end)
        if readOk and readResult and readResult ~= "" then
            clipText = readResult
        end
        if not clipText then
            local reason = "unknown"
            if not readfile then reason = "readfile not available"
            elseif not readOk then reason = "read error: " .. tostring(readResult)
            elseif not readResult or readResult == "" then reason = "file empty or not found"
            end
            Library:Notify("Blueprints", "Could not read file: " .. selectedFile .. " (" .. reason .. ")", 5)
            return
        end
        local isCombined = clipText:find("%[Wires%]") or clipText:find("%[Structures%]")
            or clipText:find("%[Furniture%]") or hasCFrameLine(clipText)

        -- Does this file contain anything that needs a plank? (structure line with
        -- a non-empty treeValue = wood blueprint). If not, never touch the planks.
        local function FileNeedsWood(text)
            local inStructures = false
            for line in (text .. "\n"):gmatch("([^\n]*)\n") do
                local trimmed = line:match("^%s*(.-)%s*$") or ""
                if trimmed:match("^%[(.-)%]$") then
                    inStructures = trimmed:lower():find("structures") ~= nil
                elseif trimmed ~= "" and trimmed:sub(1,2) ~= "--" then
                    local fields = {}
                    for f in (trimmed .. " | "):gmatch("([^|]*)|") do
                        table.insert(fields, f:match("^%s*(.-)%s*$") or "")
                    end
                    -- headerless auto-detect: a 12-num field 2 means struct/furniture
                    local f2nums = 0
                    if fields[2] then for _ in fields[2]:gmatch("[^,]+") do f2nums += 1 end end
                    if (inStructures or f2nums == 12) and #fields >= 3 and fields[3] ~= "" then
                        return true
                    end
                end
            end
            return false
        end

        local needsWood = FileNeedsWood(clipText)

        if needsWood then
            allPlanks = ScanAllOwnedPlanks()
            ApplyPlankYFilter()
            if LOT and #allPlanks > 0 then
                Library:Notify("Blueprints",
                    ("Planks scanned: %d total, %d in Y range %.1f–%.1f"):format(
                        #allPlanks, #filteredPlanks, plankFilterMin, plankFilterMax), 3)
            end
        else
            ClearPlankOutlines()
        end

        -- Pre-flight plank count check: count how many wood-blueprint structures
        -- are in the file so we can warn before starting if planks are insufficient.
        local function CountBlueprintStructures(text)
            local count = 0
            local inStructures = false
            for line in (text .. "\n"):gmatch("([^\n]*)\n") do
                local trimmed = line:match("^%s*(.-)%s*$") or ""
                if trimmed:match("^%[(.-)%]$") then
                    inStructures = trimmed:lower():find("structures") ~= nil
                elseif inStructures and trimmed ~= "" and trimmed:sub(1,2) ~= "--" then
                    -- treeValue is the 3rd pipe-delimited field; non-empty = wood blueprint
                    local fields = {}
                    for f in (trimmed .. " | "):gmatch("([^|]*)|") do
                        table.insert(fields, f:match("^%s*(.-)%s*$") or "")
                    end
                    if #fields >= 3 and fields[3] ~= "" then count += 1 end
                end
            end
            return count
        end

        if LOT and clipText then
            local needed = CountBlueprintStructures(clipText)
            if needed > 0 and #filteredPlanks < needed then
                Library:Notify("Blueprints",
                    ("Not enough planks — need %d, have %d in Y range %.1f–%.1f"):format(
                        totalNeeded, #filteredPlanks, plankFilterMin, plankFilterMax), 7)
                return
            end
        end

        if isCombined then
            local wires, wireTypes, structures, furniture, skipped, useProperty =
                ParseCombinedBlueprint(clipText)

            if skipped > 0 then
                Library:Notify("Blueprints", skipped .. " entry(s) skipped — bad format", 3)
            end

            local hasWires      = #wires > 0
            local hasStructures = #structures > 0
            local hasFurniture  = #furniture > 0

            -- Pre-flight plank check using parsed structures directly
            if LOT and hasStructures then
                local neededByClass = {}
                for _, entry in ipairs(structures) do
                    if entry.treeValue and entry.treeValue ~= "" then
                        -- If user has a selected structure of this type, it won't need a plank
                        local src = FindSourceStructure(entry.itemName)
                        if not src then
                            neededByClass[entry.treeValue] = (neededByClass[entry.treeValue] or 0) + 1
                        end
                    end
                end
                -- Reset the round-robin index so placement starts fresh
                structureUseIndex = {}
                local totalNeeded = 0
                for _, count in pairs(neededByClass) do totalNeeded += count end
                if totalNeeded > 0 and #filteredPlanks < totalNeeded then
                    Library:Notify("Blueprints",
                        ("Not enough planks — need %d, have %d in Y range %.1f–%.1f"):format(
                            totalNeeded, #filteredPlanks, plankFilterMin, plankFilterMax), 7)
                    return
                end
            end

            -- Pre-flight: non-wood structures need matching selected sources
            if hasStructures then
                local structNeeded = {}
                for _, entry in ipairs(structures) do
                    if not entry.treeValue or entry.treeValue == "" then
                        structNeeded[entry.itemName] = (structNeeded[entry.itemName] or 0) + 1
                    end
                end
                local structHave = {}
                for _, model in ipairs(SelectedStructures) do
                    if model and model.Parent then
                        local n = GetItemName(model)
                        structHave[n] = (structHave[n] or 0) + 1
                    end
                end
                local structMissing = {}
                for name, need in pairs(structNeeded) do
                    local have = structHave[name] or 0
                    if have < need then
                        table.insert(structMissing, name .. ": need " .. need .. ", selected " .. have)
                    end
                end
                if #structMissing > 0 then
                    Library:Notify("Blueprints", "Missing structures — " .. table.concat(structMissing, "; "), 7)
                    return
                end
            end

            -- Pre-flight: each furniture type needs at least one owned copy
            if hasFurniture then
                local furnMissing = {}
                local checked = {}
                for _, entry in ipairs(furniture) do
                    if not checked[entry.itemName] then
                        checked[entry.itemName] = true
                        if not FindSourceFurniture(entry.itemName) then
                            table.insert(furnMissing, entry.itemName)
                        end
                    end
                end
                if #furnMissing > 0 then
                    Library:Notify("Blueprints", "Missing furniture — not owned: " .. table.concat(furnMissing, ", "), 7)
                    return
                end
            end

            if not hasWires and not hasStructures and not hasFurniture then
                Library:Notify("Blueprints", "No valid entries found in " .. selectedFile, 4); return
            end

            if hasWires then
                if #SelectedWires == 0 then
                    Library:Notify("Blueprints", "File has wires but none selected! Select wires first.", 4); return
                end
                local assignments, ok2, missing = AssignWiresByType(wireTypes, SelectedWires)
                if not ok2 then
                    Library:Notify("Blueprints", FormatMissingReport(missing), 6); return
                end

                blueprintWires = {}
                local propertyOrig = useProperty and GetPropertyCenter()
                if useProperty and not propertyOrig then
                    Library:Notify("Blueprints", "Property-relative mode but no owned property!", 5); return
                end
                local ref
                if useProperty then
                    ref = nil
                else
                    -- Use wire-only centroid so preview centers on cursor correctly.
                    -- Structures use their stored relCF positions directly as xzOffset,
                    -- which are already relative to the same shared save origin.
                    local sum, count = Vector3.new(), 0
                    for _, stroke in ipairs(wires) do
                        for _, pt in ipairs(stroke) do
                            sum = sum + pt
                            count += 1
                        end
                    end
                    ref = count > 0 and (sum / count) or Vector3.new()
                end

                -- Find lowestY across all content so wires and structures share the same baseline
                local lowestY = math.huge
                for _, stroke in ipairs(wires) do
                    for _, pt in ipairs(stroke) do
                        if pt.Y < lowestY then lowestY = pt.Y end
                    end
                end
                for _, entry in ipairs(structures) do
                    if entry.cf.Position.Y < lowestY then lowestY = entry.cf.Position.Y end
                end
                for _, entry in ipairs(furniture) do
                    if entry.cf.Position.Y < lowestY then lowestY = entry.cf.Position.Y end
                end
                if lowestY == math.huge then lowestY = 0 end

                for _, stroke in ipairs(wires) do
                    local offsets = {}
                    for _, pt in ipairs(stroke) do
                        offsets[#offsets+1] = Vector3.new(
                            pt.X,
                            pt.Y - lowestY,
                            pt.Z
                        )
                    end
                    table.insert(blueprintWires, offsets)
                end
                blueprintTypes    = wireTypes
                placementWires    = assignments
                usePropertyOrigin = useProperty
                BlueprintMode     = true
                PlaceMode         = true
                PreviewActive     = true
                BlueprintBuild:SetText("Cancel")
            end

            if hasStructures or hasFurniture then
                pendingStructures   = structures
                pendingFurniture    = furniture
                pendingIsWorldSpace = useProperty
                BuildFilePlacementData(structures, furniture, useProperty, ref, lowestY)

                if not hasWires then
                    if useProperty then
                        -- Property mode: CFs are already world-space — fire immediately.
                        BlueprintBuild:SetText("Placing...")
                        BlueprintBuild:SetDisabled(true)
                        task.spawn(function()
                        local pm4 = workspace:FindFirstChild("PlayerModels")
                        local sb4 = {}
                        if pm4 then for _, m in ipairs(pm4:GetChildren()) do sb4[m] = true end end
                        local sTotal  = #moveStructures + #moveFurniture
                        local sPlaced = 0
                        local origin = Vector3.new()
                        if not useProperty then
                            local char = LocalPlayer.Character
                            local hrp  = char and char:FindFirstChild("HumanoidRootPart")
                            origin = hrp and hrp.Position or Vector3.new()
                        end
                        for _, entry in ipairs(moveStructures) do
                            local newCF
                            if useProperty then
                                newCF = entry.worldCF
                            else
                                local relCF = entry.relCF or entry.cf
                                local newPos = Vector3.new(
                                    origin.X + relCF.Position.X,
                                    origin.Y + entry.yAbove,
                                    origin.Z + relCF.Position.Z
                                )
                                newCF = CFrame.new(newPos) * relCF.Rotation
                            end
                            if entry.treeValue and entry.treeValue ~= "" then
                                local ok, _ = PlaceOneBlueprintFromFile(entry.itemName, newCF, entry.treeValue, sb4)
                                if ok then sPlaced += 1 end
                            else
                                local src = FindSourceStructure(entry.itemName)
                                if src then
                                    local ok
                                    if src:FindFirstChild("PurchasedBoxItemName") then
                                        ok = PlaceOneBoxedStructure(src, newCF, sb4)
                                    else
                                        ok = PlaceOneStructure(src, newCF, nil, false, sb4)
                                    end
                                    if ok then sPlaced += 1 end
                                end
                            end
                        end
                        for _, entry in ipairs(moveFurniture) do
                            local src = FindSourceFurniture(entry.itemName)
                            if src then
                                local newCF
                                if useProperty then
                                    newCF = entry.worldCF
                                else
                                    local relCF = entry.relCF or entry.cf
                                    local newPos = Vector3.new(
                                        origin.X + relCF.Position.X,
                                        origin.Y + entry.yAbove,
                                        origin.Z + relCF.Position.Z
                                    )
                                    newCF = CFrame.new(newPos) * relCF.Rotation
                                end
                                local ok = PlaceOneFurniture(src, newCF, false, sb4)
                                if ok then sPlaced += 1 end
                            end
                        end
                        Library:Notify("Blueprints",
                            ("Done! %d/%d placed."):format(sPlaced, sTotal), 5)
                        StopPlacing()
                    end)
                    else
                        -- Cursor mode: show preview and wait for click, same as wires.
                        BlueprintMode = false
                        MoveMode      = true
                        PlaceMode     = true
                        PreviewActive = true
                        BlueprintBuild:SetText("Cancel")
                        Library:Notify("Blueprints",
                            ("%d structures & %d furniture Loaded "):format(
                                #moveStructures, #moveFurniture), 5)
                    end
                    return
                end
            end

        else
            if #SelectedWires == 0 then
                Library:Notify("Blueprints", "No wires selected"); return
            end
            local parsed, types, skipped, useProperty = ParseBlueprint(clipText)
            if #parsed == 0 then
                Library:Notify("Blueprints", "No valid wires found"); return
            end
            if skipped > 0 then
                Library:Notify("Blueprints", skipped .. " Wires skipped due to invalid formating")
            end
            if useProperty then
                local center = GetPropertyCenter()
                if not center then
                    Library:Notify("Blueprints", "Property not found"); return
                end
            end
            local assignments, ok2, missing = AssignWiresByType(types, SelectedWires)
            if not ok2 then Library:Notify("Blueprints", FormatMissingReport(missing), 6); return end
            blueprintWires = {}
            if useProperty then
                for _, stroke in ipairs(parsed) do
                    local offsets = {}
                    for _, pt in ipairs(stroke) do table.insert(offsets, pt) end
                    table.insert(blueprintWires, offsets)
                end
            else
                -- Compute centroid of all wire points for centering on cursor
                local sum, count = Vector3.new(), 0
                for _, stroke in ipairs(parsed) do
                    for _, pt in ipairs(stroke) do
                        sum = sum + pt
                        count += 1
                    end
                end
            local ref = count > 0 and (sum / count) or parsed[1][1]

            -- Bottom-anchor Y so the cursor sits at the bottom-center, not the
            -- vertical center. XZ stays centroid-relative for horizontal centering.
            local lowestY = math.huge
            for _, stroke in ipairs(parsed) do
                for _, pt in ipairs(stroke) do
                    if pt.Y < lowestY then lowestY = pt.Y end
                end
            end
            if lowestY == math.huge then lowestY = ref.Y end

            for _, stroke in ipairs(parsed) do
                local offsets = {}
                for _, pt in ipairs(stroke) do
                    table.insert(offsets, Vector3.new(pt.X - ref.X, pt.Y - lowestY, pt.Z - ref.Z))
                end
                table.insert(blueprintWires, offsets)
            end
            end
            blueprintTypes    = types
            placementWires    = assignments
            usePropertyOrigin = useProperty
            BlueprintMode     = true
            PlaceMode         = true
            PreviewActive     = true
            BlueprintBuild:SetText(useProperty and "Cancel (Property)" or "Cancel")
            Library:Notify("Blueprints",
                "Loaded " .. #parsed .. " wires from " .. selectedFile .. " — " ..
                (useProperty and "property-anchored" or "click to place") .. "!", 4)
        end
    end)

    -- ================================================================
    --  OBJECT SELECTION SECTION
    -- ================================================================
    Tab:CreateSection("Object Selection")
    local BuildRow1 = Tab:CreateRow()
    BuildRow1:CreateToggle("Structures", true, function(val)
        selectStructures = val
    end)
    BuildRow1:CreateToggle("Blueprints", true, function(val)
        selectBlueprints = val
    end)

    local BuildRow2 = Tab:CreateRow()
    BuildRow2:CreateToggle("Furniture", true, function(val)
        selectFurniture = val
    end)
    BuildRow2:CreateToggle("Wires", true, function(val)
        selectWires = val
    end)

    -- ================================================================
    --  SETTINGS SECTION
    -- ================================================================
    Tab:CreateSection("Settings")
    local RotRow = Tab:CreateRow()
    RotRow:CreateKeybind("Rotate [X]", Enum.KeyCode.R, function() end)
    RotRow:CreateKeybind("Rotate [Y]", Enum.KeyCode.T, function() end)
    Tab:CreateToggle("Snap to Grid", true, function(val)
        snapToGrid = val
    end)
    Tab:CreateToggle("Keep Selection After Place", false, function(val)
        keepSelection = val
    end)
    Tab:CreateToggle("Save Relative to Property", false, function(val)
        exportToProperty = val
    end):AddTooltip("When on, saved coordinates are relative to your property center instead of the selection center.")
    Tab:CreateToggle("Group by Wood Type", false, function(val)
        groupByTreeValue = val
    end):AddTooltip(
        "Used with Group Selection.\n" ..
        "When on, clicking a structure only selects other structures\n" ..
        "with the same BlueprintWoodClass (same wood material)."
    )
    Tab:CreateToggle("Long Wire", false, function(state)
        SetWireLength(state and 50 or 20)
    end)

    plankRangeSlider = Tab:CreateRangeSlider("Plank Volume Range", 0, 10, plankFilterMin, plankFilterMax,
        function(low, high)
            plankFilterMin = low
            plankFilterMax = high
            if #allPlanks == 0 then return end
            ApplyPlankYFilter()
        end, 1)
    plankRangeSlider:AddTooltip("Filters planks by volume. \nThis feature is used for click/auto blueprint fill & Build Blueprint Files. \nDefualt Values are set to allow")

    -- Save Selection
    local SaveBtn = Tab:CreateAction("Save Selection", "Save", function()
        local totalSelected = #SelectedWires + #SelectedStructures + #SelectedFurniture
        if totalSelected == 0 then
            Library:Notify("Blueprints", "No items selected!"); return
        end
        local text, err = BuildBlueprintText(SelectedWires, SelectedStructures, SelectedFurniture, exportToProperty)
        if not text then
            Library:Notify("Blueprints", err or "Failed to build blueprint", 5); return
        end
        if not writefile then
            Library:Notify("Blueprints", "writefile not available in this environment", 5); return
        end
        local stamp    = os.date("%Y-%m-%d_%H-%M-%S")
        local filename = "blueprint_" .. stamp .. ".txt"
        local path     = BLUEPRINT_FOLDER .. "/" .. filename
        local ok, writeErr = pcall(writefile, path, text)
        if not ok then
            Library:Notify("Blueprints", "Save failed: " .. tostring(writeErr), 5); return
        end
        fileList = ScanBlueprintFiles()
        if #fileList == 0 then fileList = {"No files found"} end
        FileDropdown:SetOptions(fileList)
        selectedFile = filename
        local summary = {}
        if #SelectedStructures > 0 then table.insert(summary, #SelectedStructures .. " structures") end
        if #SelectedFurniture  > 0 then table.insert(summary, #SelectedFurniture  .. " furniture") end
        if #SelectedWires      > 0 then table.insert(summary, #SelectedWires      .. " wires") end
        Library:Notify("Blueprints",
            "Saved " .. filename .. " (" .. table.concat(summary, ", ") ..
            (exportToProperty and ", property-relative)" or ")"), 4)
    end)
    SaveBtn:AddTooltip("Exports selected wires, structures, and furniture to a timestamped .txt file in " .. BLUEPRINT_FOLDER .. "/")

    Tab:CreateAction("Delete Selection", "Delete", function()
        local total = #SelectedWires + #SelectedStructures + #SelectedFurniture + #SelectedBlueprints
        if total == 0 then Library:Notify("Blueprints", "No items selected!"); return end
        if not DestroyStructure then
            Library:Notify("Blueprints", "DestroyStructure remote not found.", 4); return
        end
        local toDestroy = {}
        for _, w in ipairs(SelectedWires) do if w and w.Parent then table.insert(toDestroy, w) end end
        for _, s in ipairs(SelectedStructures) do if s and s.Parent then table.insert(toDestroy, s) end end
        for _, f in ipairs(SelectedFurniture) do if f and f.Parent then table.insert(toDestroy, f) end end
        for _, b in ipairs(SelectedBlueprints) do if b and b.Parent then table.insert(toDestroy, b) end end
        Library:Notify("Blueprints", "Deleting " .. #toDestroy .. " item(s)...", math.max(2, math.ceil(#toDestroy * 0.1)))
        task.spawn(function()
            local destroyed = 0
            for _, item in ipairs(toDestroy) do
                if not item.Parent then continue end
                local timeout = 5; local elapsed = 0
                while item.Parent ~= nil and elapsed < timeout do
                    pcall(DestroyStructure.FireServer, DestroyStructure, item)
                    task.wait(0.05); elapsed += 0.05
                end
                if not item.Parent then destroyed += 1 end
            end
            Library:Notify("Blueprints", "Deleted " .. destroyed .. "/" .. #toDestroy .. " item(s).", 4)
            PruneDeadWires()
        end)
    end, true)

    function SetWireLength(length)
        for _, item in next, game:GetService("ReplicatedStorage").ClientItemInfo:GetChildren() do
            if item.Name:lower():find("wire") then
                local maxLength = item:FindFirstChild("OtherInfo") and item.OtherInfo:FindFirstChild("MaxLength")
                if maxLength then maxLength.Value = length end
            end
        end
    end
    -- ================================================================
    --  CLICK HANDLER
    -- ================================================================
    Mouse.Button1Down:Connect(function()
        if clickFillMode and not LassoMode and not PlaceMode and not Placing then
            local b = FindBlueprintModelFromPart(Mouse.Target)
            if b then
                if not LOT then
                    Library:Notify("Blueprints", "LOT not available — cannot fill.", 4); return
                end
                if not selectedPlankType then
                    Library:Notify("Blueprints", "No plank type selected.", 4); return
                end
                local cls = (selectedPlankType == "(none)") and "" or selectedPlankType
                local bp  = b
                task.spawn(function()
                    -- Rescan if the toggle's scan didn't populate (or planks were consumed).
                    if #filteredPlanks == 0 then
                        allPlanks = ScanAllOwnedPlanks()
                        ApplyPlankYFilter()
                    end
                    -- GetNextPlankForClass skips dead/consumed planks automatically.
                    local entry = GetNextPlankForClass(cls)
                    if not entry then
                        Library:Notify("Blueprints", "No matching plank in Y range.", 4); return
                    end
                    FillBlueprintWithPlank(bp, entry)
                end)
            end
            return
        end

        if GroupSelectMode and not LassoMode and not PlaceMode and not Placing then
            local target = Mouse.Target
            local matched = false

            local wire = FindWireModelFromPart(target)
            if wire then
                matched = true
                local pm = workspace:FindFirstChild("PlayerModels")
                if pm then
                    local alreadySelected = table.find(SelectedWires, wire) ~= nil
                    if alreadySelected then
                        local newSel = {}
                        for _, model in ipairs(SelectedWires) do
                            local typeVal = model:FindFirstChild("Type")
                            if not (typeVal and typeVal.Value == "Wire") then
                                table.insert(newSel, model)
                            end
                        end
                        SelectedWires = newSel
                        Library:Notify("Blueprints", "Group deselected wires.")
                    else
                        -- Match same wire type name AND same kind (boxed vs placed).
                        local wireTypeName = GetWireTypeName(wire)
                        local wireIsBoxed  = wire:FindFirstChild("PurchasedBoxItemName") ~= nil
                        for _, model in ipairs(pm:GetChildren()) do
                            local typeVal = model:FindFirstChild("Type")
                            if typeVal and typeVal.Value == "Wire" then
                                local modelIsBoxed = model:FindFirstChild("PurchasedBoxItemName") ~= nil
                                local nameMatch    = GetWireTypeName(model) == wireTypeName
                                if nameMatch and modelIsBoxed == wireIsBoxed then
                                    if not table.find(SelectedWires, model) then
                                        table.insert(SelectedWires, model)
                                    end
                                end
                            end
                        end
                        local kindLabel = wireIsBoxed and " (boxed)" or ""
                        Library:Notify("Blueprints", "Group selected " .. #SelectedWires .. " wire(s)" .. kindLabel .. ".")
                    end
                    UpdateSelectionVisuals()
                end
            end

            if not matched and selectStructures then
                local s = FindStructureModelFromPart(target)
                if s then
                    matched = true
                    local matchTree = groupByTreeValue and GetStructureTreeValue(s) or nil
                    local pm = workspace:FindFirstChild("PlayerModels")
                    if pm then
                        local alreadySelected = table.find(SelectedStructures, s) ~= nil
                        if alreadySelected then
                            if matchTree == nil then
                                SelectedStructures = {}
                            else
                                local kept = {}
                                for _, model in ipairs(SelectedStructures) do
                                    if GetStructureTreeValue(model) ~= matchTree then
                                        table.insert(kept, model)
                                    end
                                end
                                SelectedStructures = kept
                            end
                            local label = matchTree and (" (" .. matchTree .. ")") or ""
                            Library:Notify("Blueprints", "Group deselected structure(s)" .. label .. ".")
                        else
                            -- Group by item name + same kind (boxed vs placed) + wood type when enabled.
                            local matchName   = GetItemName(s)
                            local matchBoxed  = s:FindFirstChild("PurchasedBoxItemName") ~= nil
                            for _, model in ipairs(pm:GetChildren()) do
                                local typeVal = model:FindFirstChild("Type")
                                if typeVal and (typeVal.Value == "Structure" or typeVal.Value == "Vehicle Spot") then
                                    local modelIsBoxed = model:FindFirstChild("PurchasedBoxItemName") ~= nil
                                    local nameMatch    = GetItemName(model) == matchName
                                    local kindMatch    = modelIsBoxed == matchBoxed
                                    local treeMatch    = matchTree == nil or GetStructureTreeValue(model) == matchTree
                                    if nameMatch and kindMatch and treeMatch then
                                        if not table.find(SelectedStructures, model) then
                                            table.insert(SelectedStructures, model)
                                        end
                                    end
                                end
                            end
                            local kindLabel = matchBoxed and " (boxed)" or ""
                            local label = matchTree and (" (" .. matchTree .. ")") or ""
                            Library:Notify("Blueprints", "Group selected " .. #SelectedStructures .. " " .. matchName .. "(s)" .. kindLabel .. label .. ".")
                        end
                        UpdateSelectionVisuals()
                    end
                end
            end

            if not matched and selectBlueprints then
                local b = FindBlueprintModelFromPart(target)
                if b then
                    matched = true
                    local pm = workspace:FindFirstChild("PlayerModels")
                    if pm then
                        local alreadySelected = table.find(SelectedBlueprints, b) ~= nil
                        if alreadySelected then
                            SelectedBlueprints = {}
                            Library:Notify("Blueprints", "Group deselected blueprints.")
                        else
                            local matchName = GetItemName(b)
                            for _, model in ipairs(pm:GetChildren()) do
                                local typeVal = model:FindFirstChild("Type")
                                if typeVal and typeVal.Value == "Blueprint"
                                and not model:FindFirstChild("PurchasedBoxItemName") then
                                    if GetItemName(model) == matchName then
                                        if not table.find(SelectedBlueprints, model) then
                                            table.insert(SelectedBlueprints, model)
                                        end
                                    end
                                end
                            end
                            Library:Notify("Blueprints", "Group selected " .. #SelectedBlueprints .. " " .. matchName .. " blueprint(s).")
                        end
                        UpdateSelectionVisuals()
                    end
                end
            end

            return
        end

        if ClickSelectMode and not LassoMode and not PlaceMode and not Placing then
            local target = Mouse.Target
            local wire = FindWireModelFromPart(target)
            if wire then
                local idx = table.find(SelectedWires, wire)
                if idx then table.remove(SelectedWires, idx) else table.insert(SelectedWires, wire) end
                UpdateSelectionVisuals(); return
            end
            if selectStructures then
                local s = FindStructureModelFromPart(target)
                if s then
                    local idx = table.find(SelectedStructures, s)
                    if idx then table.remove(SelectedStructures, idx) else table.insert(SelectedStructures, s) end
                    UpdateSelectionVisuals(); return
                end
            end
            if selectFurniture then
                local f = FindFurnitureModelFromPart(target)
                if f then
                    local idx = table.find(SelectedFurniture, f)
                    if idx then table.remove(SelectedFurniture, idx) else table.insert(SelectedFurniture, f) end
                    UpdateSelectionVisuals(); return
                end
            end
            if selectBlueprints then
                local b = FindBlueprintModelFromPart(target)
                if b then
                    local idx = table.find(SelectedBlueprints, b)
                    if idx then table.remove(SelectedBlueprints, idx) else table.insert(SelectedBlueprints, b) end
                    UpdateSelectionVisuals(); return
                end
            end
            return
        end

        if not PlaceMode or Placing then return end

        Placing       = true
        PlaceMode     = false
        PreviewActive = false
        ClearPreview()
        for _, clone in ipairs(movePreviewModels) do
            pcall(function() clone:Destroy() end)
        end
        movePreviewModels = {}

        local origin
        if BlueprintMode and usePropertyOrigin then
            origin = GetPropertyCenter()
            if not origin then
                Library:Notify("Blueprints", "Property no longer available — placement cancelled.", 5)
                StopPlacing(); return
            end
        else
            origin = SnapToGrid(GetCursorWorldPos())
        end
        local capturedRot = WireRotation
        local wires       = placementWires

        -- ── Move mode with no wires (Move Selection — no plank fill) ─────────
        -- FIX: ComputeNewPos no longer stacks Y based on bounding-box collisions.
        --      It now exactly matches the preview's RepositionClone logic so items
        --      land exactly where the ghost clone was shown.
        if MoveMode and not BlueprintMode then
            MoveElement:SetText("Placing...")
            MoveElement:SetDisabled(true)
            for _, box in ipairs(SelectionBoxes) do box:Destroy() end
            SelectionBoxes = {}
            task.spawn(function()
                local sPlaced, sTotal = 0, #moveStructures + #moveFurniture + #moveBlueprints
                local pm = workspace:FindFirstChild("PlayerModels")
                local sharedBefore = {}
                if pm then for _, m in ipairs(pm:GetChildren()) do sharedBefore[m] = true end end

                -- Matches RepositionClone exactly: flat XZ rotation + yAbove, no stacking.
                local function ComputeNewPos(entry)
                    local rotatedXZ = WireRotation:VectorToWorldSpace(entry.xzOffset)
                    return Vector3.new(
                        origin.X + rotatedXZ.X,
                        origin.Y + entry.yAbove,
                        origin.Z + rotatedXZ.Z
                    )
                end

                for _, entry in ipairs(moveStructures) do
                    local newPos = ComputeNewPos(entry)
                    local newCF  = CFrame.new(newPos) * WireRotation.Rotation * entry.cf.Rotation
                    if entry.isFileBuild then
                        local src = FindSourceStructure(entry.itemName)
                        if src then
                            local ok
                            if src:FindFirstChild("PurchasedBoxItemName") then
                                ok = PlaceOneBoxedStructure(src, newCF)
                            else
                                ok = PlaceOneStructure(src, newCF, entry.treeValue, true, sharedBefore)
                            end
                            if ok then sPlaced += 1 end
                        elseif entry.treeValue and entry.treeValue ~= "" then
                            local ok, _ = PlaceOneBlueprintFromFile(entry.itemName, newCF, entry.treeValue, sharedBefore)
                            if ok then sPlaced += 1 end
                        end
                    elseif entry.model and entry.model.Parent then
                        local ok = PlaceOneStructure(entry.model, newCF, entry.treeValue, true, sharedBefore)
                        if ok then sPlaced += 1 end
                    end
                end
                for _, entry in ipairs(moveFurniture) do
                    if entry.model and entry.model.Parent then
                        local newPos = ComputeNewPos(entry)
                        local newCF  = CFrame.new(newPos) * WireRotation.Rotation * entry.cf.Rotation
                        local ok = PlaceOneFurniture(entry.model, newCF, true, sharedBefore)
                        if ok then sPlaced += 1 end
                    end
                end
                for _, entry in ipairs(moveBlueprints) do
                    if entry.model and entry.model.Parent then
                        local newPos = ComputeNewPos(entry)
                        local newCF  = entry.cf - entry.cf.Position + newPos
                        -- Move Selection: PlaceOneBlueprint — no plank fill
                        local ok = PlaceOneBlueprint(entry.model, newCF, true, sharedBefore)
                        if ok then sPlaced += 1 end
                    end
                end
                Library:Notify("Blueprints", ("Moved %d/%d item(s)."):format(sPlaced, sTotal), 4)
                StopPlacing()
            end)
            return
        end

        if BlueprintMode then
            local blueprint   = blueprintWires
            local boundsRects = GetPropertySquares()
            BlueprintBuild:SetText("Placing...")
            BlueprintBuild:SetDisabled(true)

            task.spawn(function()
                local placed, outOfBounds = 0, 0
                for i, offsetStroke in ipairs(blueprint) do
                    local wireObj = wires[i]
                    if not wireObj or not wireObj.Parent then
                        Library:Notify("Blueprints", "Ran out of wires at wire " .. i .. "!")
                        StopPlacing(); return
                    end
                    local requiredType = blueprintTypes[i]
                    if requiredType and requiredType ~= "" then
                        local actualType = GetWireTypeName(wireObj)
                        if actualType ~= requiredType then
                            Library:Notify("Blueprints",
                                "Type mismatch at wire " .. i .. " — expected \'" .. requiredType .. "\', got \'" .. tostring(actualType) .. "\'", 5)
                            StopPlacing(); return
                        end
                    end
                    local maxDist = GetWireMaxLength(wireObj)
                    local worldStroke = {}
                    for _, offset in ipairs(offsetStroke) do
                        table.insert(worldStroke, origin + capturedRot:VectorToWorldSpace(offset))
                    end
                    if StrokeExceedsMax(worldStroke, maxDist) then
                        Library:Notify("Blueprints",
                            "Cancelled — wire " .. i .. " exceeds max length (" .. maxDist .. " studs).", 4)
                        StopPlacing(); return
                    end
                    if boundsRects and not StrokeInsideProperty(worldStroke, boundsRects) then
                        outOfBounds = outOfBounds + 1
                    else
                        local Info = GetWireInfo(wireObj)
                        if Info then FireWire(wireObj, worldStroke, Info); placed = placed + 1 end
                    end
                end
                local msg = "Blueprint placed! (" .. placed .. "/" .. #blueprint .. " wires)"
                if outOfBounds > 0 then msg = msg .. " — " .. outOfBounds .. " skipped (outside property)" end
                Library:Notify("Blueprints", msg, 4)

                -- Place any pending structures from a combined file as BLUEPRINTS + fill
                if not MoveMode and (#moveStructures > 0 or #moveFurniture > 0) then
                    local pm3 = workspace:FindFirstChild("PlayerModels")
                    local sb3 = {}
                    if pm3 then for _, m in ipairs(pm3:GetChildren()) do sb3[m] = true end end
                    local sTotal = #moveStructures + #moveFurniture
                    local sPlaced = 0

                    for _, entry in ipairs(moveStructures) do
                        local newCF
                        if entry.isPropertyMode then
                            newCF = entry.worldCF
                        else
                            local rotatedXZ = capturedRot:VectorToWorldSpace(entry.xzOffset)
                            local newPos = Vector3.new(
                                origin.X + rotatedXZ.X,
                                origin.Y + entry.yAbove,
                                origin.Z + rotatedXZ.Z
                            )
                            newCF = CFrame.new(newPos) * capturedRot.Rotation * entry.cf.Rotation
                        end
                        -- Wood blueprints (treeValue set) → ClientPlacedBlueprint + auto plank fill.
                        -- Non-wood structures (Glass, etc.) → ClientPlacedStructure directly.
                        if entry.treeValue and entry.treeValue ~= "" then
                            local ok, _ = PlaceOneBlueprintFromFile(entry.itemName, newCF, entry.treeValue, sb3)
                            if ok then sPlaced += 1 end
                        else
                            local src = FindSourceStructure(entry.itemName)
                            if src then
                                local ok
                                if src:FindFirstChild("PurchasedBoxItemName") then
                                    ok = PlaceOneBoxedStructure(src, newCF, sb3)
                                else
                                    ok = PlaceOneStructure(src, newCF, nil, false, sb3)
                                end
                                if ok then sPlaced += 1 end
                            end
                        end
                    end
                    for _, entry in ipairs(moveFurniture) do
                        local src = FindSourceFurniture(entry.itemName)
                        if src then
                            local newCF
                            if entry.isPropertyMode then
                                newCF = entry.worldCF
                            else
                            local rotatedXZ = capturedRot:VectorToWorldSpace(entry.xzOffset)
                            local newPos = Vector3.new(
                                origin.X + rotatedXZ.X,
                                origin.Y + entry.yAbove,
                                origin.Z + rotatedXZ.Z
                            )
                            newCF = CFrame.new(newPos) * capturedRot.Rotation * entry.cf.Rotation
                            end
                            local ok = PlaceOneFurniture(src, newCF, false, sb3)
                            if ok then sPlaced += 1 end
                        end
                    end
                    if sTotal > 0 then
                        Library:Notify("Blueprints", ("Placed %d/%d structure blueprint(s)/furniture."):format(sPlaced, sTotal), 4)
                    end
                end

                -- Move mode also has structures/furniture (wires + selected together)
                -- FIX: Added WireRotation.Rotation to struct/furniture CFrame so rotation
                --      matches the preview clone's RepositionClone logic.
                if MoveMode and (#moveStructures > 0 or #moveFurniture > 0 or #moveBlueprints > 0) then
                    local sPlaced, sTotal = 0, #moveStructures + #moveFurniture + #moveBlueprints
                    local pm2 = workspace:FindFirstChild("PlayerModels")
                    local sharedBefore = {}
                    if pm2 then for _, m in ipairs(pm2:GetChildren()) do sharedBefore[m] = true end end
                    for _, entry in ipairs(moveStructures) do
                        if entry.model and entry.model.Parent then
                            local rotatedXZ = WireRotation:VectorToWorldSpace(entry.xzOffset)
                            local newPos    = Vector3.new(
                                origin.X + rotatedXZ.X,
                                origin.Y + entry.yAbove,
                                origin.Z + rotatedXZ.Z
                            )
                            local newCF = CFrame.new(newPos) * WireRotation.Rotation * entry.cf.Rotation
                            local ok = PlaceOneStructure(entry.model, newCF, entry.treeValue, true, sharedBefore)
                            if ok then sPlaced += 1 end
                        end
                    end
                    for _, entry in ipairs(moveFurniture) do
                        if entry.model and entry.model.Parent then
                            local rotatedXZ = WireRotation:VectorToWorldSpace(entry.xzOffset)
                            local newPos    = Vector3.new(
                                origin.X + rotatedXZ.X,
                                origin.Y + entry.yAbove,
                                origin.Z + rotatedXZ.Z
                            )
                            local newCF = CFrame.new(newPos) * WireRotation.Rotation * entry.cf.Rotation
                            local ok = PlaceOneFurniture(entry.model, newCF, true, sharedBefore)
                            if ok then sPlaced += 1 end
                        end
                    end
                    for _, entry in ipairs(moveBlueprints) do
                        if entry.model and entry.model.Parent then
                            local rotatedXZ = WireRotation:VectorToWorldSpace(entry.xzOffset)
                            local newPos    = Vector3.new(
                                origin.X + rotatedXZ.X,
                                origin.Y + entry.yAbove,
                                origin.Z + rotatedXZ.Z
                            )
                            local newCF = entry.cf - entry.cf.Position + newPos
                            -- Move Selection: no plank fill
                            local ok = PlaceOneBlueprint(entry.model, newCF, true, sharedBefore)
                            if ok then sPlaced += 1 end
                        end
                    end
                    if sTotal > 0 then
                        Library:Notify("Blueprints", ("Moved %d/%d item(s)."):format(sPlaced, sTotal), 3)
                    end
                end

                StopPlacing()
            end)

        else
            if ActionElement then ActionElement:SetText("Placing..."); ActionElement:SetDisabled(true) end
            local word        = currentWord:upper():gsub("[^A-Z0-9 %-_=+%[%]\\|;:\'\",./<>?!#%^]", "")
            local boundsRects = GetPropertySquares()

            task.spawn(function()
                local wireIndex, posIndex = 1, 0
                local ranOut = false
                local placed, outOfBounds = 0, 0

                for i = 1, #word do
                    if ranOut then break end
                    local ch = word:sub(i, i)
                    if ch ~= " " then
                        local letterOrigin = origin + capturedRot:VectorToWorldSpace(
                            Vector3.new(posIndex * Settings.Spacing, 0, 0)
                        )
                        local rawStrokes = GetLetterPoints(ch, letterOrigin)
                        if rawStrokes then
                            local rotated = RotateStrokes(rawStrokes, letterOrigin)
                            for _, stroke in ipairs(rotated) do
                                local wireObj = wires[wireIndex]
                                if not wireObj or not wireObj.Parent then
                                    Library:Notify("Blueprints", "Ran out of wires at letter \'" .. ch .. "\'!")
                                    ranOut = true; break
                                end
                                local maxDist = GetWireMaxLength(wireObj)
                                if StrokeExceedsMax(stroke, maxDist) then
                                    Library:Notify("Blueprints",
                                        "Cancelled — stroke for \'" .. ch .. "\' exceeds max length (" .. maxDist .. " studs).", 4)
                                    StopPlacing(); return
                                end
                                if boundsRects and not StrokeInsideProperty(stroke, boundsRects) then
                                    outOfBounds = outOfBounds + 1
                                else
                                    local Info = GetWireInfo(wireObj)
                                    if Info then FireWire(wireObj, stroke, Info); placed = placed + 1 end
                                    wireIndex = wireIndex + 1
                                end
                            end
                        end
                    end
                    posIndex = posIndex + 1
                end

                local msg = "Placed \'" .. word .. "\'! (" .. placed .. " wires)"
                if outOfBounds > 0 then msg = msg .. " — " .. outOfBounds .. " skipped (outside property)" end
                Library:Notify("Blueprints", msg, 4)
                StopPlacing()
            end)
        end
    end)

    -- ================================================================
    --  RENDER LOOP
    -- ================================================================
    local previewWasActive = false
    RunService.RenderStepped:Connect(function()
        if PreviewActive and PlaceMode and not Placing then
            BeginPreview()
            local origin
            if BlueprintMode and usePropertyOrigin then
                origin = GetPropertyCenter() or GetCursorWorldPos()
            else
                origin = GetCursorWorldPos()
            end

            local snappedOrigin = SnapToGrid(origin)

            if #moveStructures > 0 or #moveFurniture > 0 or #moveBlueprints > 0 then
                local function RepositionClone(entry)
                    if not entry.previewClone then return end
                    if not entry.previewClone.Parent then return end
                    if entry.isPropertyMode then return end
                    local rotatedXZ = WireRotation:VectorToWorldSpace(entry.xzOffset)
                    local newPos    = Vector3.new(
                        snappedOrigin.X + rotatedXZ.X,
                        snappedOrigin.Y + entry.yAbove,
                        snappedOrigin.Z + rotatedXZ.Z
                    )
                    local newCF
                    if entry.isBlueprint then
                        local baseCF = entry.relCF or entry.cf
                        newCF = baseCF - baseCF.Position + newPos
                    else
                        local rotSource = entry.relCF or entry.cf
                        newCF = CFrame.new(newPos) * WireRotation.Rotation * rotSource.Rotation
                    end
                    pcall(function()
                        if entry.previewClone.PrimaryPart then
                            entry.previewClone:SetPrimaryPartCFrame(newCF)
                        else
                            entry.previewClone:PivotTo(newCF)
                        end
                    end)
                end

                for _, entry in ipairs(moveStructures) do RepositionClone(entry) end
                for _, entry in ipairs(moveFurniture)  do RepositionClone(entry) end
                for _, entry in ipairs(moveBlueprints) do RepositionClone(entry) end

                if BlueprintMode then
                    UpdateBlueprintPreview(snappedOrigin)
                end
            elseif BlueprintMode then
                UpdateBlueprintPreview(snappedOrigin)
            else
                UpdatePreview(snappedOrigin, currentWord:upper())
            end

            EndPreview()
            previewWasActive = true
        elseif not Placing then
            if previewWasActive then ClearPreview(); previewWasActive = false end
        end
    end)

    -- ================================================================
    --  KEYBINDS
    -- ================================================================
    UserInputService.InputBegan:Connect(function(input, gp)
        if gp then return end
        if PlaceMode then
            if input.KeyCode == Enum.KeyCode.R then
                WireRotation = WireRotation * CFrame.Angles(0, math.rad(90), 0)
            elseif input.KeyCode == Enum.KeyCode.T then
                WireRotation = WireRotation * CFrame.Angles(math.rad(90), 0, 0)
            end
        end
        if LassoMode and not PlaceMode and not Placing
        and input.UserInputType == Enum.UserInputType.MouseButton1 then
            LassoDragging = true
            LassoStartPos = UserInputService:GetMouseLocation()
            if LassoFrame then LassoFrame.Size = UDim2.fromOffset(0, 0); LassoFrame.Visible = false end
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if LassoDragging and input.UserInputType == Enum.UserInputType.MouseMovement then
            UpdateLassoFrame(UserInputService:GetMouseLocation())
        end
    end)

    UserInputService.InputEnded:Connect(function(input)
        if LassoDragging and input.UserInputType == Enum.UserInputType.MouseButton1 then
            LassoDragging = false
            if LassoFrame then LassoFrame.Visible = false end
            SelectWiresInLassoRect(LassoStartPos, UserInputService:GetMouseLocation())
            LassoStartPos = nil
        end
    end)

    LocalPlayer.CharacterAdded:Connect(function(char)
        Character = char
        StopPlacing()
    end)
end

return Blueprints