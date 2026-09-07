--[[
    ================================================================
     FPS BOOSTER PRO + SHADER SUITE
     A full-featured client-side performance & visuals control panel
    ================================================================

    HOW TO USE:
    1. Put this script as a LocalScript inside StarterPlayerScripts
    2. Play the game
    3. Click the floating orb (or press F4) to open the menu

    TABS:
      - Home        : quick presets, live FPS, auto-optimize
      - Graphics    : render quality, shadows, lighting tech, fog, water
      - Shaders     : post-processing effects & color grading presets
      - Performance : particle/effect culling, streaming, cleanup
      - Stats       : live FPS graph, ping, memory, instance count

    NOTE ON "SHADERS":
    Roblox doesn't expose a custom shader pipeline to normal scripts.
    What we CAN control are the built-in post-processing effects
    (Bloom, SunRays, DepthOfField, Blur, ColorCorrection) and the
    Lighting.Technology setting (Voxel / ShadowMap / Future). This
    script combines those into preset "shader" looks.
--]]

----------------------------------------------------------------
-- SERVICES
----------------------------------------------------------------
local Players            = game:GetService("Players")
local Lighting           = game:GetService("Lighting")
local Workspace          = game:GetService("Workspace")
local RunService         = game:GetService("RunService")
local TweenService       = game:GetService("TweenService")
local UserInputService   = game:GetService("UserInputService")
local GuiService         = game:GetService("GuiService")
local Stats              = game:GetService("Stats")
-- NOTE: settings() is Plugin-capability-gated -- calling it from a normal
-- LocalScript (not a plugin) throws immediately, which used to happen
-- right here at module load time and killed the ENTIRE script before any
-- UI was created. RenderSettings is now resolved lazily, inside the same
-- pcall that already wraps every write to it (see Features.SetQualityLevel
-- below), so a normal client never even attempts the settings() call.
local RenderSettings = nil

local player    = Players.LocalPlayer
local PlayerGui = player:WaitForChild("PlayerGui")

----------------------------------------------------------------
-- CONFIG / STATE (internal tracking, not persisted between sessions)
----------------------------------------------------------------
local Config = {
    QualityLevel          = 5,
    GlobalShadows         = true,
    Particles             = true,
    Trails                = true,
    SmokeFire             = true,
    Decals                = true,
    StreamingRadius       = 128,
    OtherAccessoriesVisible = true,
    -- Streaming radius changes assume the game's world was built to
    -- tolerate a client dynamically changing StreamingMinRadius/Target --
    -- not every game is. Gated behind an explicit opt-in instead of
    -- silently being part of every preset/quality level change.
    ExperimentalStreaming = false,
    -- Distance-based effect LOD (see EffectLOD system below). Off by
    -- default -- like streaming, it changes behavior beyond simple
    -- on/off toggles, so it should be something you turn on, not
    -- something that's just silently active.
    EffectLOD             = false,
    EffectLODDistance     = 150,
}

----------------------------------------------------------------
-- ORIGINAL STATE SNAPSHOT
-- Captured immediately, before this script (or its own Balanced()
-- preset at init) touches anything. "Restore Original" below uses this
-- to put the game back the way it actually was -- not just back to
-- OUR idea of a default.
----------------------------------------------------------------
-- Lighting.Technology is read-gated for a normal LocalScript (throws
-- "lacking capability RobloxScript" the same way settings() throws
-- "lacking capability Plugin") -- reading it directly here at module
-- load time used to kill the whole script before any UI existed, the
-- same failure mode as the earlier settings() bug. Read it through a
-- safe helper instead; every write to Technology elsewhere in this file
-- was already wrapped in pcall, this just makes the READS consistent
-- with that.
--
-- StreamingMinRadius / StreamingTargetRadius are a different problem:
-- Roblox docs mark them non-scriptable ("must be set on the Workspace
-- object in Studio") -- a plain property read/write from ANY LocalScript
-- throws "is not a valid member of Workspace", not a capability error.
-- Every WRITE to them elsewhere in this file was already wrapped in
-- pcall (see SetStreamingRadius / RestoreOriginal below); this read at
-- load time was the one place that wasn't.
local function SafeGetTechnology()
    local ok, tech = pcall(function() return Lighting.Technology end)
    return ok and tech or nil
end

local function SafeGetWorkspaceProperty(propName)
    local ok, value = pcall(function() return Workspace[propName] end)
    return ok and value or nil
end

local OriginalWorld = {
    GlobalShadows         = Lighting.GlobalShadows,
    Technology            = SafeGetTechnology(),
    FogEnd                = Lighting.FogEnd,
    FogStart              = Lighting.FogStart,
    StreamingEnabled      = Workspace.StreamingEnabled,
    StreamingMinRadius    = SafeGetWorkspaceProperty("StreamingMinRadius"),
    StreamingTargetRadius = SafeGetWorkspaceProperty("StreamingTargetRadius"),
}

-- Per-object original values, captured lazily the FIRST time we ever
-- touch that object -- so turning a category back "on" restores what
-- the game itself had set, not a hardcoded true / Transparency 0.
-- Weak-keyed so entries for destroyed instances can be collected.
local OriginalEnabled = setmetatable({}, { __mode = "k" })
local OriginalTransparency = setmetatable({}, { __mode = "k" })

local function CaptureEnabled(obj)
    if OriginalEnabled[obj] == nil then
        OriginalEnabled[obj] = obj.Enabled
    end
end

local function CaptureTransparency(obj)
    if OriginalTransparency[obj] == nil then
        OriginalTransparency[obj] = obj.Transparency
    end
end

----------------------------------------------------------------
-- EFFECT REGISTRY
-- Every toggle function, the live-culling listener, the benchmark, and
-- the LOD system below all read from this incrementally-maintained set
-- instead of calling Workspace:GetDescendants() on every single call --
-- that repeated full-tree walk (over EVERY part/mesh/script in the
-- workspace, not just effects) was the biggest avoidable cost in the
-- busy-VFX code paths.
----------------------------------------------------------------
local EffectRegistry = setmetatable({}, { __mode = "k" }) -- obj -> category string

local function ClassifyEffect(obj)
    if obj:IsA("ParticleEmitter") then return "Particles"
    elseif obj:IsA("Trail") or obj:IsA("Beam") then return "Trails"
    elseif obj:IsA("Smoke") or obj:IsA("Fire") or obj:IsA("Sparkles") then return "SmokeFire"
    elseif obj:IsA("Decal") or obj:IsA("Texture") then return "Decals"
    end
    return nil
end

local function RegisterEffect(obj)
    local category = ClassifyEffect(obj)
    if category then EffectRegistry[obj] = category end
    return category
end

-- One-time initial population. Everything after this comes in through
-- the DescendantAdded listener further down -- no more periodic
-- full-tree scans. Also seeds the instance counter in the same pass
-- instead of scanning twice.
local totalInstanceCount = 0
for _, obj in ipairs(Workspace:GetDescendants()) do
    RegisterEffect(obj)
    totalInstanceCount += 1
end
Workspace.DescendantAdded:Connect(function() totalInstanceCount += 1 end)
Workspace.DescendantRemoving:Connect(function() totalInstanceCount = math.max(0, totalInstanceCount - 1) end)

----------------------------------------------------------------
-- THEME
----------------------------------------------------------------
local Theme = {
    Background = Color3.fromRGB(20, 20, 28),
    Panel      = Color3.fromRGB(30, 30, 42),
    PanelLight = Color3.fromRGB(40, 40, 54),
    Accent     = Color3.fromRGB(120, 100, 255),
    AccentDim  = Color3.fromRGB(80, 68, 170),
    Off        = Color3.fromRGB(58, 58, 72),
    Text       = Color3.fromRGB(235, 235, 245),
    SubText    = Color3.fromRGB(150, 150, 168),
    Danger     = Color3.fromRGB(255, 90, 90),
    Warn       = Color3.fromRGB(255, 190, 80),
}

----------------------------------------------------------------
-- FORWARD-DECLARED VARIABLES
-- (filled in later, referenced by closures defined earlier)
----------------------------------------------------------------
local BigFPSLabel, FPSLabel, PingLabel, MemoryLabel, InstanceLabel, GraphBars
local DiagFrameLabel, DiagRenderLabel, DiagGPULabel, DiagScriptLabel, DiagVerdictLabel
local BenchStatusLabel, BenchResultLabel
local autoOptimize = false
local benchmarkRunning = false
local currentFPS   = 60
local fpsSamples   = {}

----------------------------------------------------------------
-- UTILITY FUNCTIONS
----------------------------------------------------------------
local function Create(className, properties, children)
    local inst = Instance.new(className)
    if properties then
        for prop, value in pairs(properties) do
            inst[prop] = value
        end
    end
    if children then
        for _, child in ipairs(children) do
            child.Parent = inst
        end
    end
    return inst
end

local function Tween(obj, props, duration, style, direction)
    duration  = duration or 0.25
    style     = style or Enum.EasingStyle.Quad
    direction = direction or Enum.EasingDirection.Out
    local tween = TweenService:Create(obj, TweenInfo.new(duration, style, direction), props)
    tween:Play()
    return tween
end

local function MakeDraggable(frame, dragHandle)
    dragHandle = dragHandle or frame
    local dragging = false
    local dragInput, dragStart, startPos

    dragHandle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging  = true
            dragStart = input.Position
            startPos  = frame.Position

            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)

    dragHandle.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then
            dragInput = input
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if input == dragInput and dragging then
            local delta = input.Position - dragStart
            frame.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end)
end

----------------------------------------------------------------
-- ROOT UI: ScreenGui, floating orb, main window skeleton
----------------------------------------------------------------
local ScreenGui = Create("ScreenGui", {
    Name = "FPSBoosterProUI",
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    Parent = PlayerGui,
})

-- Floating toggle orb --------------------------------------------------
local ToggleOrb = Create("TextButton", {
    Name = "ToggleOrb",
    Size = UDim2.new(0, 54, 0, 54),
    Position = UDim2.new(0, 20, 0.5, -27),
    BackgroundColor3 = Theme.Accent,
    Text = "FPS",
    Font = Enum.Font.GothamBold,
    TextSize = 14,
    TextColor3 = Color3.new(1, 1, 1),
    AutoButtonColor = false,
    Parent = ScreenGui,
})
Create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = ToggleOrb })
Create("UIStroke", { Color = Color3.new(1,1,1), Thickness = 1, Transparency = 0.7, Parent = ToggleOrb })

-- Floating FPS overlay (visible even with menu closed) ------------------
local FPSOverlay = Create("TextLabel", {
    Name = "FPSOverlay",
    Size = UDim2.new(0, 100, 0, 28),
    Position = UDim2.new(0, 20, 0, 20),
    BackgroundColor3 = Theme.Background,
    BackgroundTransparency = 0.15,
    TextColor3 = Theme.Accent,
    Font = Enum.Font.GothamBold,
    TextSize = 14,
    Text = "FPS: --",
    Visible = false,
    Parent = ScreenGui,
})
Create("UICorner", { CornerRadius = UDim.new(0, 6), Parent = FPSOverlay })

-- Main window -------------------------------------------------------
local MainFrame = Create("Frame", {
    Name = "MainFrame",
    Size = UDim2.new(0, 540, 0, 420),
    Position = UDim2.new(0.5, -270, 0.5, -210),
    BackgroundColor3 = Theme.Background,
    ClipsDescendants = true,
    Visible = false,
    Parent = ScreenGui,
})
Create("UICorner", { CornerRadius = UDim.new(0, 12), Parent = MainFrame })
Create("UIStroke", { Color = Theme.Accent, Thickness = 1.5, Transparency = 0.4, Parent = MainFrame })

-- Top bar -------------------------------------------------------------
local TopBar = Create("Frame", {
    Name = "TopBar",
    Size = UDim2.new(1, 0, 0, 42),
    BackgroundColor3 = Theme.Panel,
    Parent = MainFrame,
})
Create("UICorner", { CornerRadius = UDim.new(0, 12), Parent = TopBar })

Create("TextLabel", {
    Text = "⚡ FPS Booster Pro  +  Shader Suite",
    Font = Enum.Font.GothamBold,
    TextSize = 15,
    TextColor3 = Theme.Text,
    BackgroundTransparency = 1,
    Position = UDim2.new(0, 14, 0, 0),
    Size = UDim2.new(1, -100, 1, 0),
    TextXAlignment = Enum.TextXAlignment.Left,
    Parent = TopBar,
})

local MinimizeButton = Create("TextButton", {
    Text = "–",
    Font = Enum.Font.GothamBold,
    TextSize = 18,
    TextColor3 = Theme.Text,
    BackgroundColor3 = Theme.PanelLight,
    Size = UDim2.new(0, 30, 0, 26),
    Position = UDim2.new(1, -76, 0.5, -13),
    Parent = TopBar,
})
Create("UICorner", { CornerRadius = UDim.new(0, 6), Parent = MinimizeButton })

local CloseButton = Create("TextButton", {
    Text = "×",
    Font = Enum.Font.GothamBold,
    TextSize = 18,
    TextColor3 = Theme.Text,
    BackgroundColor3 = Theme.Danger,
    Size = UDim2.new(0, 30, 0, 26),
    Position = UDim2.new(1, -38, 0.5, -13),
    Parent = TopBar,
})
Create("UICorner", { CornerRadius = UDim.new(0, 6), Parent = CloseButton })

-- Sidebar ---------------------------------------------------------------
local Sidebar = Create("Frame", {
    Name = "Sidebar",
    Size = UDim2.new(0, 130, 1, -42),
    Position = UDim2.new(0, 0, 0, 42),
    BackgroundColor3 = Theme.Panel,
    Parent = MainFrame,
})
Create("UIListLayout", {
    Padding = UDim.new(0, 6),
    SortOrder = Enum.SortOrder.LayoutOrder,
    Parent = Sidebar,
})
Create("UIPadding", {
    PaddingTop = UDim.new(0, 10), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8),
    Parent = Sidebar,
})

-- Content area ------------------------------------------------------------
local ContentArea = Create("Frame", {
    Name = "ContentArea",
    Size = UDim2.new(1, -130, 1, -42),
    Position = UDim2.new(0, 130, 0, 42),
    BackgroundTransparency = 1,
    Parent = MainFrame,
})

----------------------------------------------------------------
-- NOTIFICATIONS
----------------------------------------------------------------
local NotifContainer = Create("Frame", {
    Name = "NotifContainer",
    BackgroundTransparency = 1,
    AnchorPoint = Vector2.new(1, 1),
    Position = UDim2.new(1, -20, 1, -20),
    Size = UDim2.new(0, 280, 1, -40),
    Parent = ScreenGui,
})
Create("UIListLayout", {
    VerticalAlignment = Enum.VerticalAlignment.Bottom,
    HorizontalAlignment = Enum.HorizontalAlignment.Right,
    Padding = UDim.new(0, 8),
    SortOrder = Enum.SortOrder.LayoutOrder,
    Parent = NotifContainer,
})

local function Notify(title, text, duration)
    duration = duration or 3

    local notif = Create("Frame", {
        BackgroundColor3 = Theme.Panel,
        Size = UDim2.new(1, 0, 0, 62),
        ClipsDescendants = true,
        Parent = NotifContainer,
    })
    Create("UICorner", { CornerRadius = UDim.new(0, 8), Parent = notif })
    Create("UIStroke", { Color = Theme.Accent, Thickness = 1, Transparency = 0.4, Parent = notif })

    Create("TextLabel", {
        Text = title,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        TextColor3 = Theme.Accent,
        BackgroundTransparency = 1,
        Position = UDim2.new(0, 10, 0, 6),
        Size = UDim2.new(1, -20, 0, 18),
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = notif,
    })
    Create("TextLabel", {
        Text = text,
        Font = Enum.Font.Gotham,
        TextSize = 12,
        TextColor3 = Theme.SubText,
        BackgroundTransparency = 1,
        Position = UDim2.new(0, 10, 0, 26),
        Size = UDim2.new(1, -20, 0, 30),
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = notif,
    })

    task.delay(duration, function()
        Tween(notif, { BackgroundTransparency = 1 }, 0.3)
        task.wait(0.3)
        notif:Destroy()
    end)
end

----------------------------------------------------------------
-- UI COMPONENT FACTORIES
----------------------------------------------------------------
local function CreateSectionTitle(parent, text)
    Create("TextLabel", {
        Text = text,
        Font = Enum.Font.GothamBold,
        TextSize = 15,
        TextColor3 = Theme.Accent,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, 26),
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = parent,
    })
end

local function CreateToggle(parent, text, default, callback)
    local holder = Create("Frame", {
        Size = UDim2.new(1, 0, 0, 34),
        BackgroundTransparency = 1,
        Parent = parent,
    })

    Create("TextLabel", {
        Text = text,
        Font = Enum.Font.Gotham,
        TextSize = 14,
        TextColor3 = Theme.Text,
        BackgroundTransparency = 1,
        TextXAlignment = Enum.TextXAlignment.Left,
        Size = UDim2.new(1, -60, 1, 0),
        Parent = holder,
    })

    local switchBG = Create("Frame", {
        Size = UDim2.new(0, 44, 0, 22),
        Position = UDim2.new(1, -44, 0.5, -11),
        BackgroundColor3 = default and Theme.Accent or Theme.Off,
        Parent = holder,
    })
    Create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = switchBG })

    local knob = Create("Frame", {
        Size = UDim2.new(0, 18, 0, 18),
        Position = default and UDim2.new(1, -20, 0.5, -9) or UDim2.new(0, 2, 0.5, -9),
        BackgroundColor3 = Color3.new(1, 1, 1),
        Parent = switchBG,
    })
    Create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = knob })

    local button = Create("TextButton", {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Text = "",
        Parent = switchBG,
    })

    local state = default
    button.MouseButton1Click:Connect(function()
        state = not state
        Tween(switchBG, { BackgroundColor3 = state and Theme.Accent or Theme.Off }, 0.18)
        Tween(knob, { Position = state and UDim2.new(1, -20, 0.5, -9) or UDim2.new(0, 2, 0.5, -9) }, 0.18)
        callback(state)
    end)

    return holder
end

local function CreateSlider(parent, text, min, max, default, callback)
    local holder = Create("Frame", {
        Size = UDim2.new(1, 0, 0, 46),
        BackgroundTransparency = 1,
        Parent = parent,
    })

    local label = Create("TextLabel", {
        Text = text .. ": " .. tostring(default),
        Font = Enum.Font.Gotham,
        TextSize = 14,
        TextColor3 = Theme.Text,
        BackgroundTransparency = 1,
        TextXAlignment = Enum.TextXAlignment.Left,
        Size = UDim2.new(1, 0, 0, 18),
        Parent = holder,
    })

    local track = Create("Frame", {
        Size = UDim2.new(1, 0, 0, 6),
        Position = UDim2.new(0, 0, 0, 30),
        BackgroundColor3 = Theme.Off,
        Parent = holder,
    })
    Create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = track })

    local fillRatio = (default - min) / (max - min)

    local fill = Create("Frame", {
        Size = UDim2.new(fillRatio, 0, 1, 0),
        BackgroundColor3 = Theme.Accent,
        Parent = track,
    })
    Create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = fill })

    local knob = Create("Frame", {
        Size = UDim2.new(0, 14, 0, 14),
        Position = UDim2.new(fillRatio, -7, 0.5, -7),
        BackgroundColor3 = Color3.new(1, 1, 1),
        ZIndex = 2,
        Parent = track,
    })
    Create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = knob })

    local dragging = false

    local function updateFromInput(inputPos)
        local relative = math.clamp((inputPos.X - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
        local value = math.floor(min + (max - min) * relative)
        fill.Size = UDim2.new(relative, 0, 1, 0)
        knob.Position = UDim2.new(relative, -7, 0.5, -7)
        label.Text = text .. ": " .. tostring(value)
        callback(value)
    end

    knob.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
        end
    end)

    track.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            updateFromInput(input.Position)
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            updateFromInput(input.Position)
        end
    end)

    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)

    return holder
end

local function CreateButton(parent, text, callback)
    local btn = Create("TextButton", {
        Size = UDim2.new(1, 0, 0, 36),
        BackgroundColor3 = Theme.PanelLight,
        Text = text,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        TextColor3 = Theme.Text,
        AutoButtonColor = false,
        Parent = parent,
    })
    Create("UICorner", { CornerRadius = UDim.new(0, 6), Parent = btn })
    Create("UIStroke", { Color = Theme.Accent, Thickness = 1, Transparency = 0.55, Parent = btn })

    btn.MouseButton1Click:Connect(function()
        Tween(btn, { BackgroundColor3 = Theme.Accent }, 0.1)
        task.wait(0.1)
        Tween(btn, { BackgroundColor3 = Theme.PanelLight }, 0.25)
        callback()
    end)

    return btn
end

local function CreateDropdown(parent, text, options, default, callback)
    local index = table.find(options, default) or 1

    local holder = Create("Frame", {
        Size = UDim2.new(1, 0, 0, 36),
        BackgroundTransparency = 1,
        Parent = parent,
    })

    Create("TextLabel", {
        Text = text,
        Font = Enum.Font.Gotham,
        TextSize = 14,
        TextColor3 = Theme.Text,
        BackgroundTransparency = 1,
        TextXAlignment = Enum.TextXAlignment.Left,
        Size = UDim2.new(0.45, 0, 1, 0),
        Parent = holder,
    })

    local btn = Create("TextButton", {
        Size = UDim2.new(0.55, -4, 0, 28),
        Position = UDim2.new(0.45, 4, 0.5, -14),
        BackgroundColor3 = Theme.PanelLight,
        Text = options[index] .. "  ▸",
        Font = Enum.Font.GothamBold,
        TextSize = 13,
        TextColor3 = Theme.Accent,
        AutoButtonColor = false,
        Parent = holder,
    })
    Create("UICorner", { CornerRadius = UDim.new(0, 6), Parent = btn })

    btn.MouseButton1Click:Connect(function()
        index = index + 1
        if index > #options then index = 1 end
        btn.Text = options[index] .. "  ▸"
        callback(options[index])
    end)

    return holder
end

----------------------------------------------------------------
-- PAGES / TABS SYSTEM
----------------------------------------------------------------
local Pages = {}
local TabButtons = {}

local function CreatePage(name)
    local page = Create("ScrollingFrame", {
        Name = name,
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 4,
        ScrollBarImageColor3 = Theme.Accent,
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        Visible = false,
        Parent = ContentArea,
    })
    Create("UIListLayout", {
        Padding = UDim.new(0, 8),
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent = page,
    })
    Create("UIPadding", {
        PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14),
        PaddingTop = UDim.new(0, 14), PaddingBottom = UDim.new(0, 14),
        Parent = page,
    })
    Pages[name] = page
    return page
end

local function SwitchTab(name)
    for pageName, page in pairs(Pages) do
        page.Visible = (pageName == name)
    end
    for btnName, btn in pairs(TabButtons) do
        Tween(btn, { BackgroundColor3 = (btnName == name) and Theme.Accent or Theme.PanelLight }, 0.15)
    end
end

local TabList = { "Home", "Graphics", "Shaders", "Performance", "Diagnostics", "Stats" }
for _, tabName in ipairs(TabList) do
    local btn = Create("TextButton", {
        Size = UDim2.new(1, 0, 0, 34),
        BackgroundColor3 = Theme.PanelLight,
        Text = tabName,
        Font = Enum.Font.GothamBold,
        TextSize = 13,
        TextColor3 = Theme.Text,
        AutoButtonColor = false,
        Parent = Sidebar,
    })
    Create("UICorner", { CornerRadius = UDim.new(0, 6), Parent = btn })
    TabButtons[tabName] = btn
    CreatePage(tabName)

    btn.MouseButton1Click:Connect(function()
        SwitchTab(tabName)
    end)
end

----------------------------------------------------------------
-- POST-PROCESSING ("SHADER") EFFECT INSTANCES
----------------------------------------------------------------
local ColorCorrection = Create("ColorCorrectionEffect", {
    Name = "FPSB_ColorCorrection", Enabled = false, Parent = Lighting,
})
local Bloom = Create("BloomEffect", {
    Name = "FPSB_Bloom", Enabled = false, Intensity = 0.5, Size = 24, Parent = Lighting,
})
local SunRays = Create("SunRaysEffect", {
    Name = "FPSB_SunRays", Enabled = false, Intensity = 0.15, Spread = 0.5, Parent = Lighting,
})
local DepthOfField = Create("DepthOfFieldEffect", {
    Name = "FPSB_DoF", Enabled = false, FarIntensity = 0.3, NearIntensity = 0, Parent = Lighting,
})
local Blur = Create("BlurEffect", {
    Name = "FPSB_Blur", Enabled = false, Size = 0, Parent = Lighting,
})

----------------------------------------------------------------
-- FEATURES (actual game-affecting logic)
----------------------------------------------------------------
local Features = {}

local QualityLevels = {
    Enum.QualityLevel.Level01, Enum.QualityLevel.Level02, Enum.QualityLevel.Level03,
    Enum.QualityLevel.Level04, Enum.QualityLevel.Level05, Enum.QualityLevel.Level06,
    Enum.QualityLevel.Level07, Enum.QualityLevel.Level08, Enum.QualityLevel.Level09,
    Enum.QualityLevel.Level10,
}

function Features.SetQualityLevel(level)
    -- NOTE: RenderSettings (settings().Rendering) is Plugin-capability-gated.
    -- In a real published game (and in most Studio contexts) a normal
    -- LocalScript can't even call settings() without erroring, so this
    -- resolves it lazily on first use, inside this pcall, instead of at
    -- module load time -- a failed settings() call here just means the
    -- Quality Level slider silently skips the (usually no-op anyway)
    -- engine QualityLevel write and falls through to the settings below
    -- that a LocalScript genuinely can control.
    --
    -- To make the "Quality Level" slider actually DO something client-side,
    -- it now also drives every setting a LocalScript CAN control: shadows,
    -- lighting technology, view distance, streaming radius, and effect
    -- density. Treat level 1-10 as a composite performance/quality dial
    -- rather than a single engine property.
    level = math.clamp(level, 1, 10)
    Config.QualityLevel = level

    pcall(function()
        if RenderSettings == nil then
            RenderSettings = settings().Rendering
        end
        RenderSettings.QualityLevel = QualityLevels[level]
    end)

    local t = (level - 1) / 9 -- normalized 0..1 across the slider range

    Features.SetGlobalShadows(level > 3)
    Features.SetTechnology(level > 6 and "Future" or "Voxel")
    Features.SetFogDistance(math.floor(300 + t * (3000 - 300)))
    Features.SetStreamingRadius(math.floor(64 + t * (256 - 64)))

    local effectsOn = level > 2
    Features.ToggleParticles(effectsOn)
    Features.ToggleTrails(effectsOn)
    Features.ToggleSmokeFire(effectsOn)
    Features.ToggleDecals(level > 1)
end

function Features.SetGlobalShadows(state)
    Lighting.GlobalShadows = state
    Config.GlobalShadows = state
end

function Features.SetTechnology(name)
    local map = {
        Voxel         = Enum.Technology.Voxel,
        ShadowMap     = Enum.Technology.ShadowMap,
        Future        = Enum.Technology.Future,
        Compatibility = Enum.Technology.Compatibility,
    }
    if map[name] then
        pcall(function() Lighting.Technology = map[name] end)
    end
end

function Features.SetFogDistance(distance)
    Lighting.FogEnd = distance
    Lighting.FogStart = math.max(0, distance - 400)
end

function Features.SetWaterQuality(state)
    local terrain = Workspace:FindFirstChildOfClass("Terrain")
    if terrain then
        terrain.WaterReflectance = state and 0.4 or 0
        terrain.WaterWaveSize    = state and 0.15 or 0
        terrain.WaterWaveSpeed   = state and 10 or 0
    end
end

function Features.ToggleParticles(state)
    for obj, category in pairs(EffectRegistry) do
        if category == "Particles" then
            CaptureEnabled(obj)
            obj.Enabled = state and OriginalEnabled[obj]
        end
    end
    Config.Particles = state
end

function Features.ToggleTrails(state)
    for obj, category in pairs(EffectRegistry) do
        if category == "Trails" then
            CaptureEnabled(obj)
            obj.Enabled = state and OriginalEnabled[obj]
        end
    end
    Config.Trails = state
end

function Features.ToggleSmokeFire(state)
    for obj, category in pairs(EffectRegistry) do
        if category == "SmokeFire" then
            CaptureEnabled(obj)
            obj.Enabled = state and OriginalEnabled[obj]
        end
    end
    Config.SmokeFire = state
end

function Features.ToggleDecals(state)
    for obj, category in pairs(EffectRegistry) do
        if category == "Decals" then
            CaptureTransparency(obj)
            obj.Transparency = state and OriginalTransparency[obj] or 1
        end
    end
    Config.Decals = state
end

function Features.SetStreamingRadius(radius)
    if not Config.ExperimentalStreaming then
        Config.StreamingRadius = radius
        return
    end
    Workspace.StreamingEnabled = true
    pcall(function()
        Workspace.StreamingMinRadius = radius
        Workspace.StreamingTargetRadius = radius * 2
    end)
    Config.StreamingRadius = radius
end

function Features.SetOtherAccessoriesVisible(visible)
    Config.OtherAccessoriesVisible = visible
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= player and plr.Character then
            for _, item in ipairs(plr.Character:GetChildren()) do
                if item:IsA("Accessory") then
                    local handle = item:FindFirstChild("Handle")
                    if handle then
                        handle.LocalTransparencyModifier = visible and 0 or 1
                    end
                end
            end
        end
    end
end

-- NOTE: an earlier version had a "Clean Workspace Debris" feature that
-- destroyed any BasePart whose name contained "debris". That's not a
-- real cleanup system -- it's a substring match that could just as
-- easily delete a DebrisDetector, DebrisTrigger, or DebrisDecoration
-- your game actually relies on. Removed rather than kept as a trap.


-- NOTE: Roblox does not expose a GPU/CPU horsepower API to LocalScripts --
-- there's no legitimate way to ask "how strong is this device?" directly.
-- What we CAN read is input method (touch vs mouse/keyboard) and whether
-- it's a console-style 10-foot interface, which is a reasonable proxy for
-- device class. Combined with a live FPS sample, it's a real (if
-- approximate) signal -- not a guess dressed up as detection.
function Features.DetectDeviceProfile()
    local isConsole = false
    pcall(function() isConsole = GuiService:IsTenFootInterface() end)
    if isConsole then return "Console" end

    if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
        and not UserInputService.MouseEnabled then
        return "Mobile"
    end

    return "PC"
end

-- Samples Stats.FrameTime/RenderCPUFrameTime/RenderGPUFrameTime every
-- rendered frame for `duration` seconds and returns a stats table:
-- avgFPS, avgFrameTime, renderCPU, renderGPU, plus percentile "low" FPS
-- figures (1% low / 0.1% low) computed from the per-frame time samples.
-- Average FPS alone can hide stutter -- a run that's mostly 60 with one
-- 10 FPS spike still averages fine, but the 1% low exposes it. This
-- yields (via task.wait) so it must be called from a coroutine
-- (task.spawn), not directly from a UI click handler.
local function SampleFrameStats(duration)
    local total, totalRenderCPU, totalRenderGPU, count = 0, 0, 0, 0
    local frameTimes = {}
    local startClock = os.clock()
    while os.clock() - startClock < duration do
        local ok, ft, rc, rg = pcall(function()
            return Stats.FrameTime, Stats.RenderCPUFrameTime, Stats.RenderGPUFrameTime
        end)
        if ok and ft then
            total += ft
            totalRenderCPU += rc or 0
            totalRenderGPU += rg or 0
            count += 1
            frameTimes[#frameTimes + 1] = ft
        end
        task.wait()
    end
    if count == 0 then
        return { avgFPS = 0, avgFrameTime = 0, renderCPU = 0, renderGPU = 0, low1pct = 0, low01pct = 0, sampleCount = 0 }
    end

    table.sort(frameTimes) -- ascending time = descending FPS; worst frames are at the end

    -- Canonical "1% low FPS": convert each sampled frame TIME to its own
    -- FPS, then average the worst (slowest) 1% of those FPS values. This
    -- is distinct from -- and was previously conflated with -- taking the
    -- worst 1% of frame TIMES, averaging the time, then inverting once;
    -- that computes 1/mean(worst times), which is a legitimate smoothness
    -- metric but is not what "1% low FPS" conventionally means and reads
    -- differently to anyone comparing against other FPS tools.
    local function percentileLowFPS(fraction)
        local n = math.max(1, math.floor(#frameTimes * fraction))
        local startIdx = #frameTimes - n + 1
        local sum = 0
        for i = startIdx, #frameTimes do
            local ft = frameTimes[i]
            sum += (ft > 0 and (1 / ft) or 0)
        end
        return sum / n
    end

    local avgFrameTime = total / count
    return {
        avgFPS       = avgFrameTime > 0 and (1 / avgFrameTime) or 0,
        avgFrameTime = avgFrameTime,
        renderCPU    = totalRenderCPU / count,
        renderGPU    = totalRenderGPU / count,
        low1pct      = percentileLowFPS(0.01),
        low01pct     = percentileLowFPS(0.001),
        sampleCount  = count,
    }
end

-- How many effect-type instances currently exist -- used to tell the user
-- whether the benchmark had enough on-screen effects to measure honestly,
-- rather than silently reporting "no difference" from an empty scene.
local function CountEffectInstances()
    local particles, trails, smokeFire, decals = 0, 0, 0, 0
    for _, category in pairs(EffectRegistry) do
        if category == "Particles" then particles += 1
        elseif category == "Trails" then trails += 1
        elseif category == "SmokeFire" then smokeFire += 1
        elseif category == "Decals" then decals += 1
        end
    end
    return particles, trails, smokeFire, decals
end

-- ----------------------------------------------------------------
-- SMART BENCHMARK v6
-- Rebuilt around three problems the v5 version had:
--   1. It tested "Effects" as one lump (particles+trails+smoke+decals
--      all OFF at once), so it could never tell you WHICH category was
--      actually expensive -- a scene where only Decals cost anything
--      still reported "Effects: +12 FPS" with no way to act on that
--      more precisely. Now each category is toggled and measured
--      separately, and shadows are measured on their own too.
--   2. It could leave the game in a half-changed state (shadows off,
--      effects off, Voxel) if anything errored mid-run, because
--      benchmarkRunning=false and cleanup lived after code that could
--      throw. Now the whole test body runs inside xpcall, and restore
--      is unconditional in a `finally`-style block that always runs.
--   3. It didn't just measure -- it silently replaced the user's
--      current settings with its own idea of a new configuration. Now
--      it snapshots every setting it's about to touch, restores that
--      exact snapshot when the test ends, and applies ONLY the deltas
--      that were proven to help (via ApplyProvenChanges), not a
--      generic quality-level guess.
-- Also: gain threshold is now relative (>=3 FPS AND >=8% of baseline),
-- not a flat 5 FPS -- 5 FPS means very different things at 20 FPS vs
-- 120 FPS. And results report 1% low / avg FPS, not avg alone.
-- ----------------------------------------------------------------
local function MeetsGainThreshold(gain, baseline)
    if baseline <= 0 then return gain > 0 end
    return gain >= 3 and (gain / baseline) >= 0.08
end

function Features.RunSmartBenchmark()
    if benchmarkRunning then return end
    benchmarkRunning = true

    if BenchStatusLabel then BenchStatusLabel.Text = "Running benchmark... (~9s, visuals will flicker)" end
    Notify("Smart Benchmark", "Testing each effect category on THIS device, ~9s total. Visuals will flicker -- that's expected.", 5)

    -- Snapshot everything the benchmark is about to touch, so we can put
    -- the game back exactly as it was regardless of what the test finds
    -- or whether it errors out partway through.
    local snapshot = {
        Particles     = Config.Particles,
        Trails        = Config.Trails,
        SmokeFire     = Config.SmokeFire,
        Decals        = Config.Decals,
        GlobalShadows = Config.GlobalShadows,
        Technology    = SafeGetTechnology(),
        QualityLevel  = Config.QualityLevel,
    }

    local function restoreSnapshot()
        Features.ToggleParticles(snapshot.Particles)
        Features.ToggleTrails(snapshot.Trails)
        Features.ToggleSmokeFire(snapshot.SmokeFire)
        Features.ToggleDecals(snapshot.Decals)
        Features.SetGlobalShadows(snapshot.GlobalShadows)
        pcall(function() Lighting.Technology = snapshot.Technology end)
        Config.QualityLevel = snapshot.QualityLevel
    end

    local pParticles, pTrails, pSmokeFire, pDecals = CountEffectInstances()
    local effectCount = pParticles + pTrails + pSmokeFire + pDecals

    local results = {} -- ordered list of { name, gain, meetsThreshold, sample }
    local baseline

    local ok, err = xpcall(function()
        -- Baseline at whatever's currently active (== the snapshot state).
        baseline = SampleFrameStats(1.2)

        -- Test each category in isolation. Critical: restore the FULL
        -- original snapshot after each test, not just flip this one
        -- category back to `true`. The previous version did `cat.set(true)`,
        -- which is only correct if the category was ON before the
        -- benchmark ran -- if the user had e.g. Particles already OFF,
        -- that line would turn it ON, silently changing their real
        -- settings mid-benchmark and invalidating every test after it
        -- (each subsequent category would be tested against a baseline
        -- state that no longer matches the actual `baseline` measurement).
        -- Restoring the full snapshot before AND after each test guarantees
        -- every category is tested against the exact same original state:
        -- ORIGINAL -> disable ONE category -> measure -> ORIGINAL -> next.
        local categories = {
            { name = "Particles", set = Features.ToggleParticles, count = pParticles },
            { name = "Trails",    set = Features.ToggleTrails,    count = pTrails },
            { name = "SmokeFire", set = Features.ToggleSmokeFire, count = pSmokeFire },
            { name = "Decals",    set = Features.ToggleDecals,    count = pDecals },
        }

        for _, cat in ipairs(categories) do
            restoreSnapshot() -- guarantee a clean, known-original state before this test
            cat.set(false)
            task.wait(0.25)
            local sample = SampleFrameStats(1.0)
            restoreSnapshot() -- back to original -- never "true", never the previous test's leftover state
            task.wait(0.15)

            local gain = sample.avgFPS - baseline.avgFPS
            table.insert(results, {
                name = cat.name,
                gain = gain,
                meetsThreshold = MeetsGainThreshold(gain, baseline.avgFPS),
                sample = sample,
                instanceCount = cat.count,
            })
        end

        -- Shadows tested the same way: from the original snapshot, not
        -- from whatever state the last effect-category test left behind.
        restoreSnapshot()
        Features.SetGlobalShadows(false)
        task.wait(0.25)
        local shadowSample = SampleFrameStats(1.0)
        restoreSnapshot() -- back to original GlobalShadows, not a hardcoded true
        task.wait(0.15)
        local shadowGain = shadowSample.avgFPS - baseline.avgFPS
        table.insert(results, {
            name = "Shadows",
            gain = shadowGain,
            meetsThreshold = MeetsGainThreshold(shadowGain, baseline.avgFPS),
            sample = shadowSample,
        })
    end, debug.traceback)

    if not ok then
        -- Whatever happened, put the game back exactly where it was
        -- before guessing at anything.
        pcall(restoreSnapshot)
        benchmarkRunning = false
        if BenchStatusLabel then BenchStatusLabel.Text = "Benchmark failed -- settings restored, nothing changed." end
        Notify("Benchmark Error", "Something went wrong mid-test. Your original settings were restored; nothing was changed.", 6)
        warn("[FPS Booster] RunSmartBenchmark error: " .. tostring(err))
        return
    end

    -- Restore to the pre-test snapshot before applying only the proven
    -- changes -- never leave the mid-test toggled-off state in place.
    restoreSnapshot()

    -- Apply only the changes that measurably helped. This does NOT
    -- reassign a quality level or invent a new configuration; it flips
    -- exactly the categories that proved their worth on THIS device.
    local appliedOff = {}
    for _, r in ipairs(results) do
        if r.meetsThreshold then
            table.insert(appliedOff, r.name)
            if r.name == "Particles" then Features.ToggleParticles(false)
            elseif r.name == "Trails" then Features.ToggleTrails(false)
            elseif r.name == "SmokeFire" then Features.ToggleSmokeFire(false)
            elseif r.name == "Decals" then Features.ToggleDecals(false)
            elseif r.name == "Shadows" then Features.SetGlobalShadows(false)
            end
        end
    end

    -- Build the result readout: per-category gain, flagged with a low
    -- instance-count warning where relevant, plus baseline smoothness.
    local lines = {}
    for _, r in ipairs(results) do
        local sign = r.gain >= 0 and "+" or ""
        local note = ""
        if r.instanceCount ~= nil and r.instanceCount < 5 then
            note = string.format(" [only %d instances -- low confidence]", r.instanceCount)
        end
        table.insert(lines, string.format("%s: %s%.0f FPS%s%s",
            r.name, sign, r.gain, r.meetsThreshold and " (kept OFF)" or "", note))
    end

    local resultText = string.format(
        "Baseline: %d FPS avg (1%% low: %d). %s. %s",
        math.floor(baseline.avgFPS), math.floor(baseline.low1pct),
        table.concat(lines, " | "),
        #appliedOff > 0
            and ("Disabled: " .. table.concat(appliedOff, ", ") .. ".")
            or "Nothing measurably helped -- current settings left as-is."
    )

    if BenchStatusLabel then BenchStatusLabel.Text = "Last run: just now" end
    if BenchResultLabel then BenchResultLabel.Text = resultText end
    Notify("Benchmark Complete", resultText, 9)

    benchmarkRunning = false
end

----------------------------------------------------------------
-- LIVE CULLING (fixes the "one-time scan" bug)
-- Toggling a culling setting only affects what already exists at that
-- moment. In an active shooter, new ParticleEmitters/Trails/Smoke/Fire/
-- Decals spawn constantly (muzzle flashes, tracers, hit fx), so without
-- this listener they'd reappear seconds after you hit Potato Mode.
----------------------------------------------------------------
Workspace.DescendantAdded:Connect(function(obj)
    local category = RegisterEffect(obj)
    if not category then return end

    -- Capture BEFORE our own override, so "original" reflects what the
    -- object's own spawn logic set it to, not our forced value.
    if category == "Decals" then
        CaptureTransparency(obj)
    else
        CaptureEnabled(obj)
    end

    -- task.defer lets the instance finish initializing (e.g. Enabled
    -- sometimes gets reset by the object's own spawn logic on the same frame).
    -- Between DescendantAdded firing and this deferred callback running, the
    -- object can already have been destroyed (e.g. a short-lived muzzle
    -- flash effect) -- guard on Parent before touching it.
    task.defer(function()
        if obj.Parent == nil then return end

        if category == "Particles" then
            obj.Enabled = Config.Particles and OriginalEnabled[obj]
        elseif category == "Trails" then
            obj.Enabled = Config.Trails and OriginalEnabled[obj]
        elseif category == "SmokeFire" then
            obj.Enabled = Config.SmokeFire and OriginalEnabled[obj]
        elseif category == "Decals" then
            obj.Transparency = Config.Decals and OriginalTransparency[obj] or 1
        end
    end)
end)

----------------------------------------------------------------
-- DISTANCE-BASED EFFECT LOD (the "one real FPS upgrade" addition)
-- Idea: a particle emitter/trail/fire 300 studs from your camera costs
-- roughly the same to simulate as one right next to you, but you can
-- barely see it. This disables effect instances beyond a configurable
-- distance and re-enables them when back in range -- real FPS back in
-- any scene with players/effects spread across a big map, orthogonal to
-- the manual on/off toggles above (which are all-or-nothing).
-- Off by default: like Streaming, it's a behavior change (things you
-- could technically still see up close will vanish at range), not just
-- a simple setting, so it's opt-in rather than silently active.
--
-- v6 changes:
--   - Squared-distance comparison instead of .Magnitude, so this never
--     calls sqrt per effect per tick -- a Dot-product comparison against
--     a squared cutoff is exactly equivalent and meaningfully cheaper
--     at thousands of instances.
--   - Budgeted circular queue: instead of checking every registered
--     effect every 0.5s (which is itself a per-tick cost that scales
--     with scene size -- 5,000 emitters would mean 10,000 checks/sec
--     from a LocalScript), each tick only processes a bounded slice of
--     the registry and advances to the next slice next tick. This
--     caps the LOD system's own frame cost regardless of how many
--     effects exist, at some cost to how quickly a given effect's
--     LOD state updates (bounded by how large the registry is).
--   - Parent-nil guard: an effect can be destroyed between being
--     registered and being processed here; skip it instead of indexing
--     into a nil parent.
----------------------------------------------------------------
local LOD_BUDGET_PER_TICK = 200

task.spawn(function()
    local scanKeys = {}   -- snapshot of registry keys, rebuilt when exhausted
    local scanIndex = 1

    while true do
        task.wait(0.05) -- smaller tick so the per-tick budget spreads work smoothly
        if Config.EffectLOD then
            local camera = Workspace.CurrentCamera
            local camPos = camera and camera.CFrame.Position
            if camPos then
                if scanIndex > #scanKeys then
                    -- Rebuild the queue from the current registry. Done
                    -- periodically (whenever we wrap) rather than every
                    -- tick, so this doesn't reintroduce a full-scan cost.
                    scanKeys = {}
                    for obj in pairs(EffectRegistry) do
                        scanKeys[#scanKeys + 1] = obj
                    end
                    scanIndex = 1
                end

                local cutoffSquared = Config.EffectLODDistance * Config.EffectLODDistance
                local processed = 0
                while processed < LOD_BUDGET_PER_TICK and scanIndex <= #scanKeys do
                    local obj = scanKeys[scanIndex]
                    scanIndex += 1
                    processed += 1

                    if obj and obj.Parent ~= nil then
                        local category = EffectRegistry[obj]
                        if category == "Particles" or category == "Trails" or category == "SmokeFire" then
                            local parent = obj.Parent
                            local pos
                            if parent:IsA("BasePart") then
                                pos = parent.Position
                            elseif parent:IsA("Attachment") then
                                pos = parent.WorldPosition
                            end
                            if pos then
                                CaptureEnabled(obj)
                                local delta = pos - camPos
                                local distanceSquared = delta:Dot(delta)
                                local inRange = distanceSquared <= cutoffSquared
                                local globalOn = (category == "Particles" and Config.Particles)
                                    or (category == "Trails" and Config.Trails)
                                    or (category == "SmokeFire" and Config.SmokeFire)
                                if not inRange then
                                    obj.Enabled = false
                                elseif globalOn then
                                    obj.Enabled = OriginalEnabled[obj]
                                end
                            end
                        end
                    end
                end
            end
        else
            -- LOD disabled: drop the queue so it rebuilds fresh next time
            -- it's turned on, rather than resuming a stale scan.
            scanKeys, scanIndex = {}, 1
        end
    end
end)

-- keep accessory visibility rule applied to players who spawn later
Players.PlayerAdded:Connect(function(plr)
    plr.CharacterAdded:Connect(function(char)
        if Config.OtherAccessoriesVisible == false then
            task.wait(1)
            for _, item in ipairs(char:GetChildren()) do
                if item:IsA("Accessory") then
                    local handle = item:FindFirstChild("Handle")
                    if handle then handle.LocalTransparencyModifier = 1 end
                end
            end
        end
    end)
end)

----------------------------------------------------------------
-- SHADER PRESETS (combinations of post-processing effects)
----------------------------------------------------------------
local ShaderPresets = {}

function ShaderPresets.Off()
    ColorCorrection.Enabled = false
    Bloom.Enabled = false
    SunRays.Enabled = false
    DepthOfField.Enabled = false
    Blur.Enabled = false
end

function ShaderPresets.Cinematic()
    ColorCorrection.Enabled = true
    ColorCorrection.Contrast = 0.15
    ColorCorrection.Saturation = -0.1
    ColorCorrection.TintColor = Color3.fromRGB(255, 245, 230)
    Bloom.Enabled = true
    Bloom.Intensity = 0.6
    Bloom.Size = 24
    DepthOfField.Enabled = true
    DepthOfField.FarIntensity = 0.4
    SunRays.Enabled = true
    SunRays.Intensity = 0.15
    Blur.Enabled = false
end

function ShaderPresets.Vibrant()
    ColorCorrection.Enabled = true
    ColorCorrection.Saturation = 0.4
    ColorCorrection.Contrast = 0.2
    ColorCorrection.TintColor = Color3.fromRGB(255, 255, 255)
    Bloom.Enabled = true
    Bloom.Intensity = 0.9
    Bloom.Size = 16
    SunRays.Enabled = false
    DepthOfField.Enabled = false
    Blur.Enabled = false
end

function ShaderPresets.NightVision()
    ColorCorrection.Enabled = true
    ColorCorrection.TintColor = Color3.fromRGB(140, 255, 140)
    ColorCorrection.Brightness = 0.15
    ColorCorrection.Saturation = -0.6
    Bloom.Enabled = true
    Bloom.Intensity = 1.2
    Bloom.Size = 32
    SunRays.Enabled = false
    DepthOfField.Enabled = false
    Blur.Enabled = false
end

function ShaderPresets.Grayscale()
    ColorCorrection.Enabled = true
    ColorCorrection.Saturation = -1
    ColorCorrection.Contrast = 0.1
    Bloom.Enabled = false
    SunRays.Enabled = false
    DepthOfField.Enabled = false
    Blur.Enabled = false
end

function ShaderPresets.Warm()
    ColorCorrection.Enabled = true
    ColorCorrection.TintColor = Color3.fromRGB(255, 214, 170)
    ColorCorrection.Saturation = 0.1
    Bloom.Enabled = true
    Bloom.Intensity = 0.4
    Bloom.Size = 20
    SunRays.Enabled = false
    DepthOfField.Enabled = false
    Blur.Enabled = false
end

function ShaderPresets.Cold()
    ColorCorrection.Enabled = true
    ColorCorrection.TintColor = Color3.fromRGB(170, 200, 255)
    ColorCorrection.Saturation = -0.1
    Bloom.Enabled = false
    SunRays.Enabled = false
    DepthOfField.Enabled = false
    Blur.Enabled = false
end

function ShaderPresets.Dreamy()
    ColorCorrection.Enabled = true
    ColorCorrection.Brightness = 0.1
    ColorCorrection.Saturation = 0.15
    Blur.Enabled = true
    Blur.Size = 4
    Bloom.Enabled = true
    Bloom.Intensity = 1.4
    Bloom.Size = 40
    SunRays.Enabled = true
    SunRays.Intensity = 0.2
    DepthOfField.Enabled = false
end

----------------------------------------------------------------
-- PERFORMANCE PRESETS
----------------------------------------------------------------
local PerformancePresets = {}

function PerformancePresets.Potato()
    Features.SetQualityLevel(1)
    Features.SetGlobalShadows(false)
    Features.SetTechnology("Voxel")
    Features.SetFogDistance(300)
    Features.ToggleParticles(false)
    Features.ToggleTrails(false)
    Features.ToggleSmokeFire(false)
    Features.ToggleDecals(false)
    Features.SetStreamingRadius(64)
    ShaderPresets.Off()
    Notify("Preset Applied", "Potato Mode: maximum performance", 3)
end

function PerformancePresets.Balanced()
    Features.SetQualityLevel(5)
    Features.SetGlobalShadows(true)
    Features.SetTechnology("Voxel")
    Features.SetFogDistance(1500)
    Features.ToggleParticles(true)
    Features.ToggleTrails(true)
    Features.ToggleSmokeFire(true)
    Features.ToggleDecals(true)
    Features.SetStreamingRadius(128)
    ShaderPresets.Off()
    Notify("Preset Applied", "Balanced Mode", 3)
end

function PerformancePresets.Quality()
    Features.SetQualityLevel(10)
    Features.SetGlobalShadows(true)
    Features.SetTechnology("Future")
    Features.SetFogDistance(3000)
    Features.ToggleParticles(true)
    Features.ToggleTrails(true)
    Features.ToggleSmokeFire(true)
    Features.ToggleDecals(true)
    Features.SetStreamingRadius(256)
    ShaderPresets.Cinematic()
    Notify("Preset Applied", "Quality Mode: best visuals", 3)
end

----------------------------------------------------------------
-- RESTORE ORIGINAL
-- Unlike the old "Reset Everything" button (which just reapplied OUR
-- Balanced preset), this puts Lighting/Streaming/effects back to
-- whatever OriginalWorld/OriginalEnabled/OriginalTransparency captured
-- before this script ever touched them.
----------------------------------------------------------------
function Features.RestoreOriginal()
    Lighting.GlobalShadows = OriginalWorld.GlobalShadows
    pcall(function() Lighting.Technology = OriginalWorld.Technology end)
    Lighting.FogEnd = OriginalWorld.FogEnd
    Lighting.FogStart = OriginalWorld.FogStart

    Workspace.StreamingEnabled = OriginalWorld.StreamingEnabled
    pcall(function()
        Workspace.StreamingMinRadius = OriginalWorld.StreamingMinRadius
        Workspace.StreamingTargetRadius = OriginalWorld.StreamingTargetRadius
    end)

    for obj, category in pairs(EffectRegistry) do
        if category == "Decals" then
            if OriginalTransparency[obj] ~= nil then
                obj.Transparency = OriginalTransparency[obj]
            end
        elseif OriginalEnabled[obj] ~= nil then
            obj.Enabled = OriginalEnabled[obj]
        end
    end

    -- These flags mean "respect each object's original value" in the
    -- toggle functions above, which is exactly what we just restored to.
    Config.Particles, Config.Trails, Config.SmokeFire, Config.Decals = true, true, true, true
    Config.GlobalShadows = OriginalWorld.GlobalShadows
    Config.QualityLevel = 5
    Config.ExperimentalStreaming = false
    Config.EffectLOD = false

    ShaderPresets.Off()
    Notify("Restored", "Reverted to the settings your game had before this tool touched anything.", 4)
end

----------------------------------------------------------------
-- BUILD PAGE CONTENTS
----------------------------------------------------------------

-- HOME -------------------------------------------------------------
local homePage = Pages["Home"]

CreateSectionTitle(homePage, "Overview")

BigFPSLabel = Create("TextLabel", {
    Text = "FPS: --",
    Font = Enum.Font.GothamBold,
    TextSize = 30,
    TextColor3 = Theme.Accent,
    BackgroundTransparency = 1,
    Size = UDim2.new(1, 0, 0, 40),
    TextXAlignment = Enum.TextXAlignment.Left,
    Parent = homePage,
})

CreateSectionTitle(homePage, "Quick Presets")
CreateButton(homePage, "🥔  Potato Mode (Max Performance)", function() PerformancePresets.Potato() end)
CreateButton(homePage, "⚖️  Balanced Mode", function() PerformancePresets.Balanced() end)
CreateButton(homePage, "✨  Quality Mode (Best Visuals)", function() PerformancePresets.Quality() end)

CreateSectionTitle(homePage, "Automation")
CreateToggle(homePage, "Adaptive Auto-Optimize (gradually adjusts Quality Level)", false, function(state)
    autoOptimize = state
    Notify("Auto-Optimize", state and "Enabled" or "Disabled", 2)
end)

CreateSectionTitle(homePage, "Maintenance")
CreateButton(homePage, "↺  Restore Original Settings", function()
    Features.RestoreOriginal()
end)

Create("TextLabel", {
    Text = "Made with Claude  •  FPS Booster Pro v2.0",
    Font = Enum.Font.Gotham,
    TextSize = 11,
    TextColor3 = Theme.SubText,
    BackgroundTransparency = 1,
    Size = UDim2.new(1, 0, 0, 20),
    TextXAlignment = Enum.TextXAlignment.Left,
    Parent = homePage,
})

-- GRAPHICS -----------------------------------------------------------
local graphicsPage = Pages["Graphics"]

CreateSectionTitle(graphicsPage, "Rendering")
-- Labeled "Quality Profile" rather than "Quality Level": this drives a
-- composite of client-controllable settings (shadows, technology, fog,
-- streaming, effect density), not the engine's real QualityLevel --
-- that property is PluginSecurity-protected and the write to it is
-- best-effort/no-op in a published game (see Features.SetQualityLevel).
-- Calling it "Level" implied a precision this doesn't have.
CreateSlider(graphicsPage, "Quality Profile", 1, 10, 5, function(v) Features.SetQualityLevel(v) end)
CreateToggle(graphicsPage, "Global Shadows", true, function(v) Features.SetGlobalShadows(v) end)
CreateDropdown(graphicsPage, "Lighting Technology", { "Voxel", "ShadowMap", "Future", "Compatibility" }, "Voxel",
    function(v) Features.SetTechnology(v) end)

CreateSectionTitle(graphicsPage, "World")
CreateSlider(graphicsPage, "View Distance (Fog)", 100, 3000, 1500, function(v) Features.SetFogDistance(v) end)
CreateToggle(graphicsPage, "Water Reflections & Waves", true, function(v) Features.SetWaterQuality(v) end)

-- SHADERS -----------------------------------------------------------
local shadersPage = Pages["Shaders"]

CreateSectionTitle(shadersPage, "Shader Presets")
CreateDropdown(shadersPage, "Preset",
    { "Off", "Cinematic", "Vibrant", "NightVision", "Grayscale", "Warm", "Cold", "Dreamy" }, "Off",
    function(v)
        ShaderPresets[v]()
        Notify("Shader", "Applied preset: " .. v, 2)
    end)

CreateSectionTitle(shadersPage, "Manual Effects")
CreateToggle(shadersPage, "Bloom", false, function(v) Bloom.Enabled = v end)
CreateSlider(shadersPage, "Bloom Intensity", 0, 5, 1, function(v) Bloom.Intensity = v end)
CreateToggle(shadersPage, "Sun Rays", false, function(v) SunRays.Enabled = v end)
CreateSlider(shadersPage, "Sun Rays Intensity (%)", 0, 100, 15, function(v) SunRays.Intensity = v / 100 end)
CreateToggle(shadersPage, "Depth Of Field", false, function(v) DepthOfField.Enabled = v end)
CreateToggle(shadersPage, "Blur", false, function(v) Blur.Enabled = v end)
CreateSlider(shadersPage, "Blur Size", 0, 56, 0, function(v) Blur.Size = v end)

CreateSectionTitle(shadersPage, "Color Grading")
CreateToggle(shadersPage, "Enable Color Correction", false, function(v) ColorCorrection.Enabled = v end)
CreateSlider(shadersPage, "Brightness (%)", -100, 100, 0, function(v) ColorCorrection.Brightness = v / 100 end)
CreateSlider(shadersPage, "Contrast (%)", -100, 100, 0, function(v) ColorCorrection.Contrast = v / 100 end)
CreateSlider(shadersPage, "Saturation (%)", -100, 100, 0, function(v) ColorCorrection.Saturation = v / 100 end)

-- PERFORMANCE --------------------------------------------------------
local perfPage = Pages["Performance"]

CreateSectionTitle(perfPage, "Effects Culling")
CreateToggle(perfPage, "Particles", true, function(v) Features.ToggleParticles(v) end)
CreateToggle(perfPage, "Trails & Beams", true, function(v) Features.ToggleTrails(v) end)
CreateToggle(perfPage, "Smoke & Fire", true, function(v) Features.ToggleSmokeFire(v) end)
CreateToggle(perfPage, "Decals & Textures", true, function(v) Features.ToggleDecals(v) end)
CreateToggle(perfPage, "Hide Other Players' Accessories", false, function(v)
    Features.SetOtherAccessoriesVisible(not v)
end)

CreateSectionTitle(perfPage, "Distance-Based Effect LOD")
Create("TextLabel", {
    Text = "Auto-disables particles/trails/smoke/fire beyond a distance from your camera, and re-enables them when back in range. Effects far away cost the same to render as close ones but you can barely see them -- this is free FPS in scenes with lots of players/effects spread out.",
    Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = Theme.SubText,
    BackgroundTransparency = 1, TextWrapped = true,
    Size = UDim2.new(1, 0, 0, 60), TextXAlignment = Enum.TextXAlignment.Left,
    Parent = perfPage,
})
CreateToggle(perfPage, "Enable Effect LOD", false, function(v)
    Config.EffectLOD = v
end)
CreateSlider(perfPage, "LOD Cutoff Distance (studs)", 50, 400, 150, function(v)
    Config.EffectLODDistance = v
end)

CreateSectionTitle(perfPage, "World Streaming (Experimental)")
Create("TextLabel", {
    Text = "Changing streaming radius from a LocalScript assumes your game's world was built to tolerate it. If your game wasn't designed for that, you may see pop-in or missing objects. Off by default -- opt in only if you've tested it in your own game.",
    Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = Theme.SubText,
    BackgroundTransparency = 1, TextWrapped = true,
    Size = UDim2.new(1, 0, 0, 50), TextXAlignment = Enum.TextXAlignment.Left,
    Parent = perfPage,
})
CreateToggle(perfPage, "Enable Streaming Radius Control", false, function(v)
    Config.ExperimentalStreaming = v
    if not v then
        -- put streaming back exactly as the game had it, don't leave a
        -- half-applied radius sitting there
        Workspace.StreamingEnabled = OriginalWorld.StreamingEnabled
        pcall(function()
            Workspace.StreamingMinRadius = OriginalWorld.StreamingMinRadius
            Workspace.StreamingTargetRadius = OriginalWorld.StreamingTargetRadius
        end)
    end
end)
CreateSlider(perfPage, "Streaming Radius (studs)", 64, 512, 128, function(v) Features.SetStreamingRadius(v) end)

-- DIAGNOSTICS ----------------------------------------------------------
-- Answers "is my bottleneck even graphics?" without you having to open
-- the Microprofiler by hand. Stats.FrameTime / RenderCPUFrameTime /
-- RenderGPUFrameTime are real, documented client-side properties.
-- "Script/Physics" below is FrameTime minus RenderCPUFrameTime -- an
-- approximation (CPU render and script work can overlap slightly), but
-- it's a solid proxy for which half of the frame budget is winning.
-- For pinpointing WHICH script, drop debug.profilebegin("label") /
-- debug.profileend() around suspect code -- it'll show up as a named
-- block in the real Microprofiler (F9).
local diagPage = Pages["Diagnostics"]

CreateSectionTitle(diagPage, "Where Is Your Frame Time Going?")

DiagFrameLabel = Create("TextLabel", {
    Text = "Frame Time: -- ms", Font = Enum.Font.GothamBold, TextSize = 16,
    TextColor3 = Theme.Text, BackgroundTransparency = 1,
    Size = UDim2.new(1, 0, 0, 22), TextXAlignment = Enum.TextXAlignment.Left,
    Parent = diagPage,
})
DiagRenderLabel = Create("TextLabel", {
    Text = "Render (CPU): -- ms", Font = Enum.Font.Gotham, TextSize = 14,
    TextColor3 = Theme.SubText, BackgroundTransparency = 1,
    Size = UDim2.new(1, 0, 0, 20), TextXAlignment = Enum.TextXAlignment.Left,
    Parent = diagPage,
})
DiagGPULabel = Create("TextLabel", {
    Text = "Render (GPU): -- ms", Font = Enum.Font.Gotham, TextSize = 14,
    TextColor3 = Theme.SubText, BackgroundTransparency = 1,
    Size = UDim2.new(1, 0, 0, 20), TextXAlignment = Enum.TextXAlignment.Left,
    Parent = diagPage,
})
DiagScriptLabel = Create("TextLabel", {
    Text = "Script/Physics (est.): -- ms", Font = Enum.Font.Gotham, TextSize = 14,
    TextColor3 = Theme.SubText, BackgroundTransparency = 1,
    Size = UDim2.new(1, 0, 0, 20), TextXAlignment = Enum.TextXAlignment.Left,
    Parent = diagPage,
})

CreateSectionTitle(diagPage, "Verdict")
DiagVerdictLabel = Create("TextLabel", {
    Text = "Collecting samples...", Font = Enum.Font.GothamBold, TextSize = 14,
    TextColor3 = Theme.Accent, BackgroundTransparency = 1, TextWrapped = true,
    Size = UDim2.new(1, 0, 0, 40), TextXAlignment = Enum.TextXAlignment.Left,
    Parent = diagPage,
})

CreateSectionTitle(diagPage, "Deeper Drill-Down")
CreateButton(diagPage, "🔬  How to profile a specific script", function()
    Notify("Microprofiler Tip", "Wrap suspect code in debug.profilebegin('name') / debug.profileend() then press F9 -- it shows up as a labeled block you can inspect frame-by-frame.", 6)
end)

CreateSectionTitle(diagPage, "Smart Benchmark")
Create("TextLabel", {
    Text = "A/B tests each effect category and shadows separately on your device (~9s) instead of guessing, then restores your settings and applies only what proved to help. Best run somewhere safe, not mid-fight -- visuals will flicker during the test.",
    Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = Theme.SubText,
    BackgroundTransparency = 1, TextWrapped = true,
    Size = UDim2.new(1, 0, 0, 46), TextXAlignment = Enum.TextXAlignment.Left,
    Parent = diagPage,
})
CreateButton(diagPage, "🧪  Run Smart Benchmark (~5s)", function()
    task.spawn(Features.RunSmartBenchmark)
end)
BenchStatusLabel = Create("TextLabel", {
    Text = "Not run yet", Font = Enum.Font.GothamBold, TextSize = 13,
    TextColor3 = Theme.Text, BackgroundTransparency = 1,
    Size = UDim2.new(1, 0, 0, 20), TextXAlignment = Enum.TextXAlignment.Left,
    Parent = diagPage,
})
BenchResultLabel = Create("TextLabel", {
    Text = "", Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = Theme.SubText,
    BackgroundTransparency = 1, TextWrapped = true,
    Size = UDim2.new(1, 0, 0, 60), TextXAlignment = Enum.TextXAlignment.Left,
    Parent = diagPage,
})

-- STATS --------------------------------------------------------------
local statsPage = Pages["Stats"]

CreateSectionTitle(statsPage, "Live Metrics")

FPSLabel = Create("TextLabel", {
    Text = "FPS: --", Font = Enum.Font.GothamBold, TextSize = 18,
    TextColor3 = Theme.Text, BackgroundTransparency = 1,
    Size = UDim2.new(1, 0, 0, 22), TextXAlignment = Enum.TextXAlignment.Left,
    Parent = statsPage,
})
PingLabel = Create("TextLabel", {
    Text = "Ping: -- ms", Font = Enum.Font.Gotham, TextSize = 14,
    TextColor3 = Theme.SubText, BackgroundTransparency = 1,
    Size = UDim2.new(1, 0, 0, 20), TextXAlignment = Enum.TextXAlignment.Left,
    Parent = statsPage,
})
MemoryLabel = Create("TextLabel", {
    Text = "Memory: -- MB", Font = Enum.Font.Gotham, TextSize = 14,
    TextColor3 = Theme.SubText, BackgroundTransparency = 1,
    Size = UDim2.new(1, 0, 0, 20), TextXAlignment = Enum.TextXAlignment.Left,
    Parent = statsPage,
})
InstanceLabel = Create("TextLabel", {
    Text = "Instances: --", Font = Enum.Font.Gotham, TextSize = 14,
    TextColor3 = Theme.SubText, BackgroundTransparency = 1,
    Size = UDim2.new(1, 0, 0, 20), TextXAlignment = Enum.TextXAlignment.Left,
    Parent = statsPage,
})

CreateSectionTitle(statsPage, "FPS Graph (last ~15s)")
local GraphContainer = Create("Frame", {
    Size = UDim2.new(1, 0, 0, 100),
    BackgroundColor3 = Theme.Panel,
    Parent = statsPage,
})
Create("UICorner", { CornerRadius = UDim.new(0, 8), Parent = GraphContainer })
Create("UIListLayout", {
    FillDirection = Enum.FillDirection.Horizontal,
    VerticalAlignment = Enum.VerticalAlignment.Bottom,
    Padding = UDim.new(0, 2),
    Parent = GraphContainer,
})

GraphBars = { bars = {}, history = {}, maxBars = 30 }
for i = 1, GraphBars.maxBars do
    local bar = Create("Frame", {
        Size = UDim2.new(1 / GraphBars.maxBars - 0.01, 0, 0.3, 0),
        BackgroundColor3 = Theme.Accent,
        Parent = GraphContainer,
    })
    table.insert(GraphBars.bars, bar)
end

CreateSectionTitle(statsPage, "Overlay")
CreateToggle(statsPage, "Show Floating FPS Overlay", false, function(v)
    FPSOverlay.Visible = v
end)

----------------------------------------------------------------
-- FPS TRACKING
----------------------------------------------------------------
local frameCount = 0
local lastSecond = tick()

RunService.RenderStepped:Connect(function()
    frameCount += 1
    local now = tick()
    if now - lastSecond >= 1 then
        currentFPS = frameCount
        frameCount = 0
        lastSecond = now

        table.insert(fpsSamples, currentFPS)
        if #fpsSamples > 30 then
            table.remove(fpsSamples, 1)
        end
    end
end)

local function GetAverageFPS()
    if #fpsSamples == 0 then return currentFPS end
    local sum = 0
    for _, v in ipairs(fpsSamples) do sum += v end
    return math.floor(sum / #fpsSamples)
end

----------------------------------------------------------------
-- STATS UPDATE LOOP (labels + graph + overlay)
----------------------------------------------------------------
task.spawn(function()
    while true do
        task.wait(0.5)

        if BigFPSLabel then BigFPSLabel.Text = "FPS: " .. currentFPS end
        if FPSLabel then FPSLabel.Text = "FPS: " .. currentFPS end
        if FPSOverlay.Visible then FPSOverlay.Text = "FPS: " .. currentFPS end

        local ping = 0
        pcall(function()
            ping = math.floor(Stats.Network.ServerStatsItem["Data Ping"]:GetValue())
        end)
        if PingLabel then PingLabel.Text = "Ping: " .. ping .. " ms" end

        local mem = 0
        pcall(function() mem = math.floor(Stats:GetTotalMemoryUsageMb()) end)
        if MemoryLabel then MemoryLabel.Text = "Memory: " .. mem .. " MB" end

        if InstanceLabel then
            InstanceLabel.Text = "Instances: " .. totalInstanceCount
        end

        if GraphBars then
            table.insert(GraphBars.history, currentFPS)
            if #GraphBars.history > GraphBars.maxBars then
                table.remove(GraphBars.history, 1)
            end
            for i, bar in ipairs(GraphBars.bars) do
                local value = GraphBars.history[i]
                if value then
                    local heightScale = math.clamp(value / 120, 0.05, 1)
                    bar.Size = UDim2.new(1 / GraphBars.maxBars - 0.01, 0, heightScale, 0)
                    bar.BackgroundColor3 = value < 30 and Theme.Danger
                        or (value < 50 and Theme.Warn or Theme.Accent)
                end
            end
        end

        -- Diagnostics: real Stats properties, not a guess.
        -- v6: renamed "Script/Physics" to "Non-render frame time (est.)" --
        -- it's frameTime minus renderCPU, which lumps together scripts,
        -- physics, networking, and anything else off the render thread.
        -- Calling it "Script/Physics" implied a precision this estimate
        -- doesn't have.
        local ok, frameTime, renderCPU, renderGPU = pcall(function()
            return Stats.FrameTime, Stats.RenderCPUFrameTime, Stats.RenderGPUFrameTime
        end)
        if ok and DiagFrameLabel then
            frameTime = frameTime or 0
            renderCPU = renderCPU or 0
            renderGPU = renderGPU or 0
            local nonRenderTime = math.max(0, frameTime - renderCPU)

            DiagFrameLabel.Text  = string.format("Frame Time: %.1f ms  (~%d FPS)", frameTime * 1000, frameTime > 0 and math.floor(1 / frameTime) or 0)
            DiagRenderLabel.Text = string.format("Render (CPU): %.1f ms", renderCPU * 1000)
            DiagGPULabel.Text    = string.format("Render (GPU): %.1f ms", renderGPU * 1000)
            DiagScriptLabel.Text = string.format("Non-render frame time (est.): %.1f ms", nonRenderTime * 1000)

            -- v6 bottleneck classification: previously this only compared
            -- renderCPU against total frameTime, which can't distinguish
            -- "GPU-bound" from "CPU-render-bound" -- both show up as high
            -- render share. Now GPU time is checked directly, and the
            -- three categories (GPU / CPU-render / simulation) are
            -- compared against each other so the verdict names whichever
            -- one actually dominates, instead of only ever picking
            -- between "render" and "script".
            if frameTime > 0 then
                local gpuShare  = renderGPU / frameTime
                local cpuShare  = renderCPU / frameTime
                local simShare  = nonRenderTime / frameTime

                if gpuShare >= cpuShare and gpuShare >= simShare and gpuShare > 0.4 then
                    DiagVerdictLabel.Text = "GPU-bound: GPU render time dominates your frame. Effects, shadows, and post-processing (Bloom/DoF/SunRays) are the highest-value things to cut."
                    DiagVerdictLabel.TextColor3 = Theme.Accent
                elseif cpuShare >= gpuShare and cpuShare >= simShare and cpuShare > 0.4 then
                    DiagVerdictLabel.Text = "CPU-render-bound: CPU-side render work (geometry, lighting setup, draw calls) dominates. Lowering Quality Profile and view/streaming distance should give a real gain."
                    DiagVerdictLabel.TextColor3 = Theme.Warn
                elseif simShare > 0.4 then
                    DiagVerdictLabel.Text = "Simulation-bound: most of your frame is scripts/physics/networking, not rendering. Graphics settings will help only a little -- profile your gameplay scripts instead."
                    DiagVerdictLabel.TextColor3 = Theme.Danger
                else
                    DiagVerdictLabel.Text = "Mixed: no single stage clearly dominates. Graphics settings will help some; script/physics optimization matters too."
                    DiagVerdictLabel.TextColor3 = Theme.SubText
                end
            end
        elseif DiagFrameLabel then
            DiagFrameLabel.Text = "Frame Time: unavailable on this platform"
        end
    end
end)

----------------------------------------------------------------
-- ADAPTIVE AUTO-OPTIMIZE
-- The old version was: any single sample under 30 FPS -> full Potato
-- nuke, every 5s, with no memory of what it just did. Two problems with
-- that: (1) a borderline 28/31/29 FPS run could nuke -> nothing ->
-- nuke every few seconds, and (2) each Potato call itself touches ~8
-- settings across the whole effect registry, so the "optimizer" could
-- contribute its own frame spikes.
-- This version requires a few consecutive low readings before dropping
-- ONE quality tier (not straight to Potato), enforces a cooldown after
-- any change before judging again, and will step back UP a tier if FPS
-- has been comfortably good for a while -- so it settles instead of
-- oscillating.
----------------------------------------------------------------
task.spawn(function()
    local lowStreak, highStreak = 0, 0
    local cooldownUntil = 0

    while true do
        task.wait(3)

        if not autoOptimize then
            lowStreak, highStreak = 0, 0
        else
            local avgFPS = GetAverageFPS()
            local now = os.clock()

            if avgFPS < 30 then
                lowStreak += 1
                highStreak = 0
            elseif avgFPS > 55 then
                highStreak += 1
                lowStreak = 0
            else
                lowStreak, highStreak = 0, 0
            end

            if now >= cooldownUntil then
                if lowStreak >= 3 then
                    local newLevel = math.max(1, Config.QualityLevel - 2)
                    if newLevel ~= Config.QualityLevel then
                        Features.SetQualityLevel(newLevel)
                        Notify("Adaptive Optimize", "FPS under 30 for a while -- dropped Quality Level to " .. newLevel .. ".", 4)
                    end
                    lowStreak = 0
                    cooldownUntil = now + 8
                elseif highStreak >= 5 then
                    local newLevel = math.min(10, Config.QualityLevel + 1)
                    if newLevel ~= Config.QualityLevel then
                        Features.SetQualityLevel(newLevel)
                        Notify("Adaptive Optimize", "FPS comfortably high for a while -- raised Quality Level to " .. newLevel .. ".", 4)
                    end
                    highStreak = 0
                    cooldownUntil = now + 10
                end
            end
        end
    end
end)

----------------------------------------------------------------
-- AUTO-DETECT ON JOIN
-- v6 change: device type (Mobile/Console/PC) is only a STARTING PRIOR,
-- not the recommendation itself. Two mobile devices can have wildly
-- different real performance (a 120Hz high-end phone vs. a weak budget
-- one both classify as "Mobile" and previously both got Quality 3) --
-- the actual FPS/frame-time/1%-low measurement below is what refines
-- that prior into something meaningful for THIS device.
--
-- v6 also stops silently applying anything on load. Previously this
-- called Features.SetQualityLevel() directly, and separately, init
-- unconditionally called PerformancePresets.Balanced() -- meaning the
-- script altered the game's settings before the player ever opened the
-- menu or asked for anything. Now this only RECOMMENDS: it shows the
-- player what it would set and applies it automatically only if they've
-- already turned Adaptive Auto-Optimize on. Otherwise, nothing is
-- touched until the player chooses a preset or drags a slider.
----------------------------------------------------------------
local function RunAutoDetect()
    local profile = Features.DetectDeviceProfile()
    local priorLevel = ({ Mobile = 3, Console = 5, PC = 7 })[profile] or 5

    -- Real measurement over a short warm-up window refines the prior --
    -- this is what actually distinguishes a strong device from a weak
    -- one within the same device class.
    local warmup = SampleFrameStats(2.0)
    local recommendedLevel = priorLevel

    if warmup.sampleCount > 0 then
        if warmup.low1pct > 0 and warmup.low1pct < 20 then
            -- Stutter-prone even if the average looks OK -- weight the
            -- recommendation down more than average FPS alone would.
            recommendedLevel = math.max(1, priorLevel - 3)
        elseif warmup.avgFPS < 30 then
            recommendedLevel = math.max(1, priorLevel - 2)
        elseif warmup.avgFPS >= 55 and warmup.low1pct >= 45 then
            recommendedLevel = math.min(10, priorLevel + 1)
        end
    end

    if autoOptimize then
        Features.SetQualityLevel(recommendedLevel)
        Notify(
            "Auto-Detected: " .. profile,
            string.format("Applied Quality Profile %d (device: %s, avg %d FPS / 1%% low %d). Adaptive Auto-Optimize is on. Adjust anytime in Graphics.",
                recommendedLevel, profile, math.floor(warmup.avgFPS), math.floor(warmup.low1pct)),
            6
        )
    else
        Notify(
            "Auto-Detected: " .. profile,
            string.format("Recommended Quality Profile %d (avg %d FPS / 1%% low %d) -- not applied. Pick a preset on Home, drag the slider on Graphics, or enable Adaptive Auto-Optimize to use it automatically.",
                recommendedLevel, math.floor(warmup.avgFPS), math.floor(warmup.low1pct)),
            7
        )
    end
end

task.spawn(function()
    task.wait(4)
    RunAutoDetect()
end)

----------------------------------------------------------------
-- WINDOW BEHAVIOR: drag, open/close, minimize, keybind
----------------------------------------------------------------
MakeDraggable(MainFrame, TopBar)
MakeDraggable(ToggleOrb)

local function ToggleMenu()
    if MainFrame.Visible then
        Tween(MainFrame, { Size = UDim2.new(0, 540, 0, 0) }, 0.2)
        task.wait(0.2)
        MainFrame.Visible = false
        MainFrame.Size = UDim2.new(0, 540, 0, 420)
    else
        MainFrame.Size = UDim2.new(0, 540, 0, 0)
        MainFrame.Visible = true
        Tween(MainFrame, { Size = UDim2.new(0, 540, 0, 420) }, 0.25)
    end
end

ToggleOrb.MouseButton1Click:Connect(ToggleMenu)

CloseButton.MouseButton1Click:Connect(function()
    if MainFrame.Visible then ToggleMenu() end
end)

local minimized = false
MinimizeButton.MouseButton1Click:Connect(function()
    minimized = not minimized
    Sidebar.Visible = not minimized
    ContentArea.Visible = not minimized
    Tween(MainFrame, { Size = minimized and UDim2.new(0, 540, 0, 42) or UDim2.new(0, 540, 0, 420) }, 0.2)
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.KeyCode == Enum.KeyCode.F4 then
        ToggleMenu()
    end
end)

----------------------------------------------------------------
-- INIT
-- v6: no longer calls PerformancePresets.Balanced() here. Loading the
-- script should not, by itself, change the game's settings -- that
-- contradicted the entire point of "Restore Original" existing. The
-- game stays exactly as the player found it until they open the menu
-- and choose a preset/slider, or until RunAutoDetect applies a
-- recommendation because they've explicitly turned Adaptive
-- Auto-Optimize on.
----------------------------------------------------------------
SwitchTab("Home")

task.delay(1, function()
    Notify("FPS Booster Pro Loaded", "Click the orb or press F4 to open the menu", 4)
end)
