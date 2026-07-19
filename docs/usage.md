# MixDeck — Usage Guide

## What is MixDeck?

MixDeck lets you define **export presets** — named configurations that map your tracks to left/right channels — and batch export all of them with one click. Instead of manually muting tracks and re-rendering for every mix variation, you define the presets once and hit **Export All**.

**Example use cases:**
- Export "Bass Isolated" — bass tracks on the left, everything else on the right
- Export "Guitar + Vox" — guitar and vocal tracks on the left, rest on the right  
- Export "Full Mix" — standard stereo export
- Any other L/R routing combination you want

---

## Prerequisites

| Requirement | Version | Where to get it |
|---|---|---|
| Reaper | 6.0+ | [reaper.fm](https://www.reaper.fm) |
| ReaImGui | 0.8+ | Extensions → ReaPack → Browse packages → search **ReaImGui** |

---

## Installation

1. Open Reaper
2. Go to **Actions → Load ReaScript**
3. Browse to the MixDeck folder and select **`install.lua`**
4. Click **Run** — the installer will:
   - Check that ReaImGui is installed
   - Copy MixDeck scripts to `{Reaper resource path}/Scripts/MixDeck/`
   - Register MixDeck as a Reaper action
5. If ReaImGui is missing, follow the on-screen instructions, then re-run the installer

---

## Opening MixDeck

After installation:

1. **Actions → Action list** (or `?` shortcut)
2. Search: `MixDeck`
3. Double-click or assign a keyboard shortcut
4. The MixDeck window will open

---

## The Interface

```
┌─────────────────────────────────────────────────────────┐
│  MixDeck  v1.0.0                                        │
├───────────────────┬─────────────────────────────────────┤
│  PRESETS          │  EDIT PRESET: Bass Isolated         │
│  [G] Bass Isolated│                                     │
│  [G] Guitar + Vox │  Name, scope, format settings...    │
│  [P] Verse Build  │                                     │
│                   │  TRACK ROUTING table                │
│  ⚙  Settings      │  + Add Track                        │
├───────────────────│                                     │
│  [+ New] [- Del]  │  Output preview + Export buttons    │
└───────────────────┴─────────────────────────────────────┘
```

**Left panel:** Your preset library. `[G]` = global (all projects), `[P]` = project-only.

**Right panel:** Editor for the selected preset, or Settings when ⚙ is selected.

---

## Preset Scopes

| Scope | What it means |
|---|---|
| **Global** | Saved to Reaper's Scripts folder. Available in every project you open. |
| **Project** | Saved next to your `.rpp` file. Only appears in that project. |

If a project preset has the **same name** as a global preset, the project version takes priority for that project. This lets you override a standard preset for a specific song without affecting others.

---

## Creating a Preset

1. Click **+ New** in the left panel
2. Enter a name (e.g. `Bass Isolated`)
3. Choose **Global** or **Project** scope
4. Click **Create**
5. In the routing table, use **+ Add Track** to add tracks from your project
6. Set each track's channel: **L (Left)**, **R (Right)**, or **B (Both)**
7. The **(everything else)** row is implicit — unmapped tracks go to the opposite channel automatically
8. Click **Save Preset**

---

## Track Routing Rules

- Tracks you **add to the routing table** are assigned to their specified channel
- **Everything else** (all tracks not in the table) goes to the opposite channel
- If you map tracks to **L**, everything else goes to **R**, and vice versa
- Use **B (Both)** to include a track on both channels (e.g. a room mic you always want)
- You can add **parent/folder tracks** — all child tracks inherit the same routing

### Example: "Bass Isolated"

| Track | Channel |
|---|---|
| Bass_Dry | L |
| Bass_Wet | L |
| *(everything else)* | R |

---

## Export Folder Settings

Click **⚙ Settings** to configure where exported files land:

| Setting | Behavior |
|---|---|
| **Common export folder** | Used for all projects. Leave blank to export next to the `.rpp` file. |
| **Project export folder** | Overrides the common folder for this project only. |

**Resolution order:** Project folder → Common folder → Project `.rpp` folder (fallback)

---

## Exporting

### Export a single preset
1. Select the preset in the left panel
2. Check the **Output preview** at the bottom of the editor
3. Click **Export This**

### Export all presets at once
1. Click **Export All** from any preset's editor panel
2. MixDeck will loop through every preset, apply routing, render, and restore your project state

### Output filename format
```
{ProjectName}_{PresetName}.{format}
```
Example: `BandSession_BassIsolated.mp3`

> **Note:** You must have your project saved before exporting. Unsaved/untitled projects will show an error.

---

## Troubleshooting

**"ReaImGui NOT found"**
→ Install ReaImGui via Extensions → ReaPack → Browse packages

**Tracks not found during export**
→ Make sure the track names in your preset exactly match the track names in your project (case-sensitive)

**Config file not loading**
→ Check the Reaper console (View → Show console) for error messages with the `[MixDeck]` prefix

**Preset saved but not showing**
→ Global presets are stored at: `{Reaper resource path}/Scripts/MixDeck/mixdeck_global.json`
→ Project presets are stored at: `{project folder}/{project name}.mixdeck.json`

---

## File Locations

| File | Location |
|---|---|
| MixDeck scripts | `{Reaper resource path}/Scripts/MixDeck/` |
| Global presets | `{Reaper resource path}/Scripts/MixDeck/mixdeck_global.json` |
| Project presets | `{project folder}/{project name}.mixdeck.json` |
