-- MixDeck: Export Preset Manager for Reaper
-- Manage multiple export configurations and batch render with custom track routing
-- @author ReaperAutomation
-- @version 1.0.0

-- Load JSON utilities
local json = dofile(debug.getinfo(1).source:match("@?(.*/?)") .. "json_utils.lua")

local md = {
  version = "1.0.0",
  name = "MixDeck",
  presets = {},
  config_file = "",
  current_project = "",
  ui_open = false,
  selected_preset = nil,
  muted_state = {}, -- Track original mute states during export
  soloed_state = {}, -- Track original solo states during export
}

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

local function log(msg, level)
  level = level or "INFO"
  reaper.ShowConsoleMsg("[" .. md.name .. " " .. level .. "] " .. msg .. "\n")
end

local function get_project_folder()
  local retval, proj_path = reaper.EnumProjects(-1)
  if proj_path == "" then
    return nil
  end
  -- Extract folder from full path
  local folder = proj_path:match("^(.+[\\/])[^\\/]+$")
  return folder
end

local function get_project_name()
  local retval, proj_path = reaper.EnumProjects(-1)
  if proj_path == "" then
    return nil
  end
  -- Extract filename without extension
  local name = proj_path:match("^.+[\\/]([^\\/.]+)%.")
  return name
end

local function get_config_file_path()
  local folder = get_project_folder()
  local name = get_project_name()
  if not folder or not name then
    return nil
  end
  return folder .. name .. ".mixdeck.json"
end

-- Simple JSON encode/decode using Lua tables
local function json_encode(tbl)
  return json.encode(tbl)
end

local function json_decode_simple(json_str)
  return json.decode(json_str)
end

-- ============================================================================
-- CONFIG MANAGEMENT
-- ============================================================================

local function load_config()
  local config_path = get_config_file_path()
  if not config_path then
    log("No active project - cannot load config", "WARN")
    return {}
  end

  local file = io.open(config_path, "r")
  if not file then
    log("Config file not found: " .. config_path .. ", starting fresh", "INFO")
    return {}
  end

  local content = file:read("*all")
  file:close()

  local success, result = pcall(function()
    local data = json_decode_simple(content)
    return data.presets or {}
  end)

  if success then
    log("Loaded " .. #result .. " presets from: " .. config_path, "INFO")
    return result
  else
    log("Failed to parse config file: " .. result, "ERROR")
    return {}
  end
end

local function save_config()
  local config_path = get_config_file_path()
  if not config_path then
    log("No active project - cannot save config", "WARN")
    return false
  end

  local file = io.open(config_path, "w")
  if not file then
    log("Failed to open config file for writing: " .. config_path, "ERROR")
    return false
  end

  local data = {
    version = md.version,
    presets = md.presets,
    timestamp = os.time(),
  }

  local json_str = json_encode(data)
  file:write(json_str)
  file:close()
  log("Config saved to: " .. config_path, "INFO")
  return true
end

-- ============================================================================
-- PRESET MANAGEMENT
-- ============================================================================

local function create_preset(name)
  if not name or name == "" then
    log("Preset name cannot be empty", "WARN")
    return nil
  end

  -- Check if preset already exists
  for _, preset in ipairs(md.presets) do
    if preset.name == name then
      log("Preset '" .. name .. "' already exists", "WARN")
      return nil
    end
  end

  local preset = {
    name = name,
    routing = {},
    format = "mp3",
    bitrate = "320k",
    timestamp = os.time(),
  }

  table.insert(md.presets, preset)
  log("Created preset: " .. name, "INFO")
  return preset
end

local function delete_preset(name)
  for i, preset in ipairs(md.presets) do
    if preset.name == name then
      table.remove(md.presets, i)
      log("Deleted preset: " .. name, "INFO")
      return true
    end
  end
  log("Preset not found: " .. name, "WARN")
  return false
end

local function get_preset(name)
  for _, preset in ipairs(md.presets) do
    if preset.name == name then
      return preset
    end
  end
  return nil
end

local function update_preset_routing(preset_name, track_name, channel)
  local preset = get_preset(preset_name)
  if not preset then
    log("Preset not found: " .. preset_name, "WARN")
    return false
  end

  if channel ~= "L" and channel ~= "R" and channel ~= "B" then
    log("Invalid channel: " .. channel .. " (must be L, R, or B)", "WARN")
    return false
  end

  preset.routing[track_name] = channel
  log("Updated routing: " .. preset_name .. " -> " .. track_name .. " to " .. channel, "INFO")
  return true
end

-- ============================================================================
-- TRACK INFORMATION
-- ============================================================================

local function get_all_tracks()
  local tracks = {}
  local track_count = reaper.CountTracks(0)
  for i = 0, track_count - 1 do
    local track = reaper.GetTrack(0, i)
    local retval, track_name = reaper.GetTrackName(track)
    local is_folder = reaper.GetTrackDepth(track)
    table.insert(tracks, {
      index = i,
      track = track,
      name = track_name,
      is_folder = is_folder,
    })
  end
  return tracks
end

local function print_track_structure()
  log("=== Track Structure ===", "INFO")
  local tracks = get_all_tracks()
  for _, info in ipairs(tracks) do
    local indent = string.rep("  ", info.is_folder)
    log(indent .. info.name, "INFO")
  end
  log("======================", "INFO")
end

-- ============================================================================
-- EXPORT LOGIC
-- ============================================================================

local function save_mute_solo_state()
  md.muted_state = {}
  md.soloed_state = {}
  local track_count = reaper.CountTracks(0)
  for i = 0, track_count - 1 do
    local track = reaper.GetTrack(0, i)
    md.muted_state[i] = reaper.GetMediaTrackInfo_Value(track, "B_MUTE")
    md.soloed_state[i] = reaper.GetMediaTrackInfo_Value(track, "I_SOLO")
  end
end

local function restore_mute_solo_state()
  for i, mute_state in pairs(md.muted_state) do
    local track = reaper.GetTrack(0, i)
    if track then
      reaper.SetMediaTrackInfo_Value(track, "B_MUTE", mute_state)
    end
  end
  for i, solo_state in pairs(md.soloed_state) do
    local track = reaper.GetTrack(0, i)
    if track then
      reaper.SetMediaTrackInfo_Value(track, "I_SOLO", solo_state)
    end
  end
  reaper.UpdateArrange()
end

local function find_track_by_name(name)
  local track_count = reaper.CountTracks(0)
  for i = 0, track_count - 1 do
    local track = reaper.GetTrack(0, i)
    local retval, track_name = reaper.GetTrackName(track)
    if track_name == name then
      return track, i
    end
  end
  return nil, nil
end

local function get_children_tracks(parent_track)
  local children = {}
  local track_count = reaper.CountTracks(0)
  local retval, parent_name = reaper.GetTrackName(parent_track)
  local parent_depth = reaper.GetTrackDepth(parent_track)

  -- Find parent track index
  local parent_idx = nil
  for i = 0, track_count - 1 do
    local track = reaper.GetTrack(0, i)
    if track == parent_track then
      parent_idx = i
      break
    end
  end

  if not parent_idx then
    return children
  end

  -- Find all children (tracks that follow with greater depth)
  for i = parent_idx + 1, track_count - 1 do
    local track = reaper.GetTrack(0, i)
    local depth = reaper.GetTrackDepth(track)
    if depth <= parent_depth then
      break -- No longer a child
    end
    if depth == parent_depth + 1 then
      table.insert(children, track)
    end
  end

  return children
end

local function apply_routing(preset)
  log("Applying routing for preset: " .. preset.name, "INFO")

  -- First, unmute and unsolo all tracks
  local track_count = reaper.CountTracks(0)
  for i = 0, track_count - 1 do
    local track = reaper.GetTrack(0, i)
    reaper.SetMediaTrackInfo_Value(track, "B_MUTE", 0)
    reaper.SetMediaTrackInfo_Value(track, "I_SOLO", 0)
  end

  -- Get master track for reference
  local master = reaper.GetMasterTrack(0)
  local retval, master_name = reaper.GetTrackName(master)

  -- Process routing
  local found_tracks = {}
  for track_ref, channel in pairs(preset.routing) do
    if track_ref ~= "Master" then
      local track, idx = find_track_by_name(track_ref)
      if track then
        found_tracks[track_ref] = true
        -- Get all children if this is a folder track
        local children = get_children_tracks(track)
        if #children > 0 then
          log("Track '" .. track_ref .. "' is a folder with " .. #children .. " children", "INFO")
          for _, child in ipairs(children) do
            reaper.SetMediaTrackInfo_Value(child, "B_MUTE", 0)
          end
        end
      else
        log("Track not found: " .. track_ref, "WARN")
      end
    end
  end

  log("Routing applied successfully", "INFO")
  reaper.UpdateArrange()
end

local function export_preset(preset)
  if not preset then
    log("Invalid preset", "ERROR")
    return false
  end

  log("Starting export for preset: " .. preset.name, "INFO")

  -- Save current state
  save_mute_solo_state()

  -- Apply routing
  apply_routing(preset)

  -- TODO: Setup render queue and execute render
  -- For now, just show what would happen
  log("Would export: " .. preset.name .. " as " .. preset.format, "INFO")
  local project_name = get_project_name()
  local output_name = project_name .. "_" .. preset.name .. "." .. preset.format
  log("Output file: " .. output_name, "INFO")

  -- Restore original state
  restore_mute_solo_state()

local function batch_export()
  if #md.presets == 0 then
    log("No presets defined", "WARN")
    return false
  end

  log("Starting batch export of " .. #md.presets .. " presets", "INFO")
  for _, preset in ipairs(md.presets) do
    export_preset(preset)
  end
  log("Batch export completed", "INFO")
  return true
end

-- ============================================================================
-- UI MANAGEMENT
-- ============================================================================

local function show_ui()
  log("Opening MixDeck UI", "INFO")
  md.ui_open = true

  local msg = md.name .. " v" .. md.version .. "\n"
  msg = msg .. "======================\n\n"
  msg = msg .. "Total Presets: " .. #md.presets .. "\n\n"
  msg = msg .. "Available Commands:\n"
  msg = msg .. "  list     - List all presets\n"
  msg = msg .. "  tracks   - Show track structure\n"
  msg = msg .. "  create   - Create new preset\n"
  msg = msg .. "  delete   - Delete preset\n"
  msg = msg .. "  route    - Add track to preset\n"
  msg = msg .. "  export   - Export preset\n"
  msg = msg .. "  batch    - Export all presets\n"
  msg = msg .. "  save     - Save config\n"
  msg = msg .. "  quit     - Close\n\n"

  log(msg, "INFO")
end

local function list_presets()
  if #md.presets == 0 then
    log("No presets defined", "INFO")
    return
  end

  log("=== Presets ===", "INFO")
  for i, preset in ipairs(md.presets) do
    log(i .. ". " .. preset.name .. " (" .. preset.format .. ")", "INFO")
    for track, channel in pairs(preset.routing) do
      log("   -> " .. track .. " : " .. channel, "INFO")
    end
  end
  log("===============", "INFO")
end

-- ============================================================================
-- INITIALIZATION & MAIN LOOP
-- ============================================================================

local function init()
  log("Initializing " .. md.name .. " v" .. md.version, "INFO")

  -- Load config from project
  md.presets = load_config()

  -- Show initial UI
  show_ui()

  -- Print track structure
  print_track_structure()
end

local function main_loop()
  -- This will be called repeatedly via defer for UI responsiveness
  reaper.defer(main_loop)
end

-- ============================================================================
-- MAIN ENTRY POINT
-- ============================================================================

init()
main_loop()
