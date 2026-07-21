# MixDeck 🎛️ v1.0.0

A fast, professional **export preset manager** for Reaper. Define once, export forever — manage multi-channel mixes with L/R routing configurations, batch export all variations in one click.

## Features

✅ **Preset Library** — Global presets (shared across all projects) + project-scoped presets (specific to one project). Presets override smartly.

✅ **Track Routing** — Map individual tracks or parent folder tracks to Left/Right/Both channels. Unmapped tracks get the opposite channel automatically.

✅ **Batch Export** — Queue up export configs and render all of them in sequence. Muting, panning, and project state are automatically handled.

✅ **Format Support** — MP3 (with bitrate control: 128–320k), WAV (24-bit), FLAC.

✅ **Flexible Export Paths** — Common export folder (all projects) + per-project overrides. Falls back to the project folder if not configured.

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

## Requirements

- **Reaper** 6.0+
- **ReaImGui** extension 0.8+ (installed via ReaPack package manager)

## Installation

1. **Install ReaImGui first (if not already present):**
   - Open Reaper
   - Look for **Extensions → ReaPack → Browse packages** (or try **Help → About REAPER → Show REAPER resource path**, then open `Scripts/Packages/ReaImGui` folder if it exists)
   - If ReaPack isn't visible, you can **install it manually**: Download from [cfillion/reaimgui](https://github.com/cfillion/reaimgui/releases) and extract to `{Reaper resource path}/UserPlugins/`
   - Search for `ReaImGui` and install by cfillion
   - Restart Reaper

2. **Run the MixDeck installer:**
   - Open Reaper
   - **Actions → Load ReaScript**
   - Browse to `MixDeck/install.lua` and click **Run**
   - The installer will verify ReaImGui is present and set up MixDeck

3. **Open MixDeck:**
   - Actions → Action list (search: `MixDeck`)
   - Double-click to open, or assign a keyboard shortcut

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

Output files: `{ProjectName}_{PresetName}.mp3` (or `.wav`, `.flac`)

## File Locations

| File | Location |
|---|---|
| MixDeck scripts | `{Reaper resource path}/Scripts/MixDeck/` |
| Global presets | `{Reaper resource path}/Scripts/MixDeck/mixdeck_global.json` |
| Project presets | `{project folder}/{project name}.mixdeck.json` |

## Architecture

**mixdeck.lua** (550+ lines)
- Config management (JSON save/load)
- Preset CRUD
- Track routing & pan control
- Real render queue integration

**ui.lua** (400+ lines)
- ImGui-based editor
- Preset list with drag-to-reorder
- Track routing table
- Export folder settings

**json_utils.lua** (150+ lines)
- Standalone JSON encoder/decoder

**install.lua**
- Dependency checker
- Auto-installer to Reaper Scripts folder

## Planned Features (v1.1+)

- Audio preview (play 4 bars with current routing)
- Presets library browser / web sync
- Render progress indicator
- Undo support
- Stems export (one file per track)
- Loudness normalization

## Troubleshooting

**Can't find "Extensions → ReaPack" menu**
→ ReaPack may not be installed. Try:
   - **Help → ReaPack...** (some versions show it here)
   - **Tools → ReaPack...** (other versions)
   - If still not found, manually download ReaImGui from [cfillion/reaimgui](https://github.com/cfillion/reaimgui/releases) and extract to `{Reaper resource path}/UserPlugins/`

**ReaImGui not found after installation**
→ ReaImGui needs to be installed/enabled in Reaper before running MixDeck installer. Make sure you:
   - Installed ReaImGui via ReaPack (or manually to UserPlugins)
   - Restarted Reaper
   - Check Reaper console (View → Show console) for any errors

**Tracks not routing correctly**
→ Track names in presets must match project track names exactly (case-sensitive)

**Config file missing after export**
→ Check console (View → Show console) for `[MixDeck]` error messages

## License

MIT (see LICENSE file if included)

---

**Made for Reaper musicians. Happy mixing! 🎶**
