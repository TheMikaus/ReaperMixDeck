# MixDeck

A ReaScript tool for managing multi-channel export presets. Configure track routing rules and batch export multiple versions of your mix automatically.

## Features

- **Export Presets**: Define multiple export configurations
- **Track Routing**: Map individual tracks or parent tracks to left/right channels
- **Batch Export**: Export all presets in one go with automatic muting/soloing
- **Project Integration**: Configurations stored as JSON, tied to the project file
- **Easy UI**: Simple dock/window interface for preset management

## Project Structure

```
MixDeck/
├── mixdeck.lua                      # Main ReaScript
├── config/                          # Default configuration templates
│   └── default_config.json
├── docs/                            # Documentation
│   └── usage.md
└── README.md
```

## Quick Start

1. Open this script in Reaper's Script Editor
2. Run the script to open the configuration window
3. Create export presets with your channel mappings
4. Hit "Export All" to batch render

## Configuration Format

Export configurations are stored as JSON in the project file metadata or a companion `.json` file.

Example preset:
```json
{
  "name": "Bass Isolated",
  "routing": {
    "Bass_Dry": "L",
    "Everything_Else": "R"
  },
  "format": "mp3",
  "bitrate": "320k"
}
```

## Development Status

- [ ] Core ReaScript structure
- [ ] Configuration UI (defer or imgui based)
- [ ] Track analysis and routing logic
- [ ] Batch export automation
- [ ] JSON config persistence
- [ ] Error handling and validation
