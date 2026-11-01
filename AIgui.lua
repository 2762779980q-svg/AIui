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
local TextService  = game:GetService("TextService")
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
    notifyW = 220,   -- notification card width
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
UI.LastError = nil

-- Callbacks are user code and may throw. We swallow the error instead of
-- printing: a widget callback firing every frame would flood the console.
-- The last one is kept here so you can inspect it on demand.
local function reportError(where, err)
    UI.LastError = "[" .. tostring(where) .. "] " .. tostring(err)
end

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
--
--  Why setting MouseBehavior once does not work:
--    Games lock the cursor by writing MouseBehavior = LockCenter every frame,
--    usually from a camera controller on RenderPriority.Last (2000). A single
--    write, or one from a plain RenderStepped, is overwritten in the same
--    frame and the cursor vanishes again.
--
--  Three layers, most reliable first:
--    1. GetPropertyChangedSignal - the moment the game writes, we write back.
--       Independent of frame order, catches locks from any phase.
--    2. Heartbeat - runs after every RenderStepped, catches writes that did
--       not fire the signal for whatever reason.
--    3. BindToRenderStep(Last) - final net for camera controllers.
--
--  The priority is Last (2000), NOT Last + 1. Priorities above 2000 are
--  clamped back to 2000, which silently dropped us into the same bucket as
--  the camera and made the write order a coin flip.
--=====================================================================
local MOUSE_BIND = "AIgui_mouse"
local mouseUnlocked  = false
local autoUnlock     = true
local rightHoldLook  = true    -- hold RMB to look around while the menu is open
local rightHeld      = false
-- Latched when RMB is released while we are about to give the cursor back.
-- InputEnded for the release can arrive AFTER the menu is already closed, so
-- without this flag the close path restores Default and then the stale
-- InputEnded handler drags the cursor back to LockCenter - the cursor is then
-- stuck centred with no crosshair: only the camera moves, the pointer does not.
local restorePending = false
local unlockPrio    = Enum.RenderPriority.Last.Value
local savedBehavior, savedIcon = nil, nil
local mouseConns   = {}
local writingMouse = false
-- true while SetMouseUnlocked(false) is doing its own writes. Both the
-- MouseBehavior changed-signal handler and the RenderStep bind can fire in the
-- middle of the restore; without this they immediately undo it.
local restoringMouse = false
-- How many times the post-close verification had to re-assert the restore.
-- Non-zero means something is fighting us; surfaced in GetMouseState().
local mouseRepairs = 0

-- Named rather than inline, so pcall can take the function itself instead of
-- allocating a new closure on every Heartbeat tick.
local function applyMouse()
    if not mouseUnlocked then return end
    if restoringMouse then return end

    -- Compare before writing: assigning the same value still fires the changed
    -- signal, which would re-enter this path through the handlers below.
    if rightHeld and rightHoldLook then
        -- Right button held: snap back to LockCenter. The game camera only
        -- receives mouse delta while the cursor is centred, so this is what
        -- makes "hold right button to look around" work with the menu open.
        -- The cursor parks itself in the middle of the screen on release.
        if UIS.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
            UIS.MouseBehavior = Enum.MouseBehavior.LockCenter
        end
        if UIS.MouseIconEnabled then
            UIS.MouseIconEnabled = false
        end
    else
        if UIS.MouseBehavior ~= Enum.MouseBehavior.Default then
            UIS.MouseBehavior = Enum.MouseBehavior.Default
        end
        if not UIS.MouseIconEnabled then
            UIS.MouseIconEnabled = true
        end
    end
end

local function writeMouse()
    if not mouseUnlocked then return end
    if restoringMouse then return end
    if writingMouse then return end
    writingMouse = true
    pcall(applyMouse)
    writingMouse = false
end

local function bindRenderStep()
    pcall(function() RunService:UnbindFromRenderStep(MOUSE_BIND) end)
    pcall(function()
        RunService:BindToRenderStep(MOUSE_BIND, unlockPrio, function()
            if mouseUnlocked then writeMouse() end
        end)
    end)
end

local function startHold()
    if #mouseConns > 0 then return end

    mouseConns[#mouseConns + 1] = UIS:GetPropertyChangedSignal("MouseBehavior"):Connect(function()
        if mouseUnlocked then writeMouse() end
    end)
    mouseConns[#mouseConns + 1] = UIS:GetPropertyChangedSignal("MouseIconEnabled"):Connect(function()
        if mouseUnlocked then writeMouse() end
    end)
    mouseConns[#mouseConns + 1] = RunService.Heartbeat:Connect(function()
        if mouseUnlocked then writeMouse() end
    end)

    -- Right button: temporarily hand the cursor back to the game so the camera
    -- can turn. gameProcessed is deliberately ignored - holding RMB on top of a
    -- window should still let you look around.
    mouseConns[#mouseConns + 1] = UIS.InputBegan:Connect(function(input)
        if not mouseUnlocked or not rightHoldLook then return end
        if input.UserInputType ~= Enum.UserInputType.MouseButton2 then return end
        rightHeld = true
        writeMouse()
    end)
    mouseConns[#mouseConns + 1] = UIS.InputEnded:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton2 then return end
        if not rightHeld then return end
        rightHeld = false
        -- If the menu was closed while RMB was still down, the close path
        -- already restored the cursor. Writing again here would re-apply the
        -- post-hold state and leave the pointer locked. Let the close win.
        if restorePending or not mouseUnlocked then
            restorePending = false
            return
        end
        writeMouse()
    end)

    bindRenderStep()
end

local function stopHold()
    for _, c in ipairs(mouseConns) do
        pcall(function() c:Disconnect() end)
    end
    table.clear(mouseConns)
    pcall(function() RunService:UnbindFromRenderStep(MOUSE_BIND) end)
end

function UI.SetAutoUnlockMouse(v)
    autoUnlock = v and true or false
end

-- Force the cursor back to a usable state, whatever happened before.
-- Use this from a keybind or a button when a game (or a stale event) has left
-- the pointer locked. Works even if the library thinks it is already locked.
function UI.ForceRestoreMouse()
    rightHeld      = false
    restorePending = true
    restoringMouse = true
    pcall(function()
        UIS.MouseIconEnabled = true
        UIS.MouseBehavior    = Enum.MouseBehavior.Default
    end)
    restoringMouse = false
    task.defer(function() restorePending = false end)
end

function UI.SetUnlockPriority(n)
    unlockPrio = n
    if mouseUnlocked then bindRenderStep() end
end

-- Hold RMB to look around while the menu is open. On by default.
function UI.SetRightHoldLook(v)
    rightHoldLook = v and true or false
    if not rightHoldLook then
        rightHeld = false
        writeMouse()
    end
end

function UI.SetMouseUnlocked(on)
    on = on and true or false

    -- Closing must always run the full restore, even when our own flag already
    -- says "locked". That early return used to skip the restore entirely: if
    -- anything had cleared mouseUnlocked while the cursor was still pinned to
    -- LockCenter, the cursor stayed pinned forever (the reported bug).
    if on == mouseUnlocked and on then return end
    local wasUnlocked = mouseUnlocked
    mouseUnlocked = on

    if on then
        -- Record the original state only on the first unlock. Capturing it on
        -- every open would store Default and never lock back on close.
        if savedBehavior == nil then
            savedBehavior = UIS.MouseBehavior
            savedIcon     = UIS.MouseIconEnabled
        end
        restorePending = false
        startHold()
        writeMouse()
    else
        if not wasUnlocked and savedBehavior == nil then
            -- Nothing was ever recorded and we are not unlocked, so restore is
            -- still correct to run - just use Default rather than guessing.
            rightHeld      = false
            restorePending = true
            stopHold()
            restoringMouse = true
            pcall(function()
                UIS.MouseIconEnabled = true
                UIS.MouseBehavior    = Enum.MouseBehavior.Default
            end)
            restoringMouse = false
            pcall(function() RunService:UnbindFromRenderStep(MOUSE_BIND) end)
            task.defer(function() restorePending = false end)
            return
        end

        -- Detach first: the changed-signal handlers would otherwise re-enter
        -- applyMouse while we are writing the restored values.
        rightHeld = false
        -- Latch a pending restore so an InputEnded that arrives after this
        -- point knows the close already won and must not touch the cursor.
        restorePending = true
        stopHold()

        -- Never fall back to LockCenter, and never restore a recorded value
        -- that IS LockCenter with the icon hidden - that combination is the
        -- "cursor stuck in the middle, no crosshair" state itself.
        local wantBehavior = savedBehavior or Enum.MouseBehavior.Default
        local wantIcon     = (savedIcon ~= false)
        if wantBehavior == Enum.MouseBehavior.LockCenter and wantIcon == false then
            wantBehavior = Enum.MouseBehavior.Default
            wantIcon     = true
        end

        restoringMouse = true
        pcall(function()
            UIS.MouseIconEnabled = wantIcon
            UIS.MouseBehavior    = wantBehavior
        end)
        restoringMouse = false

        savedBehavior, savedIcon = nil, nil

        -- Unbind once more: stopHold already did, but a bind created between
        -- the two calls (resolution change, SetUnlockPriority) would survive.
        pcall(function() RunService:UnbindFromRenderStep(MOUSE_BIND) end)

        -- Verify on the next frame. A stale InputEnded, a late RenderStep tick
        -- or the game's own writer can undo the restore; re-assert once and
        -- then give up (retrying forever would fight a game that legitimately
        -- wants LockCenter, e.g. first person).
        task.defer(function()
            restorePending = false
            if mouseUnlocked then return end
            local b, i = UIS.MouseBehavior, UIS.MouseIconEnabled
            if b ~= wantBehavior or i ~= wantIcon then
                restoringMouse = true
                pcall(function()
                    UIS.MouseIconEnabled = wantIcon
                    UIS.MouseBehavior    = wantBehavior
                end)
                restoringMouse = false
                mouseRepairs = mouseRepairs + 1
            end
        end)
    end
end

function UI.IsMouseUnlocked()
    return mouseUnlocked
end

-- Diagnostics: useful when a game refuses to release the cursor.
function UI.GetMouseState()
    return {
        unlocked      = mouseUnlocked,
        behavior      = UIS.MouseBehavior,
        iconEnabled   = UIS.MouseIconEnabled,
        auto          = autoUnlock,
        rightHeld     = rightHeld,
        rightLook     = rightHoldLook,
        priority      = unlockPrio,
        -- stuck == true means the exact symptom users report as "cursor is
        -- pinned to the centre with no crosshair". Should never happen after a
        -- clean close; if it does, mouseRepairs tells you something fought us.
        stuck         = (not mouseUnlocked)
                        and UIS.MouseBehavior == Enum.MouseBehavior.LockCenter
                        and UIS.MouseIconEnabled == false,
        repairs       = mouseRepairs,
    }
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
--
--  Lives in its own ScreenGui so notifications still show while the menu is
--  closed - that is usually when you want them.
--=====================================================================
local notifyGui = new("ScreenGui", {
    Name = "AIgui_notify",
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    DisplayOrder = 1000,
})
notifyGui.Parent = getGuiParent()

notifyGui.AncestryChanged:Connect(function()
    if notifyGui.Parent or UI._destroyed then return end
    task.defer(function()
        if not notifyGui.Parent and not UI._destroyed then
            notifyGui.Parent = getGuiParent()
        end
    end)
end)
UI.NotifyGui = notifyGui

-- Y = 54 clears the Roblox topbar icons in the top-right corner
local notifyHolder = new("Frame", {
    AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, -16, 0, 54),
    Size = UDim2.new(0, 220, 0, 0),
    AutomaticSize = Enum.AutomaticSize.Y,
    BackgroundTransparency = 1,
    ZIndex = 800,
}, notifyGui)

new("UIListLayout", {
    Padding = UDim.new(0, 8),
    SortOrder = Enum.SortOrder.LayoutOrder,
    HorizontalAlignment = Enum.HorizontalAlignment.Right,
}, notifyHolder)

local notifyOrder = 0

-- The card is a plain Frame, NOT a CanvasGroup. A CanvasGroup renders its
-- subtree into a layer that needs a concrete size; paired with AutomaticSize.Y
-- it can settle at 0 height and stay invisible with no error at all.
-- Transparency is animated per element instead.
-- Exact wrapped height via TextService. Falls back to a rough estimate when
-- it is unavailable, so a card never collapses to nothing.
local NOTIFY_PAD_X = 12
local NOTIFY_PAD_Y = 10

local function measureText(text, size, font, maxWidth)
    if text == nil or text == "" then return 0 end
    local ok, bounds = pcall(function()
        return TextService:GetTextSize(text, size, font, Vector2.new(maxWidth, 100000))
    end)
    if ok and bounds and bounds.Y > 0 then
        return math.ceil(bounds.Y)
    end
    local perLine = math.max(1, math.floor(maxWidth / (size * 0.58)))
    return math.max(1, math.ceil(#text / perLine)) * math.ceil(size * 1.35)
end

function UI.Notify(cfg)
    if type(cfg) ~= "table" then
        cfg = { Text = tostring(cfg) }
    end

    notifyOrder = notifyOrder + 1

    local cardW    = M.notifyW or 220
    local textW    = cardW - NOTIFY_PAD_X * 2
    local titleStr = cfg.Title and tostring(cfg.Title) or nil
    local bodyStr  = tostring(cfg.Text or "")

    -- Height is measured up front instead of being left to AutomaticSize.
    -- A TextWrapped label inside an AutomaticSize container can be laid out
    -- against a 0-wide first frame; every character then wraps onto its own
    -- line and the card grows to several hundred pixels while looking empty.
    -- Measuring first makes the size deterministic.
    local titleH = titleStr and measureText(titleStr, Theme.textSize, Theme.fontMedium, textW) or 0
    local bodyH  = measureText(bodyStr, 11, Theme.font, textW)
    local gapH   = (titleStr and titleH > 0) and 3 or 0
    local cardH  = NOTIFY_PAD_Y * 2 + titleH + gapH + bodyH

    local card = new("Frame", {
        LayoutOrder = notifyOrder,
        Size = UDim2.fromOffset(cardW, cardH),
        BackgroundColor3 = Theme.win,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ZIndex = 801,
    }, notifyHolder)
    corner(card, 8)
    local edge = stroke(card, Theme.line)
    edge.Transparency = 1

    -- collected so fadeTo() can animate everything together
    local texts = {}

    if titleStr then
        texts[#texts + 1] = new("TextLabel", {
            Size = UDim2.fromOffset(textW, titleH),
            Position = UDim2.fromOffset(NOTIFY_PAD_X, NOTIFY_PAD_Y),
            BackgroundTransparency = 1,
            Text = titleStr,
            Font = Theme.fontMedium,
            TextSize = Theme.textSize,
            TextColor3 = Theme.text,
            TextTransparency = 1,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextYAlignment = Enum.TextYAlignment.Top,
            TextWrapped = true,
            ZIndex = 802,
        }, card)
    end

    if bodyStr ~= "" then
        texts[#texts + 1] = new("TextLabel", {
            Size = UDim2.fromOffset(textW, bodyH),
            Position = UDim2.fromOffset(NOTIFY_PAD_X, NOTIFY_PAD_Y + titleH + gapH),
            BackgroundTransparency = 1,
            Text = bodyStr,
            Font = Theme.font,
            TextSize = 11,
            TextColor3 = Theme.text2,
            TextTransparency = 1,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextYAlignment = Enum.TextYAlignment.Top,
            TextWrapped = true,
            ZIndex = 802,
        }, card)
    end

    local closed = false

    local function fadeTo(alpha, duration)
        tween(card, duration, { BackgroundTransparency = alpha })
        tween(edge, duration, { Transparency = alpha })
        for _, t in ipairs(texts) do
            tween(t, duration, { TextTransparency = alpha })
        end
    end

    local function close()
        if closed then return end
        closed = true
        fadeTo(1, 0.15)
        task.delay(0.16, function()
            card:Destroy()
        end)
    end

    fadeTo(0, 0.18)
    task.delay(cfg.Duration or 3, close)

    local hit = new("TextButton", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Text = "",
        AutoButtonColor = false,
        ZIndex = 850,
    }, card)
    hit.MouseButton1Click:Connect(close)

    return { Close = close }
end

--=====================================================================
--  Colour picker popup
--  12 preset swatches + three RGB bars, all firing the callback live.
--=====================================================================
local CP_PAD   = 10
local CP_W     = 200
local CP_SV    = CP_W - CP_PAD * 2   -- 180
local CP_SVH   = 132
local CP_BAR   = 12
local CP_SV_Y    = CP_PAD
local CP_HUE_Y   = CP_SV_Y + CP_SVH + 10
local CP_ALPHA_Y = CP_HUE_Y + CP_BAR + 8
local CP_PREV_Y  = CP_ALPHA_Y + CP_BAR + 10
local CP_H       = CP_PREV_Y + 16 + CP_PAD

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

local cpTarget, cpCallback, cpDrag = nil, nil, nil
local cpH, cpS, cpV, cpA = 0, 1, 1, 0
local cpLastHue = 0   -- keeping the hue across greys, otherwise picking a
                      -- grey collapses the hue back to red every time

--  Saturation / value square.
--  There is no built-in widget for this, so it is three stacked frames:
--    1. the pure hue as background
--    2. white, fading out to the right   -> saturation
--    3. black, fading out towards the top -> value
--  A GuiObject only accepts one UIGradient, hence the stacking.
local svBox = new("Frame", {
    Position = UDim2.fromOffset(CP_PAD, CP_PAD),
    Size = UDim2.fromOffset(CP_SV, CP_SVH),
    BackgroundColor3 = Color3.fromHSV(0, 1, 1),
    BorderSizePixel = 0,
    ClipsDescendants = true,
    ZIndex = 522,
}, colorPicker)
corner(svBox, 4)

local satLayer = new("Frame", {
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = Color3.new(1, 1, 1),
    BorderSizePixel = 0,
    ZIndex = 523,
}, svBox)
new("UIGradient", {
    Rotation = 0,
    Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0),
        NumberSequenceKeypoint.new(1, 1),
    }),
}, satLayer)

local valLayer = new("Frame", {
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = Color3.new(0, 0, 0),
    BorderSizePixel = 0,
    ZIndex = 524,
}, svBox)
new("UIGradient", {
    Rotation = 90,
    Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 1),
        NumberSequenceKeypoint.new(1, 0),
    }),
}, valLayer)

-- Knobs live on the popup, not inside the square/bars. Those containers clip
-- to their rounded corners, which would slice the knob in half at the edges.
local svKnob = new("Frame", {
    Size = UDim2.fromOffset(12, 12),
    AnchorPoint = Vector2.new(0.5, 0.5),
    BackgroundTransparency = 1,
    ZIndex = 530,
}, colorPicker)
stroke(svKnob, Color3.new(1, 1, 1), 2)

--  Hue bar
local hueBar = new("Frame", {
    Position = UDim2.fromOffset(CP_PAD, CP_HUE_Y),
    Size = UDim2.fromOffset(CP_SV, CP_BAR),
    BackgroundColor3 = Color3.new(1, 1, 1),
    BorderSizePixel = 0,
    ClipsDescendants = true,
    ZIndex = 522,
}, colorPicker)
corner(hueBar, 0.5)
new("UIGradient", {
    Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0.000, Color3.fromRGB(255,   0,   0)),
        ColorSequenceKeypoint.new(0.167, Color3.fromRGB(255, 255,   0)),
        ColorSequenceKeypoint.new(0.333, Color3.fromRGB(  0, 255,   0)),
        ColorSequenceKeypoint.new(0.500, Color3.fromRGB(  0, 255, 255)),
        ColorSequenceKeypoint.new(0.667, Color3.fromRGB(  0,   0, 255)),
        ColorSequenceKeypoint.new(0.833, Color3.fromRGB(255,   0, 255)),
        ColorSequenceKeypoint.new(1.000, Color3.fromRGB(255,   0,   0)),
    }),
}, hueBar)

local hueKnob = new("Frame", {
    Size = UDim2.fromOffset(5, CP_BAR + 6),
    AnchorPoint = Vector2.new(0.5, 0.5),
    BackgroundColor3 = Color3.new(1, 1, 1),
    BorderSizePixel = 0,
    ZIndex = 530,
}, colorPicker)
corner(hueKnob, 2)
stroke(hueKnob, Color3.fromRGB(120, 120, 128), 1)

--  Alpha bar: white underneath, current colour fading to transparent on top
local alphaBar = new("Frame", {
    Position = UDim2.fromOffset(CP_PAD, CP_ALPHA_Y),
    Size = UDim2.fromOffset(CP_SV, CP_BAR),
    BackgroundColor3 = Color3.new(1, 1, 1),
    BorderSizePixel = 0,
    ClipsDescendants = true,
    ZIndex = 522,
}, colorPicker)
corner(alphaBar, 0.5)

local alphaFill = new("Frame", {
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = Color3.fromHSV(0, 0, 0),
    BorderSizePixel = 0,
    ZIndex = 523,
}, alphaBar)
corner(alphaFill, 0.5)
new("UIGradient", {
    Rotation = 0,
    Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0),
        NumberSequenceKeypoint.new(1, 1),
    }),
}, alphaFill)

local alphaKnob = new("Frame", {
    Size = UDim2.fromOffset(5, CP_BAR + 6),
    AnchorPoint = Vector2.new(0.5, 0.5),
    BackgroundColor3 = Color3.new(1, 1, 1),
    BorderSizePixel = 0,
    ZIndex = 530,
}, colorPicker)
corner(alphaKnob, 2)
stroke(alphaKnob, Color3.fromRGB(120, 120, 128), 1)

--  Preview strip: opaque white base with the chosen colour on top
local cpPreview = new("Frame", {
    Position = UDim2.fromOffset(CP_PAD, CP_PREV_Y),
    Size = UDim2.fromOffset(CP_SV, 16),
    BackgroundColor3 = Color3.new(1, 1, 1),
    BorderSizePixel = 0,
    ClipsDescendants = true,
    ZIndex = 522,
}, colorPicker)
corner(cpPreview, 3)
stroke(cpPreview, Theme.line, 1)

local cpPreviewFill = new("Frame", {
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = Color3.fromHSV(0, 0, 0),
    BorderSizePixel = 0,
    ZIndex = 523,
}, cpPreview)
corner(cpPreviewFill, 3)

local function cpApply(fire)
    cpLastHue = cpH
    local c = Color3.fromHSV(cpH, cpS, cpV)

    svBox.BackgroundColor3      = Color3.fromHSV(cpH, 1, 1)
    alphaFill.BackgroundColor3  = c
    cpPreviewFill.BackgroundColor3    = c
    cpPreviewFill.BackgroundTransparency = cpA

    svKnob.Position = UDim2.fromOffset(
        CP_PAD + cpS * CP_SV,
        CP_SV_Y + (1 - cpV) * CP_SVH)
    hueKnob.Position = UDim2.fromOffset(
        CP_PAD + cpH * CP_SV,
        CP_HUE_Y + CP_BAR / 2)
    alphaKnob.Position = UDim2.fromOffset(
        CP_PAD + cpA * CP_SV,
        CP_ALPHA_Y + CP_BAR / 2)

    if cpTarget then
        cpTarget.BackgroundColor3        = c
        cpTarget.BackgroundTransparency  = cpA
    end

    if fire and cpCallback then
        local ok, err = pcall(cpCallback, c, cpA)
        if not ok then reportError("colorpicker", err) end
    end
end

-- Hit areas are taller than the bars so a thin 12px strip is still grabbable
local function hitArea(parent, height, yOff)
    local hit = new("TextButton", {
        Size = UDim2.new(1, 0, 0, height),
        Position = UDim2.fromOffset(0, yOff),
        BackgroundTransparency = 1,
        Text = "",
        AutoButtonColor = false,
        ZIndex = 535,
    }, parent)
    return hit
end

local function svUpdate(x, y)
    local abs, sz = svBox.AbsolutePosition, svBox.AbsoluteSize
    if sz.X <= 0 or sz.Y <= 0 then return end
    cpS = math.clamp((x - abs.X) / sz.X, 0, 1)
    cpV = 1 - math.clamp((y - abs.Y) / sz.Y, 0, 1)
    cpApply(true)
end

local function hueUpdate(x)
    local abs, w = hueBar.AbsolutePosition, hueBar.AbsoluteSize.X
    if w <= 0 then return end
    local h = math.clamp((x - abs.X) / w, 0, 1)
    -- 1.0 and 0.0 are the same hue, but the knob would jump back to the left
    if h >= 0.999 then h = 0.999 end
    cpH = h
    cpApply(true)
end

local function alphaUpdate(x)
    local abs, w = alphaBar.AbsolutePosition, alphaBar.AbsoluteSize.X
    if w <= 0 then return end
    cpA = math.clamp((x - abs.X) / w, 0, 1)
    cpApply(true)
end

local svHit = hitArea(svBox,    CP_SVH, 0)
local hueHit = hitArea(hueBar,  24, -6)
local alphaHit = hitArea(alphaBar, 24, -6)

local function bindDrag(hit, fn)
    hit.InputBegan:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1
           and input.UserInputType ~= Enum.UserInputType.Touch then return end
        cpDrag = fn
        fn(input.Position.X, input.Position.Y)
    end)
end

bindDrag(svHit, svUpdate)
bindDrag(hueHit, hueUpdate)
bindDrag(alphaHit, alphaUpdate)

UIS.InputChanged:Connect(function(input)
    if not cpDrag then return end
    if input.UserInputType == Enum.UserInputType.MouseMovement
       or input.UserInputType == Enum.UserInputType.Touch then
        cpDrag(input.Position.X, input.Position.Y)
    end
end)
UIS.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
       or input.UserInputType == Enum.UserInputType.Touch then
        cpDrag = nil
    end
end)

closeColorPicker = function()
    colorPicker.Visible = false
    veil.Visible = false
    cpTarget = nil
    cpCallback = nil
    cpDrag = nil
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

    local c = current or Color3.new(1, 1, 1)
    local h, s, v = c:ToHSV()
    -- pure greys have no meaningful hue; keep the previous one so the
    -- square does not snap to red while the user drags saturation
    cpH = (s > 0.001) and h or cpLastHue
    cpS = s
    cpV = v
    cpA = anchor.BackgroundTransparency or 0
    cpApply(false)
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
                if not ok then reportError("multiselect", err) end
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
    -- Max height in px before the body starts scrolling. nil / 0 = unlimited.
    -- A tab with 36 rows is ~1400px tall, which falls off a 1080p screen, so
    -- the shim opts in and only tall windows ever pay for the scroll plumbing.
    self.maxHeight = tonumber(cfg.MaxHeight) or 0
    self.scrollY   = 0

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

    -- Clip container for the body. Rows are parented to `content` below,
    -- which is what actually scrolls; `body` only clips.
    self.body = new("Frame", {
        Size = UDim2.new(1, 0, 1, -M.headH),
        Position = UDim2.fromOffset(0, M.headH),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ClipsDescendants = true,
    }, w)

    -- Scrolling layer. Always present (cost is one Frame) but only offset when
    -- the window has a MaxHeight and the content overflows.
    self.content = new("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        Position = UDim2.fromOffset(0, 0),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
    }, self.body)

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

    ---------------------------------------------------------------
    --  Wheel scrolling
    --  Only when the window actually overflows: otherwise every window in the
    --  library would swallow wheel events that belong to the game.
    ---------------------------------------------------------------
    self.conns[#self.conns + 1] = UIS.InputChanged:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseWheel then return end
        if self:GetMaxScroll() <= 0 then return end
        if self.collapsed or not w.Visible then return end

        -- Is the pointer over this window? AbsolutePosition is in screen space,
        -- the same space as input.Position on desktop.
        local p  = input.Position
        local ap = w.AbsolutePosition
        local sz = w.AbsoluteSize
        if p.X < ap.X or p.X > ap.X + sz.X then return end
        if p.Y < ap.Y or p.Y > ap.Y + sz.Y then return end

        -- input.Position.Z is the wheel delta: +1 up, -1 down.
        self:ScrollBy(-input.Position.Z * 48)
    end)
end

-----------------------------------------------------------------------
--  Height / collapse / scroll
-----------------------------------------------------------------------
function Window:GetHeight()
    if self.collapsed then return M.headH end
    local full = M.headH + self.cursor + M.bodyBot
    -- MaxHeight caps the visible window; the rest scrolls inside the body.
    if self.maxHeight and self.maxHeight > 0 and full > self.maxHeight then
        return self.maxHeight
    end
    return full
end

-- How far the content can be scrolled at most (0 when it fits).
function Window:GetMaxScroll()
    if self.collapsed then return 0 end
    if not (self.maxHeight and self.maxHeight > 0) then return 0 end
    local need = M.headH + self.cursor + M.bodyBot
    local over = need - self.maxHeight
    return over > 0 and over or 0
end

function Window:ScrollTo(y)
    local maxScroll = self:GetMaxScroll()
    if y < 0 then y = 0 end
    if y > maxScroll then y = maxScroll end
    if y == self.scrollY then return end
    self.scrollY = y
    self.content.Position = UDim2.fromOffset(0, -y)
end

function Window:ScrollBy(dy)
    self:ScrollTo(self.scrollY + dy)
end

function Window:ApplySize()
    self.height = self:GetHeight()
    self.frame.Size    = UDim2.fromOffset(M.winW, self.height)
    self.body.Visible  = not self.collapsed
    self.headLine.Visible = not self.collapsed

    -- Content keeps its natural height; the clipping body is what limits view.
    self.content.Size = UDim2.new(1, 0, 0, self.cursor + M.bodyBot)

    -- Content may have shrunk (rows removed) or the window may no longer
    -- overflow, so clamp the current offset instead of leaving a blank gap.
    local maxScroll = self:GetMaxScroll()
    if self.scrollY > maxScroll then
        self.scrollY = maxScroll
        self.content.Position = UDim2.fromOffset(0, -maxScroll)
    end
    self:UpdateScrollHint()
end

-- A 1px line on the right edge showing how far down the content is.
function Window:UpdateScrollHint()
    local maxScroll = self:GetMaxScroll()
    if not self.hint then
        if maxScroll <= 0 then return end
        self.hint = new("Frame", {
            Size = UDim2.new(0, 2, 0, 0),
            Position = UDim2.new(1, -3, 0, 0),
            BackgroundColor3 = Theme.accentDim,
            BackgroundTransparency = 0.35,
            BorderSizePixel = 0,
            ZIndex = 60,
        }, self.body)
    end
    if maxScroll <= 0 then
        self.hint.Visible = false
        return
    end
    self.hint.Visible = true
    local viewH   = math.max(self.height - M.headH, 1)
    local totalH  = viewH + maxScroll
    local barH    = math.max(viewH * (viewH / totalH), 18)
    local travel  = viewH - barH
    self.hint.Size = UDim2.new(0, 2, 0, barH)
    self.hint.Position = UDim2.new(
        1, -3, 0,
        travel * (self.scrollY / maxScroll)
    )
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
    }, self.content), y
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
            if not ok then reportError("toggle", err) end
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
            if not ok then reportError("slider", err) end
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
            if not ok then reportError("select", err) end
        end
    end

    btn.MouseButton1Click:Connect(function()
        openDropdown(btn, values, idx, pick)
    end)

    -- SetValues: replace the option list without firing the callback.
    -- Needed by dynamic lists (player names that come and go). Firing the
    -- callback here would make a handler think the user re-picked a value.
    return {
        Set = function(_, i) pick(values[i], i) end,
        Get = function() return values[idx], idx end,
        GetValues = function() return values end,
        SetValues = function(_, list)
            values = list or {}
            if values[idx] == nil then idx = 1 end
            label.Text = tostring(values[idx] or "")
        end,
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
            if not ok then reportError("button", err) end
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
            if not ok then reportError("keybind", err) end
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
        -- No AutoButtonColor here: that property only exists on GuiButton.
        -- Setting it on a TextBox throws "not a valid member" and aborts creation.
    }, row)
    corner(box, 5)
    new("UIPadding", { PaddingLeft = UDim.new(0, 7) }, box)

    local function fire(enterPressed)
        if cfg.Callback then
            local ok, err = pcall(cfg.Callback, box.Text, enterPressed)
            if not ok then reportError("input", err) end
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
    local alpha = cfg.Alpha or 0

    local swatch = new("TextButton", {
        Size = UDim2.fromOffset(38, 18),
        Position = UDim2.new(1, -50, 0.5, -9),
        BackgroundColor3 = color,
        BackgroundTransparency = alpha,
        BorderSizePixel = 0,
        Text = "",
        AutoButtonColor = false,
    }, row)
    corner(swatch, 4)
    stroke(swatch, Theme.line)

    -- The callback gets (colour, alpha). Existing code that only takes the
    -- first argument keeps working unchanged.
    swatch.MouseButton1Click:Connect(function()
        openColorPicker(swatch, color, function(c, a)
            color, alpha = c, a or 0
            if cfg.Callback then
                local ok, err = pcall(cfg.Callback, c, a)
                if not ok then reportError("colorpicker", err) end
            end
        end)
    end)

    return {
        Set = function(_, c, a)
            color = c
            alpha = a or 0
            swatch.BackgroundColor3 = c
            swatch.BackgroundTransparency = alpha
        end,
        Get = function() return color, alpha end,
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
                if not ok then reportError("multiselect", err) end
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

    -- Title and subtitle hang off a UIListLayout, ordered 1 and 2.
    -- Both have to be written: updating only the first leaves a stale subtitle.
    local box = self.head:FindFirstChildOfClass("Frame")
    if not box then return self end

    for _, o in ipairs(box:GetChildren()) do
        if o:IsA("TextLabel") then
            if o.LayoutOrder == 1 then
                o.Text = self.title
            elseif o.LayoutOrder == 2 and self.subtitle then
                o.Text = self.subtitle
            end
        end
    end
    return self
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
    if v then
        if autoUnlock then UI.SetMouseUnlocked(true) end
    else
        -- Always release on close. If auto-unlock was switched off while the
        -- menu was open, skipping this leaves the cursor unlocked forever.
        --
        -- rightHeld is cleared even when the unlock state is already false:
        -- RMB can be held while the menu is closed, and a leftover true value
        -- makes the next open's first write jump straight to LockCenter.
        rightHeld = false
        if mouseUnlocked then
            UI.SetMouseUnlocked(false)
        else
            -- Not marked unlocked, but the pointer may still be pinned (the
            -- exact bug this fixes). Make sure the close leaves a usable
            -- cursor instead of trusting our own bookkeeping.
            local b, i = UIS.MouseBehavior, UIS.MouseIconEnabled
            if b == Enum.MouseBehavior.LockCenter or i == false then
                UI.ForceRestoreMouse()
            end
        end
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
    -- ForceRestoreMouse afterwards is deliberate: SetMouseUnlocked(false) can be
    -- a no-op if the unlock flag was already cleared while the cursor was still
    -- pinned, and Destroy is the last chance to give the player a usable cursor.
    pcall(function() UI.SetMouseUnlocked(false) end)
    pcall(function() UI.ForceRestoreMouse() end)
    for _, win in ipairs(UI.Windows) do
        for _, c in ipairs(win.conns) do
            pcall(function() c:Disconnect() end)
        end
    end
    table.clear(UI.Windows)
    pcall(function() RunService:UnbindFromRenderStep(MOUSE_BIND) end)
    gui:Destroy()
    -- Notifications live in a second ScreenGui, so they need their own teardown
    pcall(function() notifyGui:Destroy() end)
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
