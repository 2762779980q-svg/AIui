--[[
    example.lua — complete AIgui example

    Running this file builds three windows that demonstrate every widget.
    To turn it into your own menu, change the Config table and the callbacks.
]]

--=====================================================================
--  Load
--=====================================================================
local AIgui = assert(loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/2762779980q-svg/AIui/main/AIgui.lua"
)))()

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
        -- Destroys every window and disconnects all events; the script keeps running
        AIgui.Destroy()
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
