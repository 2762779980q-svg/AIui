--[[
    example.lua — AIgui reference menu

    This is deliberately NOT a "three tiny windows" demo. Real ports break in
    three places that a 3-row example never reaches, so this file stresses all
    three on purpose:

      1. CREATION MUST NOT FIRE CALLBACKS
         In a real menu a toggle callback does something (writes a global,
         hooks a remote, starts a loop). If creating the widget fired it, then
         98 toggles would run their side effects in creation order and the last
         one would win. AIgui never calls Callback on create, and widget:Set()
         is silent too - only a real click fires it. The Porting window below
         asserts this at runtime.

      2. LONG WINDOWS RUN OFF SCREEN
         A window with 30 rows is ~900px tall plus header; 1080p gives about
         1000px and the taskbar eats more. So Window auto-caps itself at 78% of
         the viewport and scrolls the body with the mouse wheel. You do not
         have to pass anything - but you can:
             AIgui.Window{ Title = "X" }                  -- auto (78%)
             AIgui.Window{ Title = "X", MaxHeight = 420 } -- exact cap
             AIgui.Window{ Title = "X", MaxHeight = 0 }   -- unlimited, opt out

      3. NO TAB -> GROUPBOX -> CONTROL HIERARCHY
         The layout is a flat waterfall, so the middle level is rebuilt with
         Window:Group. Groups draw a captioned box behind a run of controls and
         indent them. Left/right groupbox calls interleave freely in the source
         - a waterfall has one column, so they simply append in call order.
]]

--=====================================================================
--  Load
--
--  Multiple mirrors, and the result is validated before use. A single
--  `assert(loadstring(...))()` looks safe but has three failure modes that all
--  end in "attempt to index nil with 'Window'" further down:
--    1. the HTTP request returns an error page instead of Lua source
--    2. the chunk raises while running (assert only catches loadstring
--       returning nil, not an error inside the chunk)
--    3. the mirror serves an old build whose table has no Window method
--  So: try every mirror, run the chunk under pcall, and require .Window to
--  actually be a function before accepting the result.
--
--  Nothing is printed. If loading fails you get a stub (no crash, no menu) and
--  LoadReport below holds every mirror's failure reason - read it when needed.
--=====================================================================
local AIgui
local LoadReport = nil
do
    local MIRRORS = {
        "https://raw.githubusercontent.com/2762779980q-svg/AIui/main/AIgui.lua",
        "https://github.com/2762779980q-svg/AIui/raw/main/AIgui.lua",
        "https://cdn.jsdelivr.net/gh/2762779980q-svg/AIui@main/AIgui.lua",
    }

    local errors = {}

    for _, url in ipairs(MIRRORS) do
        local ok, result = pcall(function()
            local src = game:HttpGet(url)
            -- An error page is valid Lua enough to be confusing; check the size
            -- and that it looks like the library before compiling it.
            if type(src) ~= "string" or #src < 1000 then
                error("response too small (" .. tostring(src and #src) .. " bytes)")
            end
            if not src:find("function UI.Window", 1, true)
               and not src:find("return UI", 1, true) then
                error("response does not look like AIgui source")
            end
            local chunk = loadstring(src)
            if not chunk then error("loadstring failed") end
            return chunk()
        end)

        if ok and type(result) == "table" and type(result.Window) == "function" then
            AIgui = result
            break
        end

        errors[#errors + 1] = ("%s -> %s"):format(url, tostring(result))
    end

    if not AIgui then
        -- Silent by default. Every failure reason is collected into a string so
        -- you can inspect it on demand instead of reading the console:
        --     warn(LoadReport)
        LoadReport = "[AIgui] all mirrors failed:\n" .. table.concat(errors, "\n")

        -- Minimal stub so the rest of this file still runs. Every method is a
        -- no-op that returns a widget-like table, so chained calls do not throw
        -- and you get one predictable state instead of a nil-index stack.
        local function stubWidget()
            local w = {}
            local function noop() return w end
            w.Toggle = noop   w.Slider = noop   w.Button = noop
            w.Label  = noop   w.Divider = noop  w.Select = noop
            w.MultiSelect = noop  w.ColorPicker = noop
            w.Input  = noop   w.Keybind = noop  w.Paragraph = noop
            w.Group  = noop   w.SetTitle = noop w.Open = noop
            w.Close  = noop   w.Destroy = noop  w.SetCollapsed = noop
            w.GetHeight = function() return 0 end
            w.GetMaxScroll = function() return 0 end
            return w
        end

        AIgui = {
            Window  = function() return stubWidget() end,
            Notify  = function() end,
            Destroy = function() end,
            Demo    = function() end,
            SetTheme = function() end,
            SetKey  = function() end,
            SetMenuOpen = function() end,
            ToggleMenu  = function() end,
            SetAutoUnlockMouse = function() end,
            SetRightHoldLook   = function() end,
            IsMouseUnlocked    = function() return false end,
            GetMouseState      = function() return {} end,
            ForceRestoreMouse  = function() end,
            ShowAll            = function() end,
            RestoreWindows     = function() return 0 end,
            CountVisible       = function() return 0 end,
            LastError = "AIgui failed to load",
        }
    end
end

--=====================================================================
--  Theme (optional, must run before any widget is created)
--=====================================================================
-- AIgui.SetTheme({
--     accent   = Color3.fromRGB(46, 46, 52),
--     line     = Color3.fromRGB(222, 222, 228),
--     textSize = 13,
-- })

--=====================================================================
--  Shared state + callback counter
--
--  Every callback in this file goes through cb(). It increments `fired` before
--  doing anything else, so the Porting window can prove creation did not fire
--  a single one.
--=====================================================================
local S = {
    aimOn = false, aimFov = 90, aimPart = 1, smooth = 35,
    trigOn = false, trigDelay = 40, trigMode = "Hold",
    espOn = false, espDist = 500, traceOn = false,
    speedOn = false, speed = 16, flyOn = false,
    color = Color3.fromRGB(92, 148, 255),
    hotkey = "F",
}

local fired = 0

local function cb(fn)
    return function(...)
        fired = fired + 1
        if fn then fn(...) end
    end
end

local windows = {}
local function W(cfg)
    local w = AIgui.Window(cfg)
    windows[#windows + 1] = w
    return w
end

--=====================================================================
--  Group fallback
--
--  Window:Group is new. If the build pulled from GitHub is older than this
--  file, calling w:Group{...} throws "attempt to call missing method 'Group'".
--  G() returns a real group when the library has one, and otherwise a stand-in
--  that renders a plain caption and forwards every widget call to the window.
--  So the demo runs on both builds; on the old one you just lose the box.
--=====================================================================
local FORWARD = {
    "Toggle", "Slider", "Select", "MultiSelect", "ColorPicker",
    "Input", "Keybind", "Button", "Divider", "Label", "Paragraph",
}

-- Set when the loaded build had no Group, so the startup notification can say
-- "you are on an old build" instead of leaving you to notice the missing boxes.
local usedFallback = false

local function G(w, text)
    if type(w.Group) == "function" then
        return w:Group { Text = text }
    end

    usedFallback = true
    local g = {}

    local function pass(name)
        return function(a, ...)
            -- Colon call passes the group first; a dot call passes the config.
            if a == g then return w[name](w, ...) end
            return w[name](w, a, ...)
        end
    end

    for _, name in ipairs(FORWARD) do
        g[name] = pass(name)
    end
    function g:Done() end

    if type(w.Label) == "function" then w:Label(text) end
    return g
end

--=====================================================================
--  Window 1: Aim — three groups, the way a real combat tab is shaped
--=====================================================================
local aim = W { Title = "Aim", Subtitle = "COMBAT" }

local gAim = G(aim, "AIM")
-- Kept around for the self-check window: it proves widget:Set() is silent.
local tgAim = gAim:Toggle {
    Text = "Silent aim",
    Default = S.aimOn,
    Callback = cb(function(v) S.aimOn = v end),
}
gAim:Select {
    Text = "Hit part",
    Values = { "Head", "Chest", "Nearest" },
    Default = S.aimPart,
    Callback = cb(function(_, i) S.aimPart = i end),
}
gAim:Slider {
    Text = "FOV",
    Min = 10, Max = 360, Default = S.aimFov, Suffix = "°",
    Callback = cb(function(v) S.aimFov = v end),
}
gAim:Slider {
    Text = "Smoothing",
    Min = 1, Max = 100, Default = S.smooth, Suffix = "%",
    Callback = cb(function(v) S.smooth = v end),
}
gAim:Done()

-- Second group. In an Obsidian-style menu this would be AddRightGroupbox -
-- waterfall has one column, so it just continues below.
local gPre = G(aim, "PREDICTION")
gPre:Toggle {
    Text = "Velocity prediction",
    Default = true,
    Callback = cb(function(v) S.predict = v end),
}
gPre:Slider {
    Text = "Lead time",
    Min = 0, Max = 400, Default = 120, Suffix = " ms",
    Callback = cb(function(v) S.lead = v / 1000 end),
}
gPre:Label("Lead time is applied along the target's linear velocity.")
gPre:Done()

--=====================================================================
--  Window 2: Trigger
--=====================================================================
local trig = W { Title = "Trigger", Subtitle = "COMBAT" }

local gTrig = G(trig, "TRIGGER")
gTrig:Toggle {
    Text = "Enable",
    Default = S.trigOn,
    Callback = cb(function(v) S.trigOn = v end),
}
gTrig:Slider {
    Text = "Delay",
    Min = 0, Max = 300, Default = S.trigDelay, Suffix = " ms",
    Callback = cb(function(v) S.trigDelay = v end),
}
gTrig:Select {
    Text = "Mode",
    Values = { "Hold", "Toggle", "Always" },
    Default = 1,
    Callback = cb(function(t) S.trigMode = t end),
}
gTrig:Done()

trig:Paragraph(
    "Paragraph reserves space for descriptive text. Second argument = lines.",
    2
)

--=====================================================================
--  Window 3: Visuals — the interleaved left/right case
--
--  Source order here is group, group, group, which is what you get when a
--  menu calls AddLeftGroupbox / AddRightGroupbox alternately. Order is kept;
--  the boxes just stack.
--=====================================================================
local vis = W { Title = "Visuals", Subtitle = "RENDER" }

local gPlayers = G(vis, "PLAYERS")
gPlayers:Toggle {
    Text = "Box",
    Default = S.espOn,
    Callback = cb(function(v) S.espOn = v end),
}
gPlayers:Toggle {
    Text = "Tracer",
    Default = S.traceOn,
    Callback = cb(function(v) S.traceOn = v end),
}
gPlayers:Slider {
    Text = "Max distance",
    Min = 50, Max = 2000, Default = S.espDist, Suffix = "m",
    Callback = cb(function(v) S.espDist = v end),
}
gPlayers:ColorPicker {
    Text = "Colour",
    Default = S.color,
    Callback = cb(function(c) S.color = c end),
}
gPlayers:Done()

local gWorld = G(vis, "WORLD")
gWorld:Button {
    Text = "Clear decals",
    Callback = cb(function() end),
}
gWorld:Button {
    Text = "Reset colours",
    Callback = cb(function() S.color = Color3.fromRGB(92, 148, 255) end),
}
gWorld:Done()

--=====================================================================
--  Window 4: Movement
--=====================================================================
local move = W { Title = "Movement", Subtitle = "MISC" }

local gMove = G(move, "MOVE")
gMove:Toggle {
    Text = "Speed",
    Default = S.speedOn,
    Callback = cb(function(v) S.speedOn = v end),
}
gMove:Slider {
    Text = "Walk speed",
    Min = 8, Max = 60, Default = S.speed,
    Callback = cb(function(v) S.speed = v end),
}
gMove:Toggle {
    Text = "Fly",
    Default = S.flyOn,
    Callback = cb(function(v) S.flyOn = v end),
}
-- Mode = nil keeps this a pure picker: Callback receives the key itself, and
-- the script decides what pressing it does (that is what 快说快说-style menus
-- need, since they run their own dispatcher).
gMove:Keybind {
    Text = "Fly key",
    Default = S.hotkey,
    Callback = cb(function(k) S.hotkey = k.Name end),
}

-- With a Mode the widget is a working keybind: the library watches the key and
-- drives the callback for you.
--   "Toggle" -> press flips, Callback(state)
--   "Hold"   -> active while held, Callback(true) / Callback(false)
--   "Always" -> Callback(true) on every press
gMove:Keybind {
    Text = "Aim (toggle)",
    Default = "C",
    Mode = "Toggle",
    Callback = cb(function(on)
        S.aimOn = on
        tgAim:Set(on)          -- keep the Aim window's switch honest
    end),
    ChangedCallback = function(k) S.aimKey = k.Name end,
}
gMove:Keybind {
    Text = "Sprint (hold)",
    Default = "LeftShift",
    Mode = "Hold",
    Callback = cb(function(on) S.sprint = on end),
}
gMove:Done()

--=====================================================================
--  Window 5: STRESS — 32 rows in one window
--
--  This is the one a 3-row example never covers. Without the automatic cap it
--  would be ~950px and hang off the bottom of a 1080p screen. Now the body
--  scrolls and a thin bar on the right edge shows the position.
--=====================================================================
local stress = W { Title = "Stress", Subtitle = "32 ROWS" }

local flags = {}
for i = 1, 30 do
    flags[i] = false
    stress:Toggle {
        Text = ("Flag %02d"):format(i),
        Default = false,
        Callback = cb(function(v) flags[i] = v end),
    }
end
stress:Divider()
stress:Paragraph(
    "Thirty rows plus a divider. Scroll the wheel over this window - if the " ..
    "height cap were missing this whole block would be below the screen edge.",
    3
)

--=====================================================================
--  Window 6: Porting notes + runtime self-check
--=====================================================================
local port = W { Title = "Porting", Subtitle = "NOTES" }

local firedAtBuild = fired   -- must be 0: nothing may run on create

local gCheck = G(port, "SELF-CHECK")
gCheck:Button {
    Text = "Run checks",
    Callback = function()
        local lines = {}

        lines[#lines + 1] = ("callbacks fired during creation: %d %s")
            :format(firedAtBuild, firedAtBuild == 0 and "(ok)" or "(BUG)")

        -- Set() must be silent: flip a real widget programmatically and re-read
        -- the counter. A toggle whose Set() fired its callback would double-run
        -- every side effect the moment a config loader touched it.
        local before = fired
        local v = tgAim:Get()
        tgAim:Set(not v)
        tgAim:Set(v)
        local delta = fired - before
        lines[#lines + 1] = ("callbacks fired by Set(): %d %s")
            :format(delta, delta == 0 and "(ok)" or "(BUG)")

        -- Height cap: window height must never exceed its own cap.
        local tallest, over = 0, 0
        for _, w in ipairs(windows) do
            local h = type(w.GetHeight) == "function" and w:GetHeight() or 0
            if h > tallest then tallest = h end
            if h > 800 then over = over + 1 end
        end
        lines[#lines + 1] = ("tallest window: %d px, over 800px: %d")
            :format(tallest, over)
        lines[#lines + 1] = ("scrollable: %d window(s)")
            :format((function()
                local n = 0
                for _, w in ipairs(windows) do
                    if type(w.GetMaxScroll) == "function" and w:GetMaxScroll() > 0 then
                        n = n + 1
                    end
                end
                return n
            end)())

        AIgui.Notify {
            Title = "Self-check",
            Text = table.concat(lines, "\n"),
            Duration = 8,
        }
    end,
}
gCheck:Done()

port:Paragraph(
    "Go back to the Stress window and scroll it. Then run the check: creation " ..
    "must report 0 callbacks, and Stress must report a non-zero scroll range.",
    3
)

port:Input {
    Text = "Name",
    Default = "",
    Placeholder = "type here",
    Callback = function(text, entered)
        -- Fires when the box loses focus (entered = true when Enter was hit).
        -- Not per keystroke, so a cheap side effect here is fine.
    end,
}

port:Divider()

-- Closing a window is reversible: the window keeps its widgets and values.
-- These two buttons show the round trip without touching the X.
port:Button {
    Text = "Close the Visuals window",
    Callback = function()
        vis:Close()
        AIgui.Notify {
            Title = "Close",
            Text = "Visuals is hidden. Ctrl + INSERT brings it back.",
            Duration = 4,
        }
    end,
}

port:Button {
    Text = "Restore closed windows",
    Callback = function()
        local n = 0
        if type(AIgui.RestoreWindows) == "function" then
            n = AIgui.RestoreWindows()
        end
        AIgui.Notify {
            Title = "Restore",
            Text = ("%d window(s) came back"):format(n),
            Duration = 3,
        }
    end,
}

port:Button {
    Text = "Destroy UI",
    Callback = function()
        -- Destroys every window and disconnects all events. The script keeps
        -- running but the UI is dead: do not build more windows after this.
        -- Unlike the X, this one cannot be undone without re-executing.
        AIgui.Destroy()
    end,
}

--=====================================================================
--  Startup
--=====================================================================
AIgui.Notify {
    Title = "AIgui",
    Text = usedFallback
        and ("INSERT toggles the menu. Loaded build has no Group() - boxes are "
             .. "flat. Push AIgui.lua to GitHub to get them.")
        or "INSERT toggles the menu. Ctrl + INSERT restores closed windows.",
    Duration = usedFallback and 8 or 5,
}
