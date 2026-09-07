# MixDeck 🎛️ v1.5.1

A fast, professional **export preset manager** for Reaper. Define once, export forever — manage multi-channel mixes with L/R routing configurations, batch export all variations in one click.

## Features

✅ **Preset Library** — Global presets (shared across all projects) + project-scoped presets (specific to one project). Presets override smartly.

✅ **Track Routing** — Map individual tracks or parent folder tracks to Left/Right/Both channels. Unmapped tracks get the opposite channel automatically.

✅ **Batch Export** — Queue up export configs and render all of them in sequence. Muting, panning, and project state are automatically handled.

✅ **Format Support** — MP3 (with bitrate control: 128–320k), WAV (24-bit), FLAC.

✅ **Flexible Export Paths** — Common export folder (all projects) + per-project overrides. Falls back to the project folder if not configured.

✅ **Export Song As-Is** — Tick the box beside **Export All** to render the untouched mix first, as `{ProjectName}.{ext}`, before working through the presets. Gives you the reference full mix alongside the variations.

✅ **Metronome** — Include a click in exports (handy for play-along takes), and keep the transport metronome on for recording. The export click uses Reaper's **click source**, laid over the project for the render and removed afterwards — real audio that renders, unlike the transport metronome.

✅ **Keyboard Shortcuts**
- **Ctrl+S** — Save current preset
- **Ctrl+E** — Export current preset
- **Delete** — Delete selected preset
- **Drag presets** to reorder them

✅ **ImGui-Based UI** — Fast, responsive, dockable window with a clean editor and settings panel.

✅ **Installer** — Automatically checks for dependencies (ReaImGui) and installs to the correct Reaper folder.

## What It Solves

Instead of manually:
```
1. Mute some tracks
2. Render
3. Restore, mute different tracks
4. Render again
5. (repeat for every mix variation...)
```

With MixDeck:
```
1. Define presets: "Bass Isolated", "Guitar + Vox", "Full Mix"
2. Click "Export All"
3. (Done — all files rendered with correct routing)
```

## Typical Use Case: Band Member Exports

For band workflows, create one preset per member and route that member's track(s) to one side while routing everything else to the other side.

Example:
- `Vocals` preset: vocals tracks to **Left**, everything else to **Right**
- `Guitar` preset: guitar tracks to **Left**, everything else to **Right**
- `Bass` preset: bass tracks to **Left**, everything else to **Right**

Because presets are reusable, you can use the same MixDeck setup across every recording project that has similarly named tracks, then run **Export All** to generate all member takes in one pass.

## Requirements

- **Reaper** 6.0+
- **ReaImGui** extension 0.8+ (installed via ReaPack package manager)

## Installation

### Step 1: Install ReaPack (if not already present)

ReaPack is Reaper's package manager — it makes installing extensions easy.

- **Download:** https://reapack.com/
- **Extract to:** `{Reaper resource path}/UserPlugins/`
- **Restart Reaper**

To find your Reaper resource path: **Help > About REAPER > Show REAPER resource path**

### Step 2: Install ReaImGui (via ReaPack)

- In Reaper, open **Actions > Action list** (or press `?`)
- Search: `ReaPack: Browse packages`
- Double-click to open the package browser
- Search for: `ReaImGui`
- Click **Install**
- **Restart Reaper**

### Step 3: Install MixDeck

- Open Reaper
- **Actions > Load ReaScript**
- Browse to `MixDeck/install.lua` and click **Run**
- The installer will verify dependencies and set up MixDeck
- **MixDeck window will open automatically** when installation is complete

### Future Launches

Find MixDeck in **Actions > Action list** (search: `MixDeck`) or assign a keyboard shortcut

## Quick Start

### 1. Create a Preset
- Click **+ New** in the left panel
- Name it (e.g. `Bass Isolated`)
- Choose **Global** or **Project** scope
- Click **Create**

### 2. Configure Routing
- Use **+ Add Track** to pick tracks from your project
- Set each track's channel: **L**, **R**, or **B** (both)
- The **(everything else)** row is implicit — unmapped tracks go to the opposite side

### 3. Export
- Click **Export This** for a single preset, or
- Click **Export All** to render all presets at once

Output files: `{ExportFolder}/{PresetName}/{ProjectName}-{PresetName}.mp3` (or `.wav`, `.flac`)

With **Export song as-is first** ticked, `{ExportFolder}/{ProjectName}.mp3` is rendered too — beside the preset folders, since it is not a preset.

## File Locations

| File | Location |
|---|---|
| MixDeck scripts | `{Reaper resource path}/Scripts/MixDeck/` |
| Global presets | `{Reaper resource path}/Scripts/MixDeck/mixdeck_global.json` |
| Project presets | `{project folder}/{project name}.mixdeck.json` |
| Logs | `{Reaper resource path}/Scripts/MixDeck/mixdeck.log` (and `mixdeck_errors.log`) |
| Song as-is export | `{export folder}/{project name}.{ext}` |

## Architecture

**mixdeck.lua**
- Config management (atomic, merge-preserving JSON save/load)
- Preset CRUD and ordering
- Track routing & pan control
- Render integration, with project state snapshotted and restored around every export

**ui.lua**
- ImGui-based editor
- Preset list with drag-to-reorder
- Track routing table
- Export folder settings

**json_utils.lua**
- Standalone JSON encoder/decoder (strict: malformed input raises rather than looping)

**installer_utils.lua**
- Resolves which `install.lua` the in-app Update button runs

**install.lua**
- Dependency checker
- Auto-installer to Reaper Scripts folder

**tests/**
- Runs the real Lua against a mock Reaper API. `python -m pytest MixDeck/tests -q`

## Planned Features

- Audio preview (play 4 bars with current routing)
- Presets library browser / web sync
- Render progress indicator
- Stems export (one file per track)
- Loudness normalization

## Troubleshooting

**ReaPack not found**
→ Install ReaPack from https://reapack.com/ and extract to `{Reaper resource path}/UserPlugins/`

**ReaImGui not found**
→ After installing ReaPack, search Actions for "ReaPack: Browse packages", install ReaImGui, then restart Reaper

**Can't find "ReaPack: Browse packages" in Actions**
→ Make sure you restarted Reaper after installing ReaPack (it registers itself on startup)

**Tracks not routing correctly**
→ Track names are matched case-insensitively, and missing tracks can be remapped per project in the preset editor

**No click in the exported file**
→ MixDeck renders the click as a temporary click-source track, so metronome routing does not matter. If the click is missing, check the log in Settings for "Export click unavailable" — some builds may not expose a click source, and the Settings panel warns when that is the case.

**Config file missing after export**
→ Check console (View → Show console) for `[MixDeck]` error messages

## License

MIT (see LICENSE file if included)

---

**Made for Reaper musicians. Happy mixing! 🎶**
