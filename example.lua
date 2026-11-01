--[[
    example.lua — complete AIgui example

    Running this file builds three windows that demonstrate every widget.
    To turn it into your own menu, change the Config table and the callbacks.
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
--=====================================================================
local AIgui
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
        -- Print every reason: with one URL you never learn why it failed.
        warn("[AIgui] all mirrors failed, using stub. The menu will not appear.")
        for _, e in ipairs(errors) do warn("  " .. e) end

        -- Minimal stub so the rest of this file still runs. Every method is a
        -- no-op that returns a widget-like table, so chained calls do not throw
        -- and you see exactly one clear warning instead of a nil-index stack.
        local function stubWidget()
            local w = {}
            local function noop() return w end
            w.Toggle = noop   w.Slider = noop   w.Button = noop
            w.Label  = noop   w.Divider = noop  w.Select = noop
            w.MultiSelect = noop  w.ColorPicker = noop
            w.Input  = noop   w.Keybind = noop  w.Paragraph = noop
            w.SetTitle = noop w.Open = noop     w.Close = noop
            w.Destroy = noop
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
            LastError = "AIgui failed to load",
        }
    end
end

--=====================================================================
--  Theme (optional, must run before any widget is created)
--  The default is already white / grey; this only shows how to change it.
--=====================================================================
-- AIgui.SetTheme({
--     accent   = Color3.fromRGB(46, 46, 52),   -- darker toggled state
--     line     = Color3.fromRGB(222, 222, 228),
--     textSize = 13,
-- })

--=====================================================================
--  Config: keep every tunable in one place
--=====================================================================
local Config = {
    enabled  = true,
    speed    = 50,
    mode     = "Normal",
    features = { "Feature A", "Feature C" },
    color    = Color3.fromRGB(92, 148, 255),
    hotkey   = "F",
    name     = "",
}

--=====================================================================
--  Window 1: main switch and values
--=====================================================================
local main = AIgui.Window({ Title = "Main", Subtitle = "GENERAL" })

main:Toggle {
    Text = "Enable",
    Default = Config.enabled,
    Callback = function(v)
        Config.enabled = v
        print("[Main] enabled =", v)
    end,
}

main:Slider {
    Text = "Speed",
    Min = 0, Max = 100, Default = Config.speed,
    Callback = function(v)
        Config.speed = v
    end,
}

main:Divider()

main:Select {
    Text = "Mode",
    Values = { "Fast", "Normal", "Safe" },
    Default = 2,
    Callback = function(text, index)
        Config.mode = text
        print("[Main] mode =", text, index)
    end,
}

main:Button {
    Text = "Reset",
    Callback = function()
        Config.speed = 50
        print("[Main] reset")
        AIgui.Notify { Title = "Main", Text = "Reset to defaults.", Duration = 2 }
    end,
}

--=====================================================================
--  Window 2: multi-select and colour
--=====================================================================
local appearance = AIgui.Window({ Title = "Appearance", Subtitle = "VISUAL" })

appearance:Label("Features")

appearance:MultiSelect {
    Text = "Enabled",
    Values = { "Feature A", "Feature B", "Feature C", "Feature D" },
    Default = { 1, 3 },
    Callback = function(text, index, isOn)
        print("[Appearance]", text, isOn and "on" or "off")
    end,
}

appearance:ColorPicker {
    Text = "Highlight",
    Default = Config.color,
    Callback = function(c)
        Config.color = c
        print("[Appearance] color", c)
    end,
}

appearance:Divider()

appearance:Paragraph(
    "Paragraph holds descriptive text. The second argument sets the reserved " ..
    "height in lines and defaults to 2.",
    3
)

--=====================================================================
--  Window 3: input
--=====================================================================
local input = AIgui.Window({ Title = "Input", Subtitle = "INPUT" })

input:Keybind {
    Text = "Hotkey",
    Default = Config.hotkey,
    Callback = function(key)
        Config.hotkey = key.Name
        print("[Input] hotkey =", key.Name)
    end,
}

input:Input {
    Text = "Name",
    Default = Config.name,
    Placeholder = "type here",
    Callback = function(text, entered)
        Config.name = text
        print("[Input] name =", text, "entered =", entered)
    end,
}

input:Divider()

input:Button {
    Text = "Save",
    Callback = function()
        AIgui.Notify {
            Title = "Saved",
            Text = string.format("mode=%s  speed=%d", Config.mode, Config.speed),
            Duration = 3,
        }
    end,
}

input:Button {
    Text = "Destroy UI",
    Callback = function()
        -- Destroys every window and disconnects all events. The script keeps
        -- running, but UI is now dead: creating another window afterwards
        -- indexes a torn-down table. Say so instead of throwing.
        AIgui.Destroy()
        warn("[AIgui] UI destroyed. Re-execute this script to build it again.")
    end,
}

--=====================================================================
--  Startup notification
--=====================================================================
AIgui.Notify {
    Title = "AIgui",
    Text = "Press INSERT to toggle the menu.",
    Duration = 4,
}
