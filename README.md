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
- **Groups** — `w:Group{ Text = "AIM" }` rebuilds the Tab → Groupbox → control hierarchy a flat window does not have
- **Auto height cap** — a window taller than 78% of the screen scrolls its body instead of running off the bottom
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
| `MaxHeight` | number | auto | Cap in px before the body scrolls. `nil` = 78% of the viewport, `0` = unlimited |

`MaxHeight` defaults to 78% of the viewport height, so a window with 30+ rows can never run off the bottom of the screen — it scrolls instead (mouse wheel over the window, thin bar on the right edge shows the position). Pass `MaxHeight = 0` to opt out, or a number for an exact cap.

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

#### `w:ColorPicker{ Text, Default, Alpha, Callback }`

Colour picker. `Default` is a `Color3`, `Alpha` is an optional `0`–`1` transparency. Clicking the swatch opens:

- a saturation / value square (drag anywhere inside)
- a hue bar
- an alpha bar
- a preview strip showing the colour over white

The callback fires live while dragging and receives `(colour, alpha)`. Code that only takes the first argument keeps working.

```lua
w:ColorPicker {
    Text = "ESP colour",
    Default = Color3.fromRGB(112, 216, 255),
    Callback = function(c, a) CFG.Color = c; CFG.Alpha = a end,
}
```

#### `w:Input{ Text, Default, Placeholder, Callback }`

Single-line text box. `Callback(text, enterPressed)`.

#### `w:Keybind{ Text, Default, Mode, Callback, ChangedCallback }`

Click the box to start listening, then press any key. Clicking anywhere else cancels the capture instead of leaving the box armed.

| Field | Description |
|---|---|
| `Default` | `"F"` or an `Enum.KeyCode` |
| `Mode` | `nil` = pure picker (you read the key and act on it). `"Toggle"` / `"Hold"` / `"Always"` = the library watches the key and drives `Callback` for you |
| `Callback` | picker: `Callback(keyCode)` when the key changes. With a `Mode`: `Callback(state: boolean)` — flipped value for Toggle, `true`/`false` for Hold, `true` per press for Always |
| `ChangedCallback` | `ChangedCallback(keyCode)` whenever the bound key changes |

Returns `{ Set(key), Get() -> keyCode, GetState() -> boolean }`.

```lua
gb:Keybind { Text = "Aim", Default = "C", Mode = "Toggle",
             Callback = function(on) aim(on) end }
gb:Keybind { Text = "Sprint", Default = "LeftShift", Mode = "Hold",
             Callback = function(on) sprint(on) end }
```

Keybinds fire only while no textbox has focus, and never while another keybind is being rebound — so binding something to the menu key does not close the menu in the same frame.

#### `w:Button{ Text, Callback }`

Plain button.

#### `w:Label(text)`

Group caption in small grey text.

#### `w:Paragraph(text, lines)`

Multi-line description. `lines` is the reserved height in lines (2 by default).

#### `w:Divider()`

A horizontal separator.

#### `w:Group{ Text }`

The middle level of a `Tab -> Groupbox -> control` menu, rebuilt for a flat waterfall window. Returns an object with the **same widget methods**, so controls built through it are drawn inside a captioned box and indented:

```lua
local g = w:Group { Text = "AIM" }
g:Toggle { Text = "Silent aim", Callback = fn }
g:Slider { Text = "FOV", Min = 10, Max = 360, Default = 90, Callback = fn }
g:Done()   -- optional: closing padding
```

`g` exposes `Toggle`, `Slider`, `Select`, `MultiSelect`, `ColorPicker`, `Input`, `Keybind`, `Button`, `Divider`, `Label`, `Paragraph`, plus `Done()`. `g:Toggle{...}` and `g.Toggle{...}` both work.

Groups are visual containers only — they do not fold. Folding would mean re-flowing every row below the group, and rows are positioned at creation time. Collapse the whole window instead.

Groups do not nest (`g` has no `Group` method), but you don't need depth: consecutive `Group` calls stack in call order, so interleaved `AddLeftGroupbox` / `AddRightGroupbox` calls from an Obsidian-style menu port over unchanged.

### Window methods

| Method | Description |
|---|---|
| `w:Open()` | Show the window |
| `w:Close()` | Hide it (reversible — see Notes: Ctrl + menu key restores) |
| `w:SetCollapsed(bool)` | Collapse or expand |
| `w:SetTitle(text, subtitle)` | Change the title |
| `w:Destroy()` | Destroy this window (the menu closes automatically when the last one goes) |

### Global

| Method | Description |
|---|---|
| `AIgui.Notify{ Title, Text, Duration }` | Top-right notification in its own ScreenGui, so it still shows with the menu closed. Returns `{ Close = fn }` |
| `AIgui.SetTheme(tbl)` | Override the theme — **must be called before creating widgets** |
| `AIgui.Configure(tbl)` | Override metrics — also before creating windows |
| `AIgui.SetMenuOpen(bool)` | Visibility + input blocker + mouse lock, all at once |
| `AIgui.ToggleMenu()` | Same, inverted |
| `AIgui.SetKey(Enum.KeyCode)` | Change the menu key, default `Insert` |
| `AIgui.SetAutoUnlockMouse(bool)` | Unlock the cursor while open, default `true` |
| `AIgui.SetRightHoldLook(bool)` | Hold RMB to look around while open, default `true` |
| `AIgui.SetCustomCursor(bool)` | Draw an in-GUI crosshair instead of the OS cursor while open, default `true` |
| `AIgui.SetUnlockPriority(number)` | Render priority for the unlock net, default `Last` |
| `AIgui.SetMouseUnlocked(bool)` | Control the mouse lock manually |
| `AIgui.ForceRestoreMouse()` | Unconditionally give the player a usable cursor (`Default` + visible icon) |
| `AIgui.IsMouseUnlocked()` | Query the current mouse state |
| `AIgui.GetMouseState()` | Diagnostics table: `unlocked`, `behavior`, `iconEnabled`, `auto`, `rightHeld`, `rightLook`, `priority`, `stuck`, `repairs` |
| `AIgui.Arrange()` | Drop manual placements and re-run the waterfall layout |
| `AIgui.ShowAll()` | Re-show every window **and expand them all**, then re-arrange |
| `AIgui.RestoreWindows()` | Re-show only the windows closed with the X, keeping collapse state and dragged positions. Returns how many came back |
| `AIgui.CountVisible()` | How many windows are on screen right now |
| `AIgui.IsPointerOverWindow()` | True when the cursor is over a visible window |
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
| `AIgui.LastError` | Last swallowed callback error, `nil` when clean |

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
    notifyW = 220,   -- notification card width
})
```

---

## Notes

**Set the theme and metrics before creating widgets.** Existing widgets are not updated retroactively — their properties are written at creation time. To re-skin, `Destroy()` and rebuild.

**Mouse unlocking is engine-driven now, not a write fight.** While the menu is open, a zero-size `TextButton` with `Modal = true` sits in the ScreenGui. It can never be hovered or clicked, so it swallows nothing — but the engine applies Modal **after** every script's `MouseBehavior` write each frame, so the game's camera controller loses the race by construction. The library only writes `MouseBehaviour` in one case: holding RMB to hand the camera over (and there it first drops `Modal`, after which the game's own per-frame lock does the work).

- fallback: `AIgui.Configure{ modalUnlock = false }` restores the old three-layer write behaviour (`GetPropertyChangedSignal` re-assert → `Heartbeat` → `BindToRenderStep(Last)`), kept verbatim for engines where zero-size Modal misbehaves. That behaviour is not a documented engine guarantee — Linoria/Obsidian have shipped it for years, but if a future update breaks it, the fallback is one flag away.
- closing the menu sets `Modal = false`; the engine hands control back on its own, no saved-state restore needed for the unlock itself.
- the three-layer machinery still runs in fallback mode and still re-asserts the pointer state in `modalUnlock` mode — it just no longer writes `MouseBehaviour` while unlocked, so there is nothing for a game's `GetPropertyChangedSignal` handler to fight.

**Custom crosshair.** While the menu is open a white crosshair drawn inside the GUI follows the pointer (two 1px frames + outline, `ZIndex` above everything), and the native icon is kept hidden. It follows the real pointer position, so it cannot drift from where clicks land. Hidden while RMB is held (the pointer is pinned to the centre anyway). `AIgui.SetCustomCursor(false)` or `AIgui.Configure{ customCursor = false }` to keep the OS cursor.

**Holding the right button hands the cursor back to the game.** While the menu is open the cursor is free to click widgets, but holding RMB switches `MouseBehavior` to `LockCenter` for as long as it is held: the cursor parks in the middle of the screen, the camera receives mouse delta again, and you can look around without closing the menu. Releasing returns to a free cursor parked at the centre. Turn this off with `AIgui.SetRightHoldLook(false)`.

`AIgui.SetUnlockPriority(n)` only changes layer 3. Note that priorities above 2000 are clamped to 2000 by the engine — setting `Last + 1` silently lands you in the same bucket as the camera. If the cursor still will not appear, call `AIgui.GetMouseState()` and check whether `iconEnabled` is the problem rather than `behavior`.

**Closing the menu always leaves a usable cursor.** `LockCenter` plus a hidden icon is the "cursor pinned to the centre, no crosshair — only the camera moves" state. Three things used to be able to leave the player in it, all fixed:

1. `SetMouseUnlocked(false)` returned early when its own flag already said `false`, skipping the restore entirely. Closing now always runs the full restore.
2. A recorded original value that *was* `LockCenter` with the icon hidden got written straight back. That combination is now rejected and replaced with `Default` + visible icon.
3. A right-button release arriving after the close re-applied the post-hold state. A `restorePending` latch makes the close win, and the result is verified one frame later.

`AIgui.ForceRestoreMouse()` is the escape hatch: it unconditionally writes `Default` + visible icon regardless of internal state. Call it from a keybind if a game ever leaves you stuck. `AIgui.GetMouseState().stuck` reports the exact condition, and `.repairs` counts how many times the post-close check had to re-assert the restore (non-zero means something is fighting the library — usually the game's own camera controller, which legitimately wants `LockCenter` in first person).

**Clicks outside windows reach the game.** By default the full-screen blocker is off while the menu is open: windows sink their own clicks (`Active = true` on the root frame), and a click beside the UI goes into the game — a shooter keeps shooting while the menu is up. Set `AIgui.Configure{ blockOutsideClicks = true }` for the old behaviour (everything eaten). The blocker still comes on before any window exists, so a menu-less load touches nothing.

**Right button is context-sensitive.** Holding RMB outside a window hands the camera over, exactly as before — but holding it **on top of a window does nothing now**, so interacting with the UI never yanks the cursor to the screen centre mid-click.

**"attempt to call missing method 'X'" means the loaded build is stale.** The library is fetched from GitHub on every run, so a script written against `main` runs against whatever is published right now. `AIgui.VERSION` tells you which build you got; the current source is `0.9.0`. If a script fails on `Group` (0.9), `GetMaxScroll` (0.8) or `RestoreWindows` (0.9), the file in this folder has not been pushed yet — either push it, or guard the call: `if type(w.Group) == "function" then ... end`.

**Closing a window is reversible — three ways back.** The X only sets `Visible = false`; the window keeps its widgets, values and connections, so nothing is lost. To bring it back:

- **Ctrl + menu key** (default `Ctrl + Insert`) — restores every closed window and opens the menu if it was hidden
- the menu key on its own, when *every* window has been closed — opening a menu with nothing in it would be a dead end, so it restores instead
- `AIgui.RestoreWindows()` from your own code

Closing the last window also fires a notification that spells out `Ctrl + Insert`, because the state otherwise looks like the menu simply broke. `AIgui.Destroy()` is the permanent one — that kills the UI *and* the script's windows, and cannot be undone without re-executing.

**The input blocker is a `TextButton`, not `Modal`.** It only swallows clicks at the GUI layer. If a game reads `UserInputService.InputBegan` directly without checking `gameProcessed`, the blocker will not stop it — handle that case in your own code.

**Nothing is printed.** Widget callbacks are user code and can throw; the library catches them silently rather than flooding the console (a slider callback fires every frame while dragging). Read `AIgui.LastError` if something stops working — it holds the most recent message.

This applies to the example and to every loader: no `print`, no `warn`, anywhere. If AIgui fails to load, you get a silent no-op stub instead of a console dump, and the failure reasons (one line per mirror) go into a local `loadReport` variable that you can inspect or forward to a notification when debugging. Loading is validated — a mirror serving an error page, a chunk that throws while running, or an old build without `.Window` are all rejected, and the next mirror is tried.

**Windows cap their own height and scroll.** A 30-row window is ~900px plus header; 1080p has roughly 1000px of usable space and the taskbar takes more. So `MaxHeight` defaults to 78% of the viewport: anything taller becomes wheel-scrollable instead of running off the bottom, and a thin bar on the right edge shows the position. Override per window with `MaxHeight = 420` (exact) or `MaxHeight = 0` (unlimited, the pre-0.9 behaviour). Wheel events are only consumed while the pointer is over an overflowing, expanded, visible window — the game keeps its wheel everywhere else.

Note that the cap bounds a *single* window. The waterfall still stacks windows top-to-bottom in each column, so a large number of expanded windows can exceed the screen height as a group; collapse the ones you are not using (`SetCollapsed` keeps only the 32px title bar).

**Loading without creating a window touches nothing.** The full-screen blocker eats every click when visible, so it only activates once the first window exists.

---

## Porting a Tab / Groupbox menu

Three things break when moving a real menu onto a waterfall layout, and the example exercises all three on purpose:

**1. Creating a widget must not fire its callback.** In a real menu a toggle callback does work — writes a global, hooks a remote, starts a loop. If creation fired it, 98 toggles would run their side effects in creation order and the last one would win. AIgui never calls `Callback` on create, and `widget:Set(v)` is silent too: only a real click fires it. So the order in which you build controls is irrelevant, and a config loader can `Set()` freely without re-running anything.

**2. Long pages have to become scrollable.** Covered above — it is on by default, so a ported `AddTab` with 20+ rows works without extra code.

**3. `Tab -> Groupbox -> control` has no direct equivalent.** One tab = one window (that is what the tab strip becomes), and each groupbox becomes `w:Group{ Text = "..." }`. Left/right groupboxes interleave in the source; a waterfall has a single column, so they append in call order — visually the boxes stack, and no call has to be reordered.

Splitting one tab across several windows is a separate choice, not a workaround: if a tab is genuinely two unrelated feature sets, building two windows reads better than one 40-row column.

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
