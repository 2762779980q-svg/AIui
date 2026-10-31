# AIgui

A single-file, dependency-free floating window library for Roblox — native look, waterfall layout.

Written in pure `Instance` code. White panels, grey-scale text, 1px outlines. Windows arrange themselves into columns, and can be dragged, collapsed and closed individually.

```
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│ ● General    │  │ ● Input      │  │ ● About      │
│ ──────────── │  │ ──────────── │  │ ──────────── │
│ Enable   (o) │  │ Hotkey    [F]│  │ text text    │
│ Value   ──●─ │  │ Name   [    ]│  │ text text    │
│ ───────────  │  │ ──────────── │  │ ──────────── │
│ Single  [A▾] │  │ [  Apply   ] │  │ [  Notify  ] │
└──────────────┘  └──────────────┘  └──────────────┘
```

---

## Features

- **Single file** — the whole library is one `.lua`, no other UI library required, one line to load
- **Waterfall layout** — windows fill the shortest column first; column count adapts to resolution (around 7 columns at 1920px, a single column on narrow screens)
- **Independent windows** — each window drags, collapses and closes on its own; a window you dragged stops taking part in auto layout
- **11 widgets** — Toggle, Slider, Select, MultiSelect, ColorPicker, Input, Keybind, Button, Label, Paragraph, Divider
- **Popup system** — dropdown, multi-select and colour picker share one veil; click anywhere to dismiss
- **Notifications** — stacked in the top-right, fade out automatically
- **Overridable theme** — colours, fonts, text sizes and window metrics are all exposed
- **Mouse management** — the cursor unlocks while the menu is open and the original state is restored on close
- **gethui mounting** — prefers `gethui()`, and re-parents itself if the container is cleared

---

## Installation

### Raw load (recommended)

```lua
local AIgui = assert(loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/2762779980q-svg/AIui/main/AIgui.lua"
)))()
```

### Local file

Drop `AIgui.lua` into your executor's workspace folder:

```lua
local AIgui = assert(loadstring(readfile("AIgui.lua")))()
```

---

## Quick start

```lua
local AIgui = assert(loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/2762779980q-svg/AIui/main/AIgui.lua"
)))()
```

```lua
local w = AIgui.Window({ Title = "Settings", Subtitle = "CONFIG" })

w:Toggle {
    Text = "Enable",
    Default = true,
    Callback = function(value)
        print("toggle:", value)
    end,
}

w:Slider {
    Text = "Speed",
    Min = 0, Max = 100, Default = 50,
    Callback = function(value) print("slider:", value) end,
}

w:Divider()

w:Select {
    Text = "Mode",
    Values = { "Fast", "Normal", "Safe" },
    Default = 2,
    Callback = function(text, index) print(text, index) end,
}

AIgui.Notify { Title = "AIgui", Text = "Loaded", Duration = 3 }
```

Press `INSERT` to toggle the menu.

---

## API

### `AIgui.Window(cfg)`

Creates a floating window and returns a window object.

| Field | Type | Default | Description |
|---|---|---|---|
| `Title` | string | `"Window"` | Window title |
| `Subtitle` | string | `""` | Small text next to the title |
| `StartPos` | UDim2 | auto | Fixed initial position; excludes the window from auto layout |
| `Closable` | boolean | `true` | Show the close button |
| `Collapsible` | boolean | `true` | Show the collapse button |

### Widgets

Every widget takes a table and returns a `{ Set, Get }` object — use it as `obj:Set(value)` and `obj:Get()`.

#### `w:Toggle{ Text, Default, Callback }`

On/off switch. `Callback(value: boolean)`. Clicking anywhere on the row toggles it.

#### `w:Slider{ Text, Min, Max, Default, Rounding, Suffix, Callback }`

Value slider. `Rounding` is the number of decimal places (0 by default), `Suffix` is appended to the displayed value (e.g. `"%"`).

#### `w:Select{ Text, Values, Default, Callback }`

Single-choice dropdown. `Default` is an index. `Callback(text, index)`.

#### `w:MultiSelect{ Text, Values, Default, Callback }`

Multi-choice dropdown. `Default = { 1, 3 }` pre-selects items 1 and 3. `Callback(text, index, isOn)`.
Clicking an item does not close the popup; click outside to dismiss. `Get()` returns an array of the selected strings.

#### `w:ColorPicker{ Text, Default, Callback }`

Colour picker. `Default` is a `Color3`. Clicking the swatch opens 12 presets plus three RGB bars, firing the callback live.

#### `w:Input{ Text, Default, Placeholder, Callback }`

Single-line text box. `Callback(text, enterPressed)`.

#### `w:Keybind{ Text, Default, Callback }`

Key binding. Click to start listening, then press any key. `Callback(keyCode: Enum.KeyCode)`.

#### `w:Button{ Text, Callback }`

Plain button.

#### `w:Label(text)`

Group caption in small grey text.

#### `w:Paragraph(text, lines)`

Multi-line description. `lines` is the reserved height in lines (2 by default).

#### `w:Divider()`

A horizontal separator.

### Window methods

| Method | Description |
|---|---|
| `w:Open()` | Show the window |
| `w:Close()` | Hide the window |
| `w:SetCollapsed(bool)` | Collapse or expand |
| `w:SetTitle(text, subtitle)` | Change the title |
| `w:Destroy()` | Destroy this window (the menu closes automatically when the last one goes) |

### Global

| Method | Description |
|---|---|
| `AIgui.Notify{ Title, Text, Duration }` | Top-right notification, returns `{ Close = fn }` |
| `AIgui.SetTheme(tbl)` | Override the theme — **must be called before creating widgets** |
| `AIgui.Configure(tbl)` | Override metrics — also before creating windows |
| `AIgui.SetMenuOpen(bool)` | Visibility + input blocker + mouse lock, all at once |
| `AIgui.ToggleMenu()` | Same, inverted |
| `AIgui.SetKey(Enum.KeyCode)` | Change the menu key, default `Insert` |
| `AIgui.SetAutoUnlockMouse(bool)` | Unlock the cursor while open, default `true` |
| `AIgui.SetUnlockPriority(number)` | Render priority used for unlocking, default `Last + 1` |
| `AIgui.SetMouseUnlocked(bool)` | Control the mouse lock manually |
| `AIgui.IsMouseUnlocked()` | Query the current mouse state |
| `AIgui.Arrange()` | Drop manual placements and re-run the waterfall layout |
| `AIgui.ShowAll()` | Bring back every closed window |
| `AIgui.Relayout()` | Force an immediate relayout |
| `AIgui.Destroy()` | Disconnect everything and destroy the whole UI |
| `AIgui.Demo()` | Build a set of demo windows |

### Properties

| Property | Description |
|---|---|
| `AIgui.Gui` | The underlying `ScreenGui` |
| `AIgui.Windows` | Array of all current windows |
| `AIgui.Theme` | Theme table (editing it directly works, but only affects later widgets) |
| `AIgui.Metrics` | Metrics table |

---

## Theme

```lua
AIgui.SetTheme({
    win       = Color3.fromRGB(255, 255, 255),  -- window background
    line      = Color3.fromRGB(228, 228, 233),  -- outline
    lineHover = Color3.fromRGB(217, 217, 223),  -- outline on hover
    lineSoft  = Color3.fromRGB(240, 240, 243),  -- separator

    text      = Color3.fromRGB( 58,  58,  62),
    text2     = Color3.fromRGB(138, 138, 145),
    text3     = Color3.fromRGB(179, 179, 186),

    ctrl      = Color3.fromRGB(237, 237, 241),
    ctrlHover = Color3.fromRGB(230, 230, 235),
    accent    = Color3.fromRGB( 74,  74,  80),  -- toggled state / checkmarks
    accentDim = Color3.fromRGB(112, 112, 122),  -- slider fill

    knob      = Color3.fromRGB(255, 255, 255),
    knobEdge  = Color3.fromRGB(196, 196, 204),

    font       = Enum.Font.Gotham,
    fontMedium = Enum.Font.GothamMedium,
    textSize   = 12,
    textSizeSm = 10,
})
```

### Metrics

```lua
AIgui.Configure({
    winW    = 238,   -- window width
    gap     = 12,    -- spacing between windows
    pad     = 20,    -- screen padding
    headH   = 32,    -- title bar height
    rowH    = 28,    -- standard row height
    sliderH = 46,    -- slider row height
    radius  = 8,     -- window corner radius
})
```

---

## Notes

**Set the theme and metrics before creating widgets.** Existing widgets are not updated retroactively — their properties are written at creation time. To re-skin, `Destroy()` and rebuild.

**Mouse unlocking binds at `RenderPriority.Last + 1`.** This is required to override game camera controllers that write `MouseBehavior = LockCenter` every frame. If your game's camera runs at a later priority, raise it with `AIgui.SetUnlockPriority(n)`.

**The input blocker is a `TextButton`, not `Modal`.** It only swallows clicks at the GUI layer. If a game reads `UserInputService.InputBegan` directly without checking `gameProcessed`, the blocker will not stop it — handle that case in your own code.

**Loading without creating a window touches nothing.** The full-screen blocker eats every click when visible, so it only activates once the first window exists.

---

## Project structure

```
AIgui/
├── AIgui.lua       # the library, single file
├── example.lua     # complete example
├── README.md
└── LICENSE
```

---

## License

MIT
