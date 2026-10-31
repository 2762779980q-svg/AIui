--[[
    AIgui  v1.0.0
    A universal waterfall-style multi-window UI library — native Roblox look (white / grey / 1px stroke)

    MIT License · https://github.com/2762779980q-svg/AIui

    ── Load ─────────────────────────────────────────────────
        local AIgui = assert(loadstring(game:HttpGet(
            "https://raw.githubusercontent.com/2762779980q-svg/AIui/main/AIgui.lua"
        )))()

    ── Features ─────────────────────────────────────────────
    · Pure Instance implementation, no dependencies, single file
    · Windows auto-arrange in a waterfall, shortest column first
    · Draggable / collapsible / closable, each window keeps its own state
    · Widgets: Toggle Slider Select MultiSelect ColorPicker Input Keybind
            Button Label Paragraph Divider
    · Overridable theme and metrics, notifications, dropdown and colour popups
    · Unlocks the mouse while open, restores the original behaviour on close
    · Mounts into gethui(), re-parents itself if the container is cleared

    ── Quick start ──────────────────────────────────────────
        local w = UI.Window({ Title = "Settings", Subtitle = "CONFIG" })
        w:Toggle { Text = "Enabled", Default = true, Callback = function(v) end }
        w:Slider { Text = "Speed", Min = 0, Max = 100, Default = 50,
                   Callback = function(v) end }
        UI.Notify { Title = "AIgui", Text = "Ready" }

    ── Implementation notes (read before changing) ──────────
    1. Window height is accumulated row by row via self.cursor, not AutomaticSize.
       AutomaticSize only resolves after a frame, so on the first frame every
       window is 0-height at the top-left corner and visibly jumps into place.
    2. Relayout is shortest-column-first: each window goes into the shortest column.
       Windows the user dragged are flagged manual and excluded from auto layout.
    3. Create the UIStroke once and recolour that same object.
       Calling stroke() again in MouseEnter stacks one more outline per hover.
    4. Dropdown / colour popups are global singletons behind a full-screen veil.
    5. Mouse unlocking must bind after RenderPriority.Last. Game cameras usually
       write at 2000; same-priority order is not guaranteed, so you must exceed it.
]]

local Players      = game:GetService("Players")
local UIS          = game:GetService("UserInputService")
local RunService   = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local LocalPlayer  = Players.LocalPlayer

--=====================================================================
--  Theme
--=====================================================================
local Theme = {
    win         = Color3.fromRGB(255, 255, 255),  -- window background
    line        = Color3.fromRGB(228, 228, 233),  -- window outline
    lineHover   = Color3.fromRGB(217, 217, 223),  -- outline on hover
    lineSoft    = Color3.fromRGB(240, 240, 243),  -- inner separators

    text        = Color3.fromRGB( 58,  58,  62),  -- primary text
    text2       = Color3.fromRGB(138, 138, 145),  -- secondary text / values
    text3       = Color3.fromRGB(179, 179, 186),  -- hints / group captions

    ctrl        = Color3.fromRGB(237, 237, 241),  -- control background
    ctrlHover   = Color3.fromRGB(230, 230, 235),
    accent      = Color3.fromRGB( 74,  74,  80),  -- toggled state / accent
    accentDim   = Color3.fromRGB(112, 112, 122),  -- slider fill

    knob        = Color3.fromRGB(255, 255, 255),
    knobEdge    = Color3.fromRGB(196, 196, 204),

    font        = Enum.Font.Gotham,
    fontMedium  = Enum.Font.GothamMedium,
    textSize    = 12,
    textSizeSm  = 10,
}

--=====================================================================
--  Metrics
--=====================================================================
local M = {
    winW    = 238,
    gap     = 12,
    pad     = 20,
    headH   = 32,
    rowH    = 28,
    sliderH = 46,
    sepH    = 15,
    capH    = 24,
    bodyTop = 3,
    bodyBot = 8,
    radius  = 8,
}

--=====================================================================
--  Helpers
--=====================================================================
local function new(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props) do
        o[k] = v
    end
    if parent then o.Parent = parent end
    return o
end

-- px > 1 = pixels; px <= 1 = scale (0.5 = full circle)
local function corner(inst, px)
    local c = Instance.new("UICorner")
    c.CornerRadius = (px <= 1) and UDim.new(1, 0) or UDim.new(0, px)
    c.Parent = inst
    return c
end

-- 1px stroke that outlines only, no inner fill
local function stroke(inst, color, thickness)
    local s = Instance.new("UIStroke")
    s.Color = color or Theme.line
    s.Thickness = thickness or 1
    s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    s.Parent = inst
    return s
end

local function tween(inst, time, props, style)
    local t = TweenService:Create(
        inst,
        TweenInfo.new(time or 0.12, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        props
    )
    t:Play()
    return t
end

-- UI container fallback chain: gethui -> CoreGui -> PlayerGui
local function getGuiParent()
    local ok, h = pcall(function() return gethui and gethui() end)
    if ok and h then return h end
    local ok2, cg = pcall(function() return game:GetService("CoreGui") end)
    if ok2 and cg then return cg end
    return LocalPlayer:WaitForChild("PlayerGui")
end

local function viewport()
    local cam = workspace.CurrentCamera
    return cam and cam.ViewportSize or Vector2.new(1280, 720)
end

-- Forward declaration: Window uses it below, implementation lives in the layout section
local scheduleLayout

--=====================================================================
--  Module
--=====================================================================
local UI = {}
UI.Windows  = {}
UI.Theme    = Theme
UI.Metrics  = M
UI.MenuOpen = true
UI._destroyed = false

--=====================================================================
--  Root container
--=====================================================================
local gui = new("ScreenGui", {
    Name = "AIgui",
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    DisplayOrder = 999,
})
gui.Parent = getGuiParent()
UI.Gui = gui

-- Some executors rebuild or clear the gethui container; re-parent if it drops.
-- _destroyed guards against the AncestryChanged fired by our own Destroy().
gui.AncestryChanged:Connect(function()
    if gui.Parent or UI._destroyed then return end
    task.defer(function()
        if not gui.Parent and not UI._destroyed then
            gui.Parent = getGuiParent()
        end
    end)
end)

--=====================================================================
--  Input blocker
--  While the menu is open, a full-screen transparent button swallows clicks
--  at the GUI level, so clicking beside a window does not reach the game.
--=====================================================================
local blocker = new("TextButton", {
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    Text = "",
    AutoButtonColor = false,
    ZIndex = 1,
    Visible = false,
}, gui)

--=====================================================================
--  Mouse unlocking
--=====================================================================
local MOUSE_BIND = "AIgui_mouse"
local mouseUnlocked = false
local autoUnlock    = true
local unlockPrio    = Enum.RenderPriority.Last.Value + 1
local savedBehavior, savedIcon = nil, nil

local function writeMouse()
    pcall(function()
        UIS.MouseBehavior    = Enum.MouseBehavior.Default
        UIS.MouseIconEnabled = true
    end)
end

function UI.SetAutoUnlockMouse(v)
    autoUnlock = v and true or false
end

function UI.SetUnlockPriority(n)
    unlockPrio = n
    if mouseUnlocked then
        pcall(function() RunService:UnbindFromRenderStep(MOUSE_BIND) end)
        RunService:BindToRenderStep(MOUSE_BIND, unlockPrio, function()
            if mouseUnlocked then writeMouse() end
        end)
    end
end

function UI.SetMouseUnlocked(on)
    on = on and true or false
    if on == mouseUnlocked then return end
    mouseUnlocked = on

    if on then
        -- Record the original state only on the first open. Otherwise, after a few
        -- toggles you would capture Default and never lock back on close.
        if savedBehavior == nil then
            savedBehavior = UIS.MouseBehavior
            savedIcon     = UIS.MouseIconEnabled
        end
        pcall(function() RunService:UnbindFromRenderStep(MOUSE_BIND) end)
        RunService:BindToRenderStep(MOUSE_BIND, unlockPrio, function()
            if mouseUnlocked then writeMouse() end
        end)
        writeMouse()
    else
        pcall(function() RunService:UnbindFromRenderStep(MOUSE_BIND) end)
        pcall(function()
            UIS.MouseBehavior    = savedBehavior or Enum.MouseBehavior.LockCenter
            UIS.MouseIconEnabled = (savedIcon ~= false)
        end)
        savedBehavior, savedIcon = nil, nil
    end
end

function UI.IsMouseUnlocked()
    return mouseUnlocked
end

--=====================================================================
--  Dropdown popup (global singleton)
--=====================================================================
local dropdown = new("Frame", {
    Visible = false,
    ZIndex = 500,
    BackgroundColor3 = Theme.win,
    BorderSizePixel = 0,
    ClipsDescendants = true,
}, gui)
corner(dropdown, 6)
stroke(dropdown, Theme.line)

local veil = new("TextButton", {
    Visible = false,
    ZIndex = 499,
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    Text = "",
    AutoButtonColor = false,
}, gui)

local function closeDropdown()
    dropdown.Visible = false
    veil.Visible = false
end
UI.CloseDropdown = closeDropdown

-- closeColorPicker is defined later; forward-declared so the veil closes both
local closeColorPicker
veil.MouseButton1Click:Connect(function()
    closeDropdown()
    if closeColorPicker then closeColorPicker() end
end)

local function openDropdown(anchor, values, current, onPick)
    closeDropdown()

    local itemH = 24
    local h = #values * itemH + 8
    local pos = anchor.AbsolutePosition
    local vp  = viewport()

    -- Opens downwards by default, flips up when there is no room below
    local y = pos.Y + anchor.AbsoluteSize.Y + 2
    if y + h > vp.Y - 8 then
        y = math.max(8, pos.Y - h - 2)
    end

    dropdown.Position = UDim2.fromOffset(pos.X, y)
    dropdown.Size     = UDim2.fromOffset(anchor.AbsoluteSize.X, h)
    dropdown.Visible  = true
    veil.Visible      = true

    for _, c in ipairs(dropdown:GetChildren()) do
        if c:IsA("TextButton") then c:Destroy() end
    end

    for i, v in ipairs(values) do
        local picked = (i == current)
        local item = new("TextButton", {
            Size = UDim2.new(1, 0, 0, itemH),
            Position = UDim2.fromOffset(0, 4 + (i - 1) * itemH),
            BackgroundColor3 = Theme.win,
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            Text = tostring(v),
            Font = Theme.font,
            TextSize = Theme.textSize,
            TextColor3 = picked and Theme.text or Theme.text2,
            TextXAlignment = Enum.TextXAlignment.Left,
            AutoButtonColor = false,
            ZIndex = 501,
        }, dropdown)
        new("UIPadding", { PaddingLeft = UDim.new(0, 10) }, item)

        item.MouseEnter:Connect(function()
            item.BackgroundTransparency = 0
            item.BackgroundColor3 = Theme.ctrl
            item.TextColor3 = Theme.text
        end)
        item.MouseLeave:Connect(function()
            item.BackgroundTransparency = 1
            item.TextColor3 = picked and Theme.text or Theme.text2
        end)
        item.MouseButton1Click:Connect(function()
            closeDropdown()
            onPick(v, i)
        end)
    end
end

--=====================================================================
--  Notifications
--  Stacked top-right, auto-dismiss, click to close early.
--=====================================================================
local notifyHolder = new("Frame", {
    AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, -16, 0, 16),
    Size = UDim2.new(0, 220, 0, 0),
    AutomaticSize = Enum.AutomaticSize.Y,
    BackgroundTransparency = 1,
    ZIndex = 800,
}, gui)

new("UIListLayout", {
    Padding = UDim.new(0, 8),
    SortOrder = Enum.SortOrder.LayoutOrder,
    HorizontalAlignment = Enum.HorizontalAlignment.Right,
}, notifyHolder)

local notifyOrder = 0

function UI.Notify(cfg)
    if type(cfg) ~= "table" then
        cfg = { Text = tostring(cfg) }
    end

    notifyOrder = notifyOrder + 1

    -- CanvasGroup allows one tween for the whole card; a Frame needs every child
    local card = new("CanvasGroup", {
        LayoutOrder = notifyOrder,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = Theme.win,
        BorderSizePixel = 0,
        GroupTransparency = 1,
        ZIndex = 801,
    }, notifyHolder)
    corner(card, 8)
    stroke(card, Theme.line)

    new("UIPadding", {
        PaddingTop = UDim.new(0, 10),
        PaddingBottom = UDim.new(0, 10),
        PaddingLeft = UDim.new(0, 12),
        PaddingRight = UDim.new(0, 12),
    }, card)

    new("UIListLayout", {
        Padding = UDim.new(0, 3),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, card)

    if cfg.Title then
        new("TextLabel", {
            LayoutOrder = 1,
            Size = UDim2.new(1, 0, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundTransparency = 1,
            Text = tostring(cfg.Title),
            Font = Theme.fontMedium,
            TextSize = Theme.textSize,
            TextColor3 = Theme.text,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextWrapped = true,
        }, card)
    end

    new("TextLabel", {
        LayoutOrder = 2,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Text = tostring(cfg.Text or ""),
        Font = Theme.font,
        TextSize = 11,
        TextColor3 = Theme.text2,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextWrapped = true,
    }, card)

    local closed = false
    local function close()
        if closed then return end
        closed = true
        local t = tween(card, 0.15, { GroupTransparency = 1 })
        t.Completed:Connect(function()
            card:Destroy()
        end)
    end

    tween(card, 0.18, { GroupTransparency = 0 })
    task.delay(cfg.Duration or 3, close)

    local hit = new("TextButton", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Text = "",
        AutoButtonColor = false,
        ZIndex = 3,
    }, card)
    hit.MouseButton1Click:Connect(close)

    return { Close = close }
end

--=====================================================================
--  Colour picker popup
--  12 preset swatches + three RGB bars, all firing the callback live.
--=====================================================================
local CP_W, CP_H = 172, 132

local colorPicker = new("Frame", {
    Visible = false,
    ZIndex = 520,
    Size = UDim2.fromOffset(CP_W, CP_H),
    BackgroundColor3 = Theme.win,
    BorderSizePixel = 0,
    ClipsDescendants = true,
}, gui)
corner(colorPicker, 8)
stroke(colorPicker, Theme.line)

local cpTarget = nil      -- swatch button currently being edited
local cpCallback = nil
local cpRGB = { 1, 1, 1 }

local PRESETS = {
    Color3.fromRGB(255, 255, 255), Color3.fromRGB(200, 200, 206),
    Color3.fromRGB(120, 120, 128), Color3.fromRGB( 60,  60,  66),
    Color3.fromRGB(255,  92,  92), Color3.fromRGB(255, 168,  64),
    Color3.fromRGB(255, 226,  88), Color3.fromRGB(112, 208, 116),
    Color3.fromRGB( 88, 196, 200), Color3.fromRGB( 92, 148, 255),
    Color3.fromRGB(160, 120, 240), Color3.fromRGB(240, 120, 190),
}

-- preview strip
local cpPreview = new("Frame", {
    Position = UDim2.fromOffset(10, 96),
    Size = UDim2.fromOffset(CP_W - 20, 8),
    BackgroundColor3 = Color3.new(1, 1, 1),
    BorderSizePixel = 0,
}, colorPicker)
corner(cpPreview, 0.5)
stroke(cpPreview, Theme.line, 1)

local function cpApplyColor(c, fire)
    if not c then return end
    cpRGB = { c.R, c.G, c.B }
    cpPreview.BackgroundColor3 = c
    if cpTarget then
        cpTarget.BackgroundColor3 = c
    end
    if fire and cpCallback then
        local ok, err = pcall(cpCallback, c)
        if not ok then warn("[AIgui] colorpicker: " .. tostring(err)) end
    end
end

-- 12 preset swatches (6 columns x 2 rows)
for i, c in ipairs(PRESETS) do
    local col = (i - 1) % 6
    local row = math.floor((i - 1) / 6)
    local sw = new("TextButton", {
        Size = UDim2.fromOffset(22, 22),
        Position = UDim2.fromOffset(10 + col * 26, 10 + row * 26),
        BackgroundColor3 = c,
        BorderSizePixel = 0,
        Text = "",
        AutoButtonColor = false,
        ZIndex = 522,
    }, colorPicker)
    corner(sw, 4)
    stroke(sw, Theme.line, 1)

    sw.MouseButton1Click:Connect(function()
        cpApplyColor(c, true)
    end)
end

-- three mini RGB bars
local cpBars = {}
local cpDragBar = nil

local function makeBar(y, channel, init)
    local bar = new("Frame", {
        Size = UDim2.fromOffset(CP_W - 20, 4),
        Position = UDim2.fromOffset(10, y),
        BackgroundColor3 = Theme.ctrl,
        BorderSizePixel = 0,
        ZIndex = 522,
    }, colorPicker)
    corner(bar, 0.5)

    local fill = new("Frame", {
        Size = UDim2.fromScale(init, 1),
        BackgroundColor3 = Theme.accentDim,
        BorderSizePixel = 0,
        ZIndex = 523,
    }, bar)
    corner(fill, 0.5)

    local hit = new("TextButton", {
        Size = UDim2.new(1, 0, 0, 12),
        Position = UDim2.fromOffset(0, -4),
        BackgroundTransparency = 1,
        Text = "",
        AutoButtonColor = false,
        ZIndex = 524,
    }, bar)

    local rec = { track = bar, fill = fill, ch = channel }
    rec.update = function(clientX)
        local abs = bar.AbsolutePosition
        local wpx = bar.AbsoluteSize.X
        if wpx <= 0 then return end
        local p = math.clamp((clientX - abs.X) / wpx, 0, 1)
        fill.Size = UDim2.fromScale(p, 1)
        cpRGB[channel] = p
        cpApplyColor(Color3.new(cpRGB[1], cpRGB[2], cpRGB[3]), true)
    end

    hit.InputBegan:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1
           and input.UserInputType ~= Enum.UserInputType.Touch then return end
        cpDragBar = rec
        rec.update(input.Position.X)
    end)

    cpBars[channel] = rec
    return bar
end

makeBar(60, 1, 1)
makeBar(70, 2, 1)
makeBar(80, 3, 1)

UIS.InputChanged:Connect(function(input)
    if not cpDragBar then return end
    if input.UserInputType == Enum.UserInputType.MouseMovement
       or input.UserInputType == Enum.UserInputType.Touch then
        cpDragBar.update(input.Position.X)
    end
end)
UIS.InputEnded:Connect(function()
    cpDragBar = nil
end)

closeColorPicker = function()
    colorPicker.Visible = false
    veil.Visible = false
    cpTarget = nil
    cpCallback = nil
end

local function openColorPicker(anchor, current, callback)
    closeDropdown()
    colorPicker.Visible = true
    veil.Visible = true

    local pos = anchor.AbsolutePosition
    local vp  = viewport()
    local x = math.min(pos.X, vp.X - CP_W - 8)
    local y = pos.Y + anchor.AbsoluteSize.Y + 4
    if y + CP_H > vp.Y - 8 then
        y = math.max(8, pos.Y - CP_H - 4)
    end

    colorPicker.Position = UDim2.fromOffset(x, y)
    cpTarget   = anchor
    cpCallback = callback

    for ch = 1, 3 do
        local rec = cpBars[ch]
        local v = (current and ({ current.R, current.G, current.B })[ch]) or 1
        rec.fill.Size = UDim2.fromScale(v, 1)
    end
    cpApplyColor(current or Color3.new(1, 1, 1), false)
end

-- Multi-select popup: reuses the dropdown container, toggles without closing
local function openMultiDropdown(anchor, values, selected, onToggle)
    closeDropdown()

    local itemH = 24
    local h = #values * itemH + 8
    local pos = anchor.AbsolutePosition
    local vp  = viewport()

    local y = pos.Y + anchor.AbsoluteSize.Y + 2
    if y + h > vp.Y - 8 then
        y = math.max(8, pos.Y - h - 2)
    end

    dropdown.Position = UDim2.fromOffset(pos.X, y)
    dropdown.Size     = UDim2.fromOffset(anchor.AbsoluteSize.X, h)
    dropdown.Visible  = true
    veil.Visible      = true

    for _, c in ipairs(dropdown:GetChildren()) do
        if c:IsA("TextButton") then c:Destroy() end
    end

    for i, v in ipairs(values) do
        local item = new("TextButton", {
            Size = UDim2.new(1, 0, 0, itemH),
            Position = UDim2.fromOffset(0, 4 + (i - 1) * itemH),
            BackgroundColor3 = Theme.win,
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            Text = "",
            AutoButtonColor = false,
            ZIndex = 501,
        }, dropdown)

        local mark = new("TextLabel", {
            Size = UDim2.fromOffset(14, itemH),
            Position = UDim2.fromOffset(9, 0),
            BackgroundTransparency = 1,
            Text = selected[i] and "✓" or "",
            Font = Theme.fontMedium,
            TextSize = 11,
            TextColor3 = Theme.accent,
            TextXAlignment = Enum.TextXAlignment.Left,
            ZIndex = 502,
        }, item)

        new("TextLabel", {
            Size = UDim2.new(1, -30, 1, 0),
            Position = UDim2.fromOffset(26, 0),
            BackgroundTransparency = 1,
            Text = tostring(v),
            Font = Theme.font,
            TextSize = Theme.textSize,
            TextColor3 = Theme.text2,
            TextXAlignment = Enum.TextXAlignment.Left,
            ZIndex = 502,
        }, item)

        item.MouseEnter:Connect(function()
            item.BackgroundTransparency = 0
            item.BackgroundColor3 = Theme.ctrl
        end)
        item.MouseLeave:Connect(function()
            item.BackgroundTransparency = 1
        end)
        item.MouseButton1Click:Connect(function()
            selected[i] = not selected[i]
            mark.Text = selected[i] and "✓" or ""
            if onToggle then
                local ok, err = pcall(onToggle, tostring(v), i, selected[i])
                if not ok then warn("[AIgui] multiselect: " .. tostring(err)) end
            end
        end)
    end
end

--=====================================================================
--  Window
--=====================================================================
local Window = {}
Window.__index = Window

function UI.Window(cfg)
    cfg = cfg or {}

    local self = setmetatable({}, Window)
    self.title     = cfg.Title or "Window"
    self.subtitle  = cfg.Subtitle or ""
    self.cursor    = M.bodyTop
    self.collapsed = false
    self.manual    = (cfg.StartPos ~= nil)   -- explicit StartPos means manual placement
    self.conns     = {}
    self.height    = M.headH
    self.z         = 10

    local w = new("Frame", {
        Name = "nu_" .. self.title,
        Size = UDim2.fromOffset(M.winW, M.headH),
        Position = cfg.StartPos or UDim2.fromOffset(-999, -999),
        BackgroundColor3 = Theme.win,
        BorderSizePixel = 0,
        ClipsDescendants = true,
        ZIndex = 10,
    }, gui)
    corner(w, M.radius)
    self.winStroke = stroke(w, Theme.line)
    self.frame = w

    ---------------------------------------------------------------
    --  Title bar
    ---------------------------------------------------------------
    local head = new("Frame", {
        Size = UDim2.new(1, 0, 0, M.headH),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
    }, w)
    self.head = head

    local dot = new("Frame", {
        Size = UDim2.fromOffset(5, 5),
        Position = UDim2.fromOffset(11, 13),
        BackgroundColor3 = Theme.accentDim,
        BorderSizePixel = 0,
    }, head)
    corner(dot, 0.5)

    -- Title and subtitle are ordered by a UIListLayout.
    -- Hand-computing x = 24 + #title * 12 fails on mixed CJK/latin text and overlaps.
    local titleBox = new("Frame", {
        Size = UDim2.new(1, -70, 1, 0),
        Position = UDim2.fromOffset(22, 0),
        BackgroundTransparency = 1,
        ClipsDescendants = true,
    }, head)
    new("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        VerticalAlignment = Enum.VerticalAlignment.Center,
        Padding = UDim.new(0, 5),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, titleBox)

    new("TextLabel", {
        LayoutOrder = 1,
        AutomaticSize = Enum.AutomaticSize.X,
        Size = UDim2.fromOffset(0, 14),
        BackgroundTransparency = 1,
        Text = self.title,
        Font = Theme.fontMedium,
        TextSize = Theme.textSize,
        TextColor3 = Theme.text,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, titleBox)

    if self.subtitle ~= "" then
        new("TextLabel", {
            LayoutOrder = 2,
            AutomaticSize = Enum.AutomaticSize.X,
            Size = UDim2.fromOffset(0, 14),
            BackgroundTransparency = 1,
            Text = self.subtitle,
            Font = Theme.font,
            TextSize = Theme.textSizeSm,
            TextColor3 = Theme.text3,
            TextXAlignment = Enum.TextXAlignment.Left,
        }, titleBox)
    end

    -- collapse
    local fold = new("TextButton", {
        Size = UDim2.fromOffset(20, 20),
        Position = UDim2.new(1, -48, 0, 6),
        BackgroundColor3 = Theme.ctrl,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Text = "–",
        Font = Theme.fontMedium,
        TextSize = 13,
        TextColor3 = Theme.text2,
        AutoButtonColor = false,
        Visible = false,
    }, head)
    corner(fold, 4)

    -- close
    local close = new("TextButton", {
        Size = UDim2.fromOffset(20, 20),
        Position = UDim2.new(1, -26, 0, 6),
        BackgroundColor3 = Theme.ctrl,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Text = "×",
        Font = Theme.fontMedium,
        TextSize = 13,
        TextColor3 = Theme.text2,
        AutoButtonColor = false,
        Visible = false,
    }, head)
    corner(close, 4)

    w.MouseEnter:Connect(function()
        fold.Visible  = true
        close.Visible = true
        self.winStroke.Color = Theme.lineHover
    end)
    w.MouseLeave:Connect(function()
        fold.Visible  = false
        close.Visible = false
        self.winStroke.Color = Theme.line
    end)

    for _, btn in ipairs({ fold, close }) do
        btn.MouseEnter:Connect(function()
            btn.BackgroundTransparency = 0
            btn.TextColor3 = Theme.text
        end)
        btn.MouseLeave:Connect(function()
            btn.BackgroundTransparency = 1
            btn.TextColor3 = Theme.text2
        end)
    end

    -- content container
    self.body = new("Frame", {
        Size = UDim2.new(1, 0, 1, -M.headH),
        Position = UDim2.fromOffset(0, M.headH),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
    }, w)

    self.headLine = new("Frame", {
        Size = UDim2.new(1, 0, 0, 1),
        Position = UDim2.fromOffset(0, M.headH - 1),
        BackgroundColor3 = Theme.lineSoft,
        BorderSizePixel = 0,
    }, w)

    if cfg.Closable ~= false then
        close.MouseButton1Click:Connect(function()
            w.Visible = false
            scheduleLayout()
        end)
    else
        close.Visible = false
        close.Size = UDim2.fromOffset(0, 0)
    end

    if cfg.Collapsible ~= false then
        fold.MouseButton1Click:Connect(function()
            self:SetCollapsed(not self.collapsed)
        end)
    else
        fold.Visible = false
        fold.Size = UDim2.fromOffset(0, 0)
    end

    self:MakeDraggable(head)

    table.insert(UI.Windows, self)
    scheduleLayout()

    -- The menu only really opens once the first window exists:
    -- loading without creating a window must not touch the mouse or enable the
    -- blocker, or a full-screen transparent button would eat every click.
    if #UI.Windows == 1 and UI.MenuOpen then
        UI.SetMenuOpen(true)
    end

    return self
end

-----------------------------------------------------------------------
--  Dragging
-----------------------------------------------------------------------
function Window:MakeDraggable(head)
    local dragging, dragStart, startPos = false, nil, nil

    local function isPress(t)
        return t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch
    end

    self.conns[#self.conns + 1] = head.InputBegan:Connect(function(input)
        if not isPress(input.UserInputType) then return end
        dragging  = true
        dragStart = input.Position
        startPos  = self.frame.Position
        self.manual = true
        self.z = self.z + 1
        self.frame.ZIndex = 100 + self.z
    end)

    self.conns[#self.conns + 1] = UIS.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType ~= Enum.UserInputType.MouseMovement
           and input.UserInputType ~= Enum.UserInputType.Touch then return end
        local d  = input.Position - dragStart
        local vp = viewport()
        local nx = math.clamp(startPos.X.Offset + d.X, 0, math.max(0, vp.X - M.winW))
        local ny = math.clamp(startPos.Y.Offset + d.Y, 0, math.max(0, vp.Y - M.headH))
        self.frame.Position = UDim2.fromOffset(nx, ny)
    end)

    self.conns[#self.conns + 1] = UIS.InputEnded:Connect(function(input)
        if isPress(input.UserInputType) then
            dragging = false
        end
    end)
end

-----------------------------------------------------------------------
--  Height / collapse
-----------------------------------------------------------------------
function Window:GetHeight()
    if self.collapsed then return M.headH end
    return M.headH + self.cursor + M.bodyBot
end

function Window:ApplySize()
    self.height = self:GetHeight()
    self.frame.Size    = UDim2.fromOffset(M.winW, self.height)
    self.body.Visible  = not self.collapsed
    self.headLine.Visible = not self.collapsed
end

function Window:SetCollapsed(v)
    self.collapsed = v and true or false
    self:ApplySize()
    scheduleLayout()
end

-- Reserve a row: advance cursor and sync the window height
function Window:Push(h)
    local y = self.cursor
    self.cursor = self.cursor + h
    self:ApplySize()
    scheduleLayout()
    return y
end

function Window:Row(h)
    local y = self:Push(h)
    return new("Frame", {
        Size = UDim2.new(1, 0, 0, h),
        Position = UDim2.fromOffset(0, y),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
    }, self.body), y
end

-----------------------------------------------------------------------
--  Toggle
-----------------------------------------------------------------------
function Window:Toggle(cfg)
    cfg = cfg or {}
    local row = self:Row(M.rowH)

    new("TextLabel", {
        Size = UDim2.new(1, -74, 1, 0),
        Position = UDim2.fromOffset(12, 0),
        BackgroundTransparency = 1,
        Text = cfg.Text or "",
        Font = Theme.font,
        TextSize = Theme.textSize,
        TextColor3 = Theme.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, row)

    local track = new("Frame", {
        Size = UDim2.fromOffset(30, 17),
        Position = UDim2.new(1, -42, 0.5, -8),
        BackgroundColor3 = cfg.Default and Theme.accent or Theme.ctrl,
        BorderSizePixel = 0,
    }, row)
    corner(track, 0.5)

    local knob = new("Frame", {
        Size = UDim2.fromOffset(13, 13),
        Position = cfg.Default and UDim2.fromOffset(15, 2) or UDim2.fromOffset(2, 2),
        BackgroundColor3 = Theme.knob,
        BorderSizePixel = 0,
        ZIndex = 2,
    }, track)
    corner(knob, 0.5)
    stroke(knob, Theme.knobEdge, 1)

    -- Transparent hitbox over the whole row, so clicking the label also toggles
    local hit = new("TextButton", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Text = "",
        AutoButtonColor = false,
        ZIndex = 3,
    }, row)

    local state = cfg.Default and true or false

    local function set(v, fire)
        state = v
        tween(track, 0.15, { BackgroundColor3 = v and Theme.accent or Theme.ctrl })
        tween(knob, 0.15, { Position = v and UDim2.fromOffset(15, 2) or UDim2.fromOffset(2, 2) })
        if fire and cfg.Callback then
            local ok, err = pcall(cfg.Callback, v)
            if not ok then warn("[AIgui] toggle: " .. tostring(err)) end
        end
    end

    hit.MouseButton1Click:Connect(function() set(not state, true) end)
    hit.MouseEnter:Connect(function()
        tween(track, 0.1, { BackgroundColor3 = state and Theme.accent or Theme.ctrlHover })
    end)
    hit.MouseLeave:Connect(function()
        tween(track, 0.1, { BackgroundColor3 = state and Theme.accent or Theme.ctrl })
    end)

    return {
        Set = function(_, v) set(v, false) end,
        Get = function() return state end,
    }
end

-----------------------------------------------------------------------
--  Slider
-----------------------------------------------------------------------
function Window:Slider(cfg)
    cfg = cfg or {}
    local row = self:Row(M.sliderH)

    local min  = cfg.Min or 0
    local max  = cfg.Max or 100
    local val  = cfg.Default or min
    local rnd  = cfg.Rounding or 0
    local suf  = cfg.Suffix or ""

    new("TextLabel", {
        Size = UDim2.new(1, -70, 0, 14),
        Position = UDim2.fromOffset(12, 6),
        BackgroundTransparency = 1,
        Text = cfg.Text or "",
        Font = Theme.font,
        TextSize = Theme.textSize,
        TextColor3 = Theme.text,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, row)

    local valBox = new("Frame", {
        Size = UDim2.fromOffset(34, 15),
        Position = UDim2.new(1, -46, 0, 6),
        BackgroundColor3 = Theme.ctrl,
        BorderSizePixel = 0,
    }, row)
    corner(valBox, 4)

    local valLabel = new("TextLabel", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Text = tostring(val) .. suf,
        Font = Theme.font,
        TextSize = Theme.textSizeSm,
        TextColor3 = Theme.text2,
    }, valBox)

    local track = new("Frame", {
        Size = UDim2.new(1, -24, 0, 3),
        Position = UDim2.fromOffset(12, 30),
        BackgroundColor3 = Theme.ctrl,
        BorderSizePixel = 0,
    }, row)
    corner(track, 0.5)

    local pct0 = (max > min) and (val - min) / (max - min) or 0

    local fill = new("Frame", {
        Size = UDim2.fromScale(pct0, 1),
        BackgroundColor3 = Theme.accentDim,
        BorderSizePixel = 0,
    }, track)
    corner(fill, 0.5)

    local knob = new("Frame", {
        Size = UDim2.fromOffset(11, 11),
        Position = UDim2.new(pct0, 0, 0.5, 0),
        AnchorPoint = Vector2.new(0.5, 0.5),
        BackgroundColor3 = Theme.knob,
        BorderSizePixel = 0,
        ZIndex = 2,
    }, track)
    corner(knob, 0.5)
    stroke(knob, Theme.knobEdge, 1)

    local hit = new("TextButton", {
        Size = UDim2.new(1, -24, 0, 20),
        Position = UDim2.fromOffset(12, 22),
        BackgroundTransparency = 1,
        Text = "",
        AutoButtonColor = false,
        ZIndex = 3,
    }, row)

    -- Setting a value and deriving one from a coordinate must stay separate.
    -- Merged, Slider:Set(200) would treat 200 as an X coordinate and jump wildly.
    local function setValue(v, fire)
        v = math.clamp(v, min, max)
        if rnd > 0 then
            local m = 10 ^ rnd
            v = math.floor(v * m + 0.5) / m
        else
            v = math.floor(v + 0.5)
        end
        val = v
        local p = (max > min) and (v - min) / (max - min) or 0
        fill.Size     = UDim2.fromScale(p, 1)
        knob.Position = UDim2.new(p, 0, 0.5, 0)
        valLabel.Text = tostring(v) .. suf
        if fire and cfg.Callback then
            local ok, err = pcall(cfg.Callback, v)
            if not ok then warn("[AIgui] slider: " .. tostring(err)) end
        end
    end

    local function applyAt(clientX)
        local abs = track.AbsolutePosition
        local wpx = track.AbsoluteSize.X
        if wpx <= 0 then return end
        local p = math.clamp((clientX - abs.X) / wpx, 0, 1)
        setValue(min + p * (max - min), true)
    end

    local dragging = false
    hit.InputBegan:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1
           and input.UserInputType ~= Enum.UserInputType.Touch then return end
        dragging = true
        applyAt(input.Position.X)
    end)
    self.conns[#self.conns + 1] = UIS.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement
           or input.UserInputType == Enum.UserInputType.Touch then
            applyAt(input.Position.X)
        end
    end)
    self.conns[#self.conns + 1] = UIS.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
           or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)

    return {
        Set = function(_, v) setValue(v, false) end,
        Get = function() return val end,
    }
end

-----------------------------------------------------------------------
--  Select
-----------------------------------------------------------------------
function Window:Select(cfg)
    cfg = cfg or {}
    local row = self:Row(M.rowH)

    new("TextLabel", {
        Size = UDim2.new(1, -120, 1, 0),
        Position = UDim2.fromOffset(12, 0),
        BackgroundTransparency = 1,
        Text = cfg.Text or "",
        Font = Theme.font,
        TextSize = Theme.textSize,
        TextColor3 = Theme.text,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, row)

    local btn = new("TextButton", {
        Size = UDim2.fromOffset(92, 23),
        Position = UDim2.new(1, -104, 0.5, -12),
        BackgroundColor3 = Theme.ctrl,
        BorderSizePixel = 0,
        Text = "",
        AutoButtonColor = false,
    }, row)
    corner(btn, 5)

    local values = cfg.Values or {}
    local idx    = cfg.Default or 1

    local label = new("TextLabel", {
        Size = UDim2.new(1, -18, 1, 0),
        Position = UDim2.fromOffset(7, 0),
        BackgroundTransparency = 1,
        Text = tostring(values[idx] or ""),
        Font = Theme.font,
        TextSize = 11,
        TextColor3 = Theme.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, btn)

    -- Use a glyph, not an ImageLabel: embedded asset ids can vanish or fail to cache
    new("TextLabel", {
        Size = UDim2.fromOffset(10, 10),
        Position = UDim2.new(1, -14, 0.5, -5),
        BackgroundTransparency = 1,
        Text = "▾",
        Font = Theme.fontMedium,
        TextSize = 9,
        TextColor3 = Theme.text2,
        TextXAlignment = Enum.TextXAlignment.Center,
        TextYAlignment = Enum.TextYAlignment.Center,
    }, btn)

    btn.MouseEnter:Connect(function() btn.BackgroundColor3 = Theme.ctrlHover end)
    btn.MouseLeave:Connect(function() btn.BackgroundColor3 = Theme.ctrl end)

    local function pick(v, i)
        idx = i
        label.Text = tostring(v)
        if cfg.Callback then
            local ok, err = pcall(cfg.Callback, v, i)
            if not ok then warn("[AIgui] select: " .. tostring(err)) end
        end
    end

    btn.MouseButton1Click:Connect(function()
        openDropdown(btn, values, idx, pick)
    end)

    return {
        Set = function(_, i) pick(values[i], i) end,
        Get = function() return values[idx], idx end,
    }
end

-----------------------------------------------------------------------
--  Button / Divider / Label
-----------------------------------------------------------------------
function Window:Button(cfg)
    cfg = cfg or {}
    local row = self:Row(30)

    local btn = new("TextButton", {
        Size = UDim2.new(1, -24, 0, 26),
        Position = UDim2.fromOffset(12, 2),
        BackgroundColor3 = Theme.win,
        BorderSizePixel = 0,
        Text = cfg.Text or "Button",
        Font = Theme.font,
        TextSize = Theme.textSize,
        TextColor3 = Theme.text2,
        AutoButtonColor = false,
    }, row)
    corner(btn, 6)
    stroke(btn, Theme.line)

    btn.MouseEnter:Connect(function()
        btn.BackgroundColor3 = Theme.ctrl
        btn.TextColor3 = Theme.text
    end)
    btn.MouseLeave:Connect(function()
        btn.BackgroundColor3 = Theme.win
        btn.TextColor3 = Theme.text2
    end)
    btn.MouseButton1Click:Connect(function()
        if cfg.Callback then
            local ok, err = pcall(cfg.Callback)
            if not ok then warn("[AIgui] button: " .. tostring(err)) end
        end
    end)
    return btn
end

function Window:Divider()
    local row = self:Row(M.sepH)
    new("Frame", {
        Size = UDim2.new(1, -24, 0, 1),
        Position = UDim2.fromOffset(12, 7),
        BackgroundColor3 = Theme.lineSoft,
        BorderSizePixel = 0,
    }, row)
end

function Window:Label(text)
    local row = self:Row(M.capH)
    new("TextLabel", {
        Size = UDim2.new(1, -24, 1, 0),
        Position = UDim2.fromOffset(12, 4),
        BackgroundTransparency = 1,
        Text = tostring(text or ""),
        Font = Theme.font,
        TextSize = Theme.textSizeSm,
        TextColor3 = Theme.text3,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, row)
end

-----------------------------------------------------------------------
--  Keybind
-----------------------------------------------------------------------
function Window:Keybind(cfg)
    cfg = cfg or {}
    local row = self:Row(M.rowH)

    new("TextLabel", {
        Size = UDim2.new(1, -104, 1, 0),
        Position = UDim2.fromOffset(12, 0),
        BackgroundTransparency = 1,
        Text = cfg.Text or "",
        Font = Theme.font,
        TextSize = Theme.textSize,
        TextColor3 = Theme.text,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, row)

    local key = new("TextButton", {
        Size = UDim2.fromOffset(52, 20),
        Position = UDim2.new(1, -64, 0.5, -10),
        BackgroundColor3 = Theme.win,
        BorderSizePixel = 0,
        Text = tostring(cfg.Default or "None"),
        Font = Theme.font,
        TextSize = Theme.textSizeSm,
        TextColor3 = Theme.text2,
        AutoButtonColor = false,
    }, row)
    corner(key, 4)
    stroke(key, Theme.line)

    local listening = false

    key.MouseButton1Click:Connect(function()
        listening = true
        key.Text = "..."
        key.TextColor3 = Theme.accentDim
    end)

    self.conns[#self.conns + 1] = UIS.InputBegan:Connect(function(input)
        if not listening then return end
        if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
        listening = false
        key.Text = input.KeyCode.Name
        key.TextColor3 = Theme.text2
        if cfg.Callback then
            local ok, err = pcall(cfg.Callback, input.KeyCode)
            if not ok then warn("[AIgui] keybind: " .. tostring(err)) end
        end
    end)

    return {
        Set = function(_, name)
            key.Text = tostring(name)
        end,
        Get = function() return key.Text end,
    }
end

-----------------------------------------------------------------------
--  Input (single-line textbox)
-----------------------------------------------------------------------
function Window:Input(cfg)
    cfg = cfg or {}
    local row = self:Row(M.rowH)

    new("TextLabel", {
        Size = UDim2.new(1, -110, 1, 0),
        Position = UDim2.fromOffset(12, 0),
        BackgroundTransparency = 1,
        Text = cfg.Text or "",
        Font = Theme.font,
        TextSize = Theme.textSize,
        TextColor3 = Theme.text,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, row)

    local box = new("TextBox", {
        Size = UDim2.fromOffset(92, 23),
        Position = UDim2.new(1, -104, 0.5, -12),
        BackgroundColor3 = Theme.ctrl,
        BorderSizePixel = 0,
        Text = tostring(cfg.Default or ""),
        PlaceholderText = cfg.Placeholder or "",
        PlaceholderColor3 = Theme.text3,
        Font = Theme.font,
        TextSize = 11,
        TextColor3 = Theme.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        ClearTextOnFocus = false,
        AutoButtonColor = false,
    }, row)
    corner(box, 5)
    new("UIPadding", { PaddingLeft = UDim.new(0, 7) }, box)

    local function fire(enterPressed)
        if cfg.Callback then
            local ok, err = pcall(cfg.Callback, box.Text, enterPressed)
            if not ok then warn("[AIgui] input: " .. tostring(err)) end
        end
    end

    box.Focused:Connect(function() box.BackgroundColor3 = Theme.ctrlHover end)
    box.FocusLost:Connect(function(enter)
        box.BackgroundColor3 = Theme.ctrl
        fire(enter)
    end)

    return {
        Set = function(_, v) box.Text = tostring(v) end,
        Get = function() return box.Text end,
    }
end

-----------------------------------------------------------------------
--  ColorPicker
-----------------------------------------------------------------------
function Window:ColorPicker(cfg)
    cfg = cfg or {}
    local row = self:Row(M.rowH)

    new("TextLabel", {
        Size = UDim2.new(1, -60, 1, 0),
        Position = UDim2.fromOffset(12, 0),
        BackgroundTransparency = 1,
        Text = cfg.Text or "",
        Font = Theme.font,
        TextSize = Theme.textSize,
        TextColor3 = Theme.text,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, row)

    local color = cfg.Default or Color3.new(1, 1, 1)

    local swatch = new("TextButton", {
        Size = UDim2.fromOffset(34, 18),
        Position = UDim2.new(1, -46, 0.5, -9),
        BackgroundColor3 = color,
        BorderSizePixel = 0,
        Text = "",
        AutoButtonColor = false,
    }, row)
    corner(swatch, 4)
    stroke(swatch, Theme.line)

    swatch.MouseButton1Click:Connect(function()
        openColorPicker(swatch, color, function(c)
            color = c
            if cfg.Callback then
                local ok, err = pcall(cfg.Callback, c)
                if not ok then warn("[AIgui] colorpicker: " .. tostring(err)) end
            end
        end)
    end)

    return {
        Set = function(_, c)
            color = c
            swatch.BackgroundColor3 = c
        end,
        Get = function() return color end,
    }
end

-----------------------------------------------------------------------
--  MultiSelect
-----------------------------------------------------------------------
function Window:MultiSelect(cfg)
    cfg = cfg or {}
    local row = self:Row(M.rowH)

    new("TextLabel", {
        Size = UDim2.new(1, -120, 1, 0),
        Position = UDim2.fromOffset(12, 0),
        BackgroundTransparency = 1,
        Text = cfg.Text or "",
        Font = Theme.font,
        TextSize = Theme.textSize,
        TextColor3 = Theme.text,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, row)

    local btn = new("TextButton", {
        Size = UDim2.fromOffset(92, 23),
        Position = UDim2.new(1, -104, 0.5, -12),
        BackgroundColor3 = Theme.ctrl,
        BorderSizePixel = 0,
        Text = "",
        AutoButtonColor = false,
    }, row)
    corner(btn, 5)

    local values  = cfg.Values or {}
    local selected = {}

    if cfg.Default then
        for i, v in pairs(cfg.Default) do
            if type(i) == "number" then
                selected[i] = v
            elseif type(v) == "number" then
                selected[v] = true
            end
        end
    end

    local label = new("TextLabel", {
        Size = UDim2.new(1, -18, 1, 0),
        Position = UDim2.fromOffset(7, 0),
        BackgroundTransparency = 1,
        Text = "",
        Font = Theme.font,
        TextSize = 11,
        TextColor3 = Theme.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, btn)

    new("TextLabel", {
        Size = UDim2.fromOffset(10, 10),
        Position = UDim2.new(1, -14, 0.5, -5),
        BackgroundTransparency = 1,
        Text = "▾",
        Font = Theme.fontMedium,
        TextSize = 9,
        TextColor3 = Theme.text2,
        TextXAlignment = Enum.TextXAlignment.Center,
        TextYAlignment = Enum.TextYAlignment.Center,
    }, btn)

    local function refresh()
        local picked = {}
        for i, v in ipairs(values) do
            if selected[i] then table.insert(picked, tostring(v)) end
        end
        label.Text = (#picked == 0) and "None" or table.concat(picked, ", ")
    end
    refresh()

    btn.MouseEnter:Connect(function() btn.BackgroundColor3 = Theme.ctrlHover end)
    btn.MouseLeave:Connect(function() btn.BackgroundColor3 = Theme.ctrl end)

    btn.MouseButton1Click:Connect(function()
        openMultiDropdown(btn, values, selected, function(v, i, on)
            refresh()
            if cfg.Callback then
                local ok, err = pcall(cfg.Callback, v, i, on)
                if not ok then warn("[AIgui] multiselect: " .. tostring(err)) end
            end
        end)
    end)

    return {
        Set = function(_, list)
            selected = {}
            for _, i in ipairs(list) do selected[i] = true end
            refresh()
        end,
        Get = function()
            local out = {}
            for i = 1, #values do
                if selected[i] then table.insert(out, values[i]) end
            end
            return out
        end,
    }
end

-----------------------------------------------------------------------
--  Paragraph
-----------------------------------------------------------------------
function Window:Paragraph(text, lines)
    local n = lines or 2
    local h = n * 15 + 8
    local row = self:Row(h)

    new("TextLabel", {
        Size = UDim2.new(1, -24, 1, -6),
        Position = UDim2.fromOffset(12, 3),
        BackgroundTransparency = 1,
        Text = tostring(text or ""),
        Font = Theme.font,
        TextSize = 11,
        TextColor3 = Theme.text2,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        TextWrapped = true,
    }, row)
end

-----------------------------------------------------------------------
--  Window methods
-----------------------------------------------------------------------
function Window:Open()
    self.frame.Visible = true
    scheduleLayout()
end

function Window:Close()
    self.frame.Visible = false
    scheduleLayout()
end

function Window:SetTitle(text, subtitle)
    self.title = text or self.title
    if subtitle ~= nil then self.subtitle = subtitle end
    -- The title is a child of the UIListLayout; find the first TextLabel
    local box = self.head:FindFirstChildOfClass("Frame")
    if box then
        local labels = box:GetChildren()
        for _, o in ipairs(labels) do
            if o:IsA("TextLabel") and o.LayoutOrder == 1 then
                o.Text = self.title
                break
            end
        end
    end
end

function Window:Destroy()
    for _, c in ipairs(self.conns) do
        pcall(function() c:Disconnect() end)
    end
    for i, w in ipairs(UI.Windows) do
        if w == self then
            table.remove(UI.Windows, i)
            break
        end
    end
    if self.frame then self.frame:Destroy() end
    if #UI.Windows == 0 and UI.MenuOpen then
        UI.SetMenuOpen(false)
    end
    scheduleLayout()
end

--=====================================================================
--  Waterfall layout
--=====================================================================
local layoutPending = false

scheduleLayout = function()
    if layoutPending then return end
    layoutPending = true
    task.defer(function()
        layoutPending = false
        UI.Relayout()
    end)
end

function UI.Relayout()
    local vp    = viewport()
    local avail = vp.X - M.pad * 2
    local cols  = math.max(1, math.floor((avail + M.gap) / (M.winW + M.gap)))

    local heights = {}
    for i = 1, cols do heights[i] = M.pad end

    for _, win in ipairs(UI.Windows) do
        if win.frame.Visible and not win.manual then
            local c = 1
            for i = 2, cols do
                if heights[i] < heights[c] - 0.5 then c = i end
            end
            win.frame.Position = UDim2.fromOffset(
                M.pad + (c - 1) * (M.winW + M.gap),
                heights[c]
            )
            heights[c] = heights[c] + win.height + M.gap
        end
    end
end

-- Drop every manual placement and lay out again
function UI.Arrange()
    for _, win in ipairs(UI.Windows) do
        win.manual = false
    end
    UI.Relayout()
end

function UI.ShowAll()
    for _, win in ipairs(UI.Windows) do
        win.frame.Visible = true
        win:SetCollapsed(false)
    end
    UI.Arrange()
end

--=====================================================================
--  Theme / metrics overrides
--=====================================================================
function UI.SetTheme(tbl)
    if type(tbl) ~= "table" then return end
    for k, v in pairs(tbl) do
        if Theme[k] ~= nil then Theme[k] = v end
    end
end

function UI.Configure(tbl)
    if type(tbl) ~= "table" then return end
    for k, v in pairs(tbl) do
        if M[k] ~= nil then M[k] = v end
    end
end

--=====================================================================
--  Toggle / menu key
--=====================================================================
local menuKey = Enum.KeyCode.Insert

function UI.SetKey(k)
    if typeof(k) == "EnumItem" then menuKey = k end
end

function UI.SetMenuOpen(v)
    v = v and true or false
    UI.MenuOpen = v
    gui.Enabled    = v
    blocker.Visible = v
    if autoUnlock then
        UI.SetMouseUnlocked(v)
    end
    if not v then closeDropdown() end
end

function UI.ToggleMenu()
    UI.SetMenuOpen(not UI.MenuOpen)
end

UIS.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.KeyCode == menuKey then
        UI.ToggleMenu()
    end
end)

--=====================================================================
--  Cleanup
--=====================================================================
function UI.Destroy()
    UI._destroyed = true
    closeDropdown()
    -- Restore the mouse before tearing down the GUI, otherwise it stays unlocked.
    pcall(function() UI.SetMouseUnlocked(false) end)
    for _, win in ipairs(UI.Windows) do
        for _, c in ipairs(win.conns) do
            pcall(function() c:Disconnect() end)
        end
    end
    table.clear(UI.Windows)
    pcall(function() RunService:UnbindFromRenderStep(MOUSE_BIND) end)
    gui:Destroy()
end

--=====================================================================
--  Relayout on resolution change
--  UserInputService has no ViewportSize; it lives on the Camera.
--  Cameras are rebuilt on respawn, so re-hook whenever CurrentCamera changes.
--=====================================================================
local camConn = nil

local function watchCamera()
    if camConn then
        pcall(function() camConn:Disconnect() end)
        camConn = nil
    end
    local cam = workspace.CurrentCamera
    if cam then
        camConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(scheduleLayout)
    end
    scheduleLayout()
end

watchCamera()
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera)

--=====================================================================
--  Demo windows
--  Only shows what the widgets look like. Delete or skip it in real use.
--=====================================================================
function UI.Demo()
    local w

    w = UI.Window({ Title = "General", Subtitle = "GENERAL" })
    w:Toggle { Text = "Enable", Default = true }
    w:Toggle { Text = "Second toggle", Default = false }
    w:Slider { Text = "Value", Min = 0, Max = 100, Default = 45 }
    w:Slider { Text = "Percent", Min = 0, Max = 100, Default = 80, Suffix = "%" }
    w:Divider()
    w:Select { Text = "Single", Values = { "Option A", "Option B", "Option C" }, Default = 1 }
    w:MultiSelect { Text = "Multi", Values = { "Alpha", "Beta", "Gamma", "Delta" }, Default = { 1, 3 } }
    w:ColorPicker { Text = "Color", Default = Color3.fromRGB(92, 148, 255) }

    w = UI.Window({ Title = "Input", Subtitle = "INPUT" })
    w:Keybind { Text = "Hotkey", Default = "F" }
    w:Input { Text = "Name", Default = "", Placeholder = "type here" }
    w:Divider()
    w:Button { Text = "Apply" }
    w:Button { Text = "Reset" }

    w = UI.Window({ Title = "About", Subtitle = "ABOUT" })
    w:Paragraph("AIgui is a single-file, dependency-free window library. " ..
                "Windows arrange themselves in a waterfall and can be dragged freely.", 3)
    w:Divider()
    w:Label("v1.0.0")
    w:Button { Text = "Notify", Callback = function()
        UI.Notify { Title = "AIgui", Text = "This is a notification.", Duration = 3 }
    end }
    w:Button { Text = "Hide", Callback = function() UI.SetMenuOpen(false) end }
end

return UI
