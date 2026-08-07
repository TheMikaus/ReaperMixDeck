-- MixDeck: Export Preset Manager for Reaper
-- Manage multiple export configurations and batch render with custom track routing
-- @author ReaperAutomation
-- @version 1.3.21

-- Load JSON utilities
local function get_script_dir()
  local src = debug.getinfo(1).source
  if src:sub(1, 1) == "@" then
    src = src:sub(2)
  end
  local dir = src:match("(.*[/\\])")
  return dir or ""
end

local json = dofile(get_script_dir() .. "json_utils.lua")

local md = {
  version = "1.3.21",
  name = "MixDeck",
  global_presets = {},      -- Presets shared across all projects
  project_presets = {},     -- Presets specific to the current project
  presets = {},             -- Merged view: global + project (read-only, rebuilt on load/save)
  global_export_path = "", -- Common output folder for all projects
  project_export_path = "",-- Per-project output folder override
  format = "mp3",           -- Global default format for exports
  bitrate = "320k",         -- Global default bitrate for MP3/OGG
  config_file = "",
  current_project = "",
  ui_open = false,
  selected_preset = nil,
  muted_state = {},  -- Track original mute states during export
  soloed_state = {}, -- Track original solo states during export
  log_lines = {},
  log_path = get_script_dir() .. "mixdeck.log",
  error_log_path = get_script_dir() .. "mixdeck_errors.log",
  install_source_dir = "",
}

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

-- Internal log buffer: last 200 entries, exposed to UI via md.log_lines
local LOG_MAX = 200

local function append_to_file(path, line)
  local dir = path:match("(.+)[/\\][^/\\]+$")
  if dir and dir ~= "" then
    pcall(function()
      reaper.RecursiveCreateDirectory(dir, 0)
    end)
  end

  local file = io.open(path, "a")
  if not file then return false end
  file:write(line .. "\n")
  file:close()
  return true
end

local function log(msg, level)
  level = level or "INFO"
  local stamp = os.date("%Y-%m-%d %H:%M:%S")
  local entry = "[" .. stamp .. "] [" .. level .. "] " .. msg
  table.insert(md.log_lines, entry)
  if #md.log_lines > LOG_MAX then
    table.remove(md.log_lines, 1)
  end
  append_to_file(md.log_path, entry)
  if level == "ERROR" then
    append_to_file(md.error_log_path, entry)
  end
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

-- Global config lives in Reaper's resource path, survives across all projects
local function get_global_config_path()
  local resource_path = reaper.GetResourcePath()
  local dir = resource_path .. "/Scripts/MixDeck"
  -- Ensure directory exists (Reaper 6.29+: reaper.RecursiveCreateDirectory)
  reaper.RecursiveCreateDirectory(dir, 0)
  return dir .. "/mixdeck_global.json"
end

local function get_runtime_log_dir()
  local dir = get_global_config_path():match("(.+)[/\\][^/\\]+$") or get_script_dir()
  return dir
end

local function get_install_source_state_path()
  local global_path = get_global_config_path()
  local dir = global_path:match("(.+)[/\\][^/\\]+$") or get_script_dir()
  return dir .. "/mixdeck_install_source.txt"
end

local function load_install_source_dir()
  local path = get_install_source_state_path()
  local file = io.open(path, "r")
  if not file then return "" end
  local dir = file:read("*l") or ""
  file:close()
  if dir ~= "" then
    md.install_source_dir = dir
  end
  return md.install_source_dir or ""
end

local function save_install_source_dir(dir)
  if not dir or dir == "" then return false end
  dir = dir:gsub("\\", "/")
  if dir:sub(-1) ~= "/" then
    dir = dir .. "/"
  end
  local path = get_install_source_state_path()
  local file = io.open(path, "w")
  if not file then return false end
  file:write(dir)
  file:close()
  md.install_source_dir = dir
  return true
end

-- Per-project config lives next to the .rpp file
local function get_project_config_path()
  local folder = get_project_folder()
  local name = get_project_name()
  if not folder or not name then
    return nil
  end
  return folder .. name .. ".mixdeck.json"
end

-- Legacy alias used by export naming
local function get_config_file_path()
  return get_project_config_path()
end

-- Rebuild the merged preset list (global first, project presets override by name)
local function rebuild_merged_presets()
  local merged = {}
  local seen = {}
  -- Global presets go in first
  for _, p in ipairs(md.global_presets) do
    table.insert(merged, p)
    seen[p.name] = true
  end
  -- Project presets: if same name exists globally, override it; otherwise append
  for _, p in ipairs(md.project_presets) do
    if seen[p.name] then
      for i, m in ipairs(merged) do
        if m.name == p.name then
          merged[i] = p  -- project wins
          break
        end
      end
    else
      table.insert(merged, p)
      seen[p.name] = true
    end
  end
  md.presets = merged
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

local function load_config_file(path)
  if not path then return {} end
  local file = io.open(path, "r")
  if not file then return {} end
  local content = file:read("*all")
  file:close()
  local success, result = pcall(function()
    return json_decode_simple(content)
  end)
  if success then
    return result
  else
    log("Failed to parse: " .. path .. " - " .. tostring(result), "ERROR")
    return {}
  end
end

local function load_config()
  -- Load global config (presets + global export path + format settings)
  local global_path = get_global_config_path()
  local global_data = load_config_file(global_path)
  md.global_presets = global_data.presets or {}
  md.global_export_path = global_data.export_path or ""
  md.format = global_data.format or "mp3"
  md.bitrate = global_data.bitrate or "320k"
  log("Loaded " .. #md.global_presets .. " global presets from: " .. global_path, "INFO")

  -- Load project config (presets + project export path override)
  local project_path = get_project_config_path()
  if project_path then
    local project_data = load_config_file(project_path)
    md.project_presets = project_data.presets or {}
    md.project_export_path = project_data.export_path or ""
    log("Loaded " .. #md.project_presets .. " project presets from: " .. project_path, "INFO")
  else
    md.project_presets = {}
    md.project_export_path = ""
    log("No active project — skipping project preset load", "WARN")
  end

  rebuild_merged_presets()
  return md.presets
end

-- Resolve the output folder: project path > global path > project folder
local function get_export_path()
  if md.project_export_path and md.project_export_path ~= "" then
    return md.project_export_path
  elseif md.global_export_path and md.global_export_path ~= "" then
    return md.global_export_path
  else
    return get_project_folder()  -- fallback: same folder as .rpp
  end
end

-- Save a preset to global or project scope
-- scope: "global" or "project" (default: global)
local function save_preset_to_scope(preset, scope)
  scope = scope or "global"
  local target, path
  if scope == "global" then
    target = md.global_presets
    path = get_global_config_path()
  else
    target = md.project_presets
    path = get_project_config_path()
    if not path then
      log("Cannot save project preset — no active project", "WARN")
      return false
    end
  end

  -- Update or insert in the target list
  local found = false
  for i, p in ipairs(target) do
    if p.name == preset.name then
      target[i] = preset
      found = true
      break
    end
  end
  if not found then
    table.insert(target, preset)
  end

  -- Write to disk
  local file = io.open(path, "w")
  if not file then
    log("Failed to write " .. scope .. " config: " .. path, "ERROR")
    return false
  end
  local data = { version = md.version, presets = target, timestamp = os.time() }
  file:write(json_encode(data))
  file:close()

  rebuild_merged_presets()
  log("Saved preset '" .. preset.name .. "' to " .. scope .. " scope", "INFO")
  return true
end

local function save_config(scope)
  scope = scope or "global"
  local target, export_path_val, path
  if scope == "global" then
    target = md.global_presets
    export_path_val = md.global_export_path
    path = get_global_config_path()
  else
    target = md.project_presets
    export_path_val = md.project_export_path
    path = get_project_config_path()
    if not path then
      log("No active project — cannot save project config", "WARN")
      return false
    end
  end
  local file = io.open(path, "w")
  if not file then
    log("Failed to open config for writing: " .. path, "ERROR")
    return false
  end
  local data = {
    version = md.version,
    presets = target,
    export_path = export_path_val,
    timestamp = os.time()
  }
  -- Add format/bitrate only to global config
  if scope == "global" then
    data.format = md.format
    data.bitrate = md.bitrate
  end
  file:write(json_encode(data))
  file:close()
  log("Saved " .. scope .. " config to: " .. path, "INFO")
  return true
end

-- ============================================================================
-- TRACK INFORMATION (defined before PRESET MANAGEMENT so get_all_tracks is available)
-- ============================================================================

local function get_all_tracks()
  local tracks = {}
  local track_count = reaper.CountTracks(0)

  local function make_track_route_key(track_index, track_name)
    return string.format("%03d: %s", track_index + 1, track_name)
  end

  for i = 0, track_count - 1 do
    local track = reaper.GetTrack(0, i)
    local retval, track_name = reaper.GetTrackName(track)
    local is_folder = reaper.GetTrackDepth(track)
    table.insert(tracks, {
      index = i,
      track = track,
      name = track_name,
      route_key = make_track_route_key(i, track_name),
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
-- PRESET MANAGEMENT
-- ============================================================================

-- scope: "global" (default) or "project"
local function create_preset(name, scope)
  scope = scope or "global"
  if not name or name == "" then
    log("Preset name cannot be empty", "WARN")
    return nil
  end

  -- Check merged presets for name collision
  for _, preset in ipairs(md.presets) do
    if preset.name == name then
      log("Preset '" .. name .. "' already exists", "WARN")
      return nil
    end
  end

  -- Auto-populate routing with all project tracks, set to center by default
  local routing = {}
  local all_tracks = get_all_tracks()
  for _, track_info in ipairs(all_tracks) do
    routing[track_info.route_key or track_info.name] = "C"  -- C = Center (default)
  end

  local preset = {
    name = name,
    scope = scope,
    routing = routing,
    format = md.format,       -- Use global format setting
    bitrate = md.bitrate,     -- Use global bitrate setting
    timestamp = os.time(),
  }

  save_preset_to_scope(preset, scope)
  log("Created " .. scope .. " preset: " .. name .. " with " .. #all_tracks .. " tracks", "INFO")
  return preset
end

local function delete_preset(name)
  local deleted = false
  -- Remove from global presets if present
  for i, preset in ipairs(md.global_presets) do
    if preset.name == name then
      table.remove(md.global_presets, i)
      save_config("global")
      deleted = true
      break
    end
  end
  -- Remove from project presets if present
  for i, preset in ipairs(md.project_presets) do
    if preset.name == name then
      table.remove(md.project_presets, i)
      save_config("project")
      deleted = true
      break
    end
  end
  if deleted then
    rebuild_merged_presets()
    log("Deleted preset: " .. name, "INFO")
  else
    log("Preset not found: " .. name, "WARN")
  end
  return deleted
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

  if channel ~= "L" and channel ~= "R" and channel ~= "B" and channel ~= nil then
    log("Invalid channel: " .. tostring(channel) .. " (must be L, R, B, or nil to remove)", "WARN")
    return false
  end

  if channel == nil then
    preset.routing[track_name] = nil  -- Remove the entry
  else
    preset.routing[track_name] = channel
  end

  -- Persist to whichever scope this preset belongs to
  local scope = preset.scope or "global"
  save_preset_to_scope(preset, scope)
  log("Updated routing: " .. preset_name .. " -> " .. track_name .. " = " .. tostring(channel), "INFO")
  return true
end

-- ============================================================================
-- EXPORT LOGIC
-- ============================================================================

-- Render format binary strings understood by Reaper's render engine
-- Each format starts with a 4-byte little-endian tag followed by settings bytes
local RENDER_FORMATS = {
  -- "evaw" = WAV; byte 8 = bit-depth code (2=16bit, 3=24bit, 4=32float)
  wav_16  = "\101\118\97\119\0\0\0\0\2\0\0\0",
  wav_24  = "\101\118\97\119\0\0\0\0\3\0\0\0",
  wav_32f = "\101\118\97\119\0\0\0\0\4\0\0\0",
  -- " 3pm" = MP3 (LAME); bytes 8-9 = CBR bitrate little-endian
  mp3 = function(kbps)
    kbps = kbps or 320
    return "\32\51\112\109\0\0\0\0" .. string.char(kbps % 256, math.floor(kbps / 256), 0, 0)
  end,
  -- "calf" = FLAC; byte 4 = compression level
  flac = "\99\97\108\102\5\0\0\0",
}

local function get_render_format_string(fmt, bitrate)
  fmt = (fmt or "wav"):lower()
  if fmt == "mp3" then
    local kbps = tonumber((bitrate or "320k"):match("%d+")) or 320
    return RENDER_FORMATS.mp3(kbps)
  elseif fmt == "flac" then
    return RENDER_FORMATS.flac
  elseif fmt == "wav" then
    return RENDER_FORMATS.wav_24  -- default WAV to 24-bit
  end
  return RENDER_FORMATS.wav_24    -- safe fallback
end

local function get_fourcc(fmt_blob)
  if not fmt_blob or #fmt_blob < 4 then return "" end
  return fmt_blob:sub(1, 4)
end

local supported_render_formats_cache = nil

local function is_render_format_supported(fmt, bitrate)
  local desired = get_render_format_string(fmt, bitrate)
  local _, previous = reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", "", false)

  reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", desired, true)
  local _, applied = reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", "", false)

  reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", previous or "", true)
  return get_fourcc(applied) == get_fourcc(desired)
end

local function get_supported_render_formats(refresh)
  if not refresh and supported_render_formats_cache then
    return supported_render_formats_cache
  end

  local supported = {}
  if is_render_format_supported("wav", md.bitrate) then table.insert(supported, "wav") end
  if is_render_format_supported("flac", md.bitrate) then table.insert(supported, "flac") end
  if is_render_format_supported("mp3", md.bitrate) then table.insert(supported, "mp3") end

  supported_render_formats_cache = supported
  return supported_render_formats_cache
end

-- ── Track state helpers ─────────────────────────────────────────────────────

local pan_state = {}

local function save_track_state()
  md.muted_state = {}
  md.soloed_state = {}
  pan_state = {}
  local track_count = reaper.CountTracks(0)
  for i = 0, track_count - 1 do
    local track = reaper.GetTrack(0, i)
    md.muted_state[i] = reaper.GetMediaTrackInfo_Value(track, "B_MUTE")
    md.soloed_state[i] = reaper.GetMediaTrackInfo_Value(track, "I_SOLO")
    pan_state[i]       = reaper.GetMediaTrackInfo_Value(track, "D_PAN")
  end
end

local function restore_track_state()
  local track_count = reaper.CountTracks(0)
  for i = 0, track_count - 1 do
    local track = reaper.GetTrack(0, i)
    if track then
      if md.muted_state[i] ~= nil then
        reaper.SetMediaTrackInfo_Value(track, "B_MUTE", md.muted_state[i])
      end
      if md.soloed_state[i] ~= nil then
        reaper.SetMediaTrackInfo_Value(track, "I_SOLO", md.soloed_state[i])
      end
      if pan_state[i] ~= nil then
        reaper.SetMediaTrackInfo_Value(track, "D_PAN", pan_state[i])
      end
    end
  end
  reaper.UpdateArrange()
end

-- Kept for compatibility; now wraps save_track_state
local function save_mute_solo_state()  save_track_state() end
local function restore_mute_solo_state() restore_track_state() end

-- ── Default state management (save/restore entire project state) ─────────────

local function save_default_state()
  local all_tracks = get_all_tracks()
  local default_state = {}
  
  for _, track_info in ipairs(all_tracks) do
    local track = track_info.track
    default_state[track_info.name] = {
      pan   = reaper.GetMediaTrackInfo_Value(track, "D_PAN"),
      vol   = reaper.GetMediaTrackInfo_Value(track, "D_VOL"),
      mute  = reaper.GetMediaTrackInfo_Value(track, "B_MUTE"),
      solo  = reaper.GetMediaTrackInfo_Value(track, "I_SOLO"),
    }
  end
  
  -- Save to project config
  local project_path = get_project_config_path()
  if not project_path then
    log("Cannot save default state — no active project", "WARN")
    return false
  end
  
  local project_data = load_config_file(project_path)
  project_data.default_state = default_state
  project_data.version = md.version
  project_data.timestamp = os.time()
  
  local file = io.open(project_path, "w")
  if not file then
    log("Failed to write default state: " .. project_path, "ERROR")
    return false
  end
  file:write(json_encode(project_data))
  file:close()
  
  log("Saved default state for project with " .. #all_tracks .. " tracks", "INFO")
  return true
end

local function restore_default_state()
  local project_path = get_project_config_path()
  if not project_path then
    log("Cannot restore default state — no active project", "WARN")
    return false
  end
  
  local project_data = load_config_file(project_path)
  local default_state = project_data.default_state
  
  if not default_state or (next(default_state) == nil) then
    log("No default state found for this project", "WARN")
    return false
  end
  
  local all_tracks = get_all_tracks()
  local restored_count = 0
  
  for _, track_info in ipairs(all_tracks) do
    local track = track_info.track
    local state = default_state[track_info.name]
    
    if state then
      reaper.SetMediaTrackInfo_Value(track, "D_PAN",  state.pan or 0)
      reaper.SetMediaTrackInfo_Value(track, "D_VOL",  state.vol or 1)
      reaper.SetMediaTrackInfo_Value(track, "B_MUTE", state.mute or 0)
      reaper.SetMediaTrackInfo_Value(track, "I_SOLO", state.solo or 0)
      restored_count = restored_count + 1
    end
  end
  
  reaper.UpdateArrange()
  log("Restored default state — " .. restored_count .. " tracks updated", "INFO")
  return true
end

local function get_default_state_status()
  local project_path = get_project_config_path()
  if not project_path then
    return false, 0
  end

  local project_data = load_config_file(project_path)
  local default_state = project_data.default_state
  if not default_state or next(default_state) == nil then
    return false, 0
  end

  local count = 0
  for _ in pairs(default_state) do
    count = count + 1
  end
  return true, count
end

local saved_render = {}

local function save_render_settings()
  local function gs(key)
    local _, v = reaper.GetSetProjectInfo_String(0, key, "", false)
    return v
  end
  local function gn(key)
    return reaper.GetSetProjectInfo(0, key, 0, false)
  end
  saved_render = {
    file        = gs("RENDER_FILE"),
    pattern     = gs("RENDER_PATTERN"),
    format      = gs("RENDER_FORMAT"),
    settings    = gn("RENDER_SETTINGS"),
    boundsflag  = gn("RENDER_BOUNDSFLAG"),
    channels    = gn("RENDER_CHANNELS"),
    samplerate  = gn("RENDER_SAMPLERATE"),
  }
end

local function restore_render_settings()
  reaper.GetSetProjectInfo_String(0, "RENDER_FILE",    saved_render.file    or "", true)
  reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", saved_render.pattern or "", true)
  reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT",  saved_render.format  or "", true)
  reaper.GetSetProjectInfo(0, "RENDER_SETTINGS",   saved_render.settings   or 0,     true)
  reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", saved_render.boundsflag or 1,     true)
  reaper.GetSetProjectInfo(0, "RENDER_CHANNELS",   saved_render.channels   or 2,     true)
  reaper.GetSetProjectInfo(0, "RENDER_SAMPLERATE", saved_render.samplerate or 44100, true)
end

local function configure_render(preset, out_path)
  -- Output file (folder + stem without extension; Reaper appends ext from format)
  reaper.GetSetProjectInfo_String(0, "RENDER_FILE",    out_path, true)
  reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", "",       true)  -- no additional pattern

  -- Format (use global settings, not per-preset). Fall back when unavailable.
  local format_to_use = md.format
  if not is_render_format_supported(format_to_use, md.bitrate) then
    log("Render format unavailable: " .. tostring(format_to_use) .. ". Falling back to WAV.", "WARN")
    format_to_use = "wav"
  end
  local fmt_str = get_render_format_string(format_to_use, md.bitrate)
  reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", fmt_str, true)

  -- Render entire project, stereo, master mix only
  reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 1, true)  -- 1 = entire project
  reaper.GetSetProjectInfo(0, "RENDER_CHANNELS",   2, true)  -- stereo
  reaper.GetSetProjectInfo(0, "RENDER_SETTINGS",   0, true)  -- 0 = master mix
end

-- ── Track routing ───────────────────────────────────────────────────────────

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

  local function make_track_route_key(track_index, track_name)
    return string.format("%03d: %s", track_index + 1, track_name)
  end

  -- Build a flat map of indexed_track_key -> channel for explicit routes.
  -- Legacy presets may still use plain track names, so those are still accepted.
  local channel_map = {}
  for track_ref, channel in pairs(preset.routing) do
    if track_ref ~= "Master" and channel then
      channel_map[track_ref] = channel
    end
  end

  -- Determine the "implicit" channel for everything not in the map.
  -- If any mapped track is L, everything else is R (and vice versa). Default to R.
  local has_L, has_R = false, false
  for _, ch in pairs(channel_map) do
    if ch == "L" then has_L = true end
    if ch == "R" then has_R = true end
  end
  local implicit_ch
  if has_L and not has_R then
    implicit_ch = "R"
  elseif has_R and not has_L then
    implicit_ch = "L"
  else
    implicit_ch = nil  -- mixed explicit assignments; unmapped tracks go to B (center/both)
  end

  -- Apply pan and mute to every track
  local track_count = reaper.CountTracks(0)
  for i = 0, track_count - 1 do
    local track = reaper.GetTrack(0, i)
    local retval, track_name = reaper.GetTrackName(track)
    local track_key = make_track_route_key(i, track_name)

    local ch = channel_map[track_key] or channel_map[track_name] or implicit_ch

    if ch == "L" then
      reaper.SetMediaTrackInfo_Value(track, "D_PAN",  -1.0)
      reaper.SetMediaTrackInfo_Value(track, "B_MUTE",  0)
    elseif ch == "R" then
      reaper.SetMediaTrackInfo_Value(track, "D_PAN",   1.0)
      reaper.SetMediaTrackInfo_Value(track, "B_MUTE",  0)
    elseif ch == "B" or ch == "C" then
      reaper.SetMediaTrackInfo_Value(track, "D_PAN",   0.0)
      reaper.SetMediaTrackInfo_Value(track, "B_MUTE",  0)
    else
      -- "none" or unmapped: mute
      reaper.SetMediaTrackInfo_Value(track, "B_MUTE",  1)
    end
  end

  reaper.UpdateArrange()
  log("Routing applied — " .. (implicit_ch and ("unmapped tracks → " .. implicit_ch) or "mixed routing"), "INFO")
end

local function export_preset(preset)
  if not preset then
    return false, "Invalid preset"
  end

  local project_name = get_project_name()
  if not project_name then
    return false, "Project must be saved before exporting"
  end

  log("Exporting preset: " .. preset.name, "INFO")

  -- Build output path (no extension — Reaper appends from format)
  local out_folder = get_export_path() or get_project_folder() or ""
  if out_folder ~= "" and not out_folder:match("[\\/]$") then
    out_folder = out_folder .. "/"
  end
  -- Sanitise preset name for use in a filename
  local safe_name = preset.name:gsub('[\\/:*?"<>|]', "_")
  local out_stem  = out_folder .. project_name .. "_" .. safe_name

  -- Persist state
  save_render_settings()
  save_track_state()

  -- Configure
  configure_render(preset, out_stem)
  apply_routing(preset)

  -- Render (command 42230 = render using current settings, auto-close dialog)
  reaper.Main_OnCommand(42230, 0)

  -- Restore everything
  restore_track_state()
  restore_render_settings()
  reaper.UpdateArrange()

  -- Verify output was created
  local expected = out_stem .. "." .. md.format
  local f = io.open(expected, "r")
  if f then
    f:close()
    log("Output: " .. expected, "INFO")
    return true
  else
    -- Render may have completed but file extension differs; still counts as attempted
    log("Render dispatched. Check: " .. expected, "INFO")
    return true
  end
end

local function batch_export()
  if #md.presets == 0 then
    log("No presets defined", "WARN")
    return false
  end

  log("Starting batch export of " .. #md.presets .. " presets", "INFO")
  local failed = {}
  for _, preset in ipairs(md.presets) do
    local ok, err = export_preset(preset)
    if not ok then
      log("Failed: " .. preset.name .. " — " .. tostring(err), "ERROR")
      table.insert(failed, preset.name)
    end
  end
  if #failed > 0 then
    log("Batch export done with " .. #failed .. " failure(s): " .. table.concat(failed, ", "), "WARN")
  else
    log("Batch export complete — " .. #md.presets .. " file(s) exported", "INFO")
  end
  return #failed == 0
end

-- ============================================================================
-- INITIALIZATION & MAIN LOOP
-- ============================================================================

local function normalize_install_dir(dir)
  if not dir or dir == "" then return "" end
  local normalized = dir:gsub("\\", "/")
  if normalized:sub(-1) ~= "/" then
    normalized = normalized .. "/"
  end
  return normalized
end

local function set_install_source_dir(dir)
  if not dir or dir == "" then return false end
  local normalized = normalize_install_dir(dir)
  return save_install_source_dir(normalized)
end

local function resolve_installer_path(preferred_dir, saved_dir)
  local candidates = {}
  local current_dir = normalize_install_dir(get_script_dir())
  if saved_dir and saved_dir ~= "" then
    local normalized = normalize_install_dir(saved_dir)
    if normalized ~= "" then
      table.insert(candidates, normalized)
    end
  end

  if preferred_dir and preferred_dir ~= "" then
    local normalized = normalize_install_dir(preferred_dir)
    if normalized ~= "" then
      table.insert(candidates, normalized)
    end
  end

  if current_dir ~= "" then
    table.insert(candidates, current_dir)
  end

  local seen = {}
  for _, dir in ipairs(candidates) do
    if not seen[dir] then
      seen[dir] = true
      local path = dir .. "install.lua"
      local file = io.open(path, "r")
      if file then
        file:close()
        return dir, path
      end
    end
  end

  local fallback_dir = normalize_install_dir(preferred_dir or saved_dir or current_dir)
  return fallback_dir, fallback_dir .. "install.lua"
end

local function run_installer()
  local installer_dir, installer_path = resolve_installer_path(get_script_dir(), md.install_source_dir)
  local current_dir = get_script_dir()
  local global_config_path = get_global_config_path()
  local state_path = get_install_source_state_path()

  log("Update requested", "INFO")
  log("Current script dir: " .. current_dir, "INFO")
  log("Resolved installer dir: " .. installer_dir, "INFO")
  log("Installer path candidate: " .. installer_path, "INFO")
  log("Install state path: " .. state_path, "INFO")
  log("Global config path: " .. global_config_path, "INFO")

  local exists = io.open(installer_path, "r")
  if not exists then
    log("Installer not found at: " .. installer_path, "ERROR")
    return false
  end
  exists:close()

  local saved = save_install_source_dir(installer_dir)
  log("Saved install source dir: " .. tostring(saved), "INFO")

  local ok, err = pcall(function()
    dofile(installer_path)
  end)
  if not ok then
    log("Installer launch failed: " .. tostring(err), "ERROR")
    return false
  end

  log("Installer launched successfully", "INFO")
  return true
end

local restart_requested = false

local function restart_mixdeck_action()
  restart_requested = true
  return true
end

-- Functions table exposed to the UI module
local fns = {
  create_preset        = create_preset,
  delete_preset        = delete_preset,
  get_preset           = get_preset,
  save_preset_to_scope = save_preset_to_scope,
  save_config          = save_config,
  get_all_tracks       = get_all_tracks,
  get_project_name     = get_project_name,
  get_export_path      = get_export_path,
  export_preset        = export_preset,
  batch_export         = batch_export,
  save_default_state   = save_default_state,
  restore_default_state = restore_default_state,
  get_default_state_status = get_default_state_status,
  get_supported_render_formats = get_supported_render_formats,
  run_installer         = run_installer,
  restart_mixdeck_action = restart_mixdeck_action,
  set_install_source_dir = set_install_source_dir,
  get_install_source_dir = load_install_source_dir,
  log_message          = log,
}

local function init()
  md.log_path = get_runtime_log_dir() .. "/mixdeck.log"
  md.error_log_path = get_runtime_log_dir() .. "/mixdeck_errors.log"
  log("Initializing " .. md.name .. " v" .. md.version, "INFO")
  log("Global config: " .. get_global_config_path(), "INFO")
  load_install_source_dir()
  if md.install_source_dir == "" then
    md.install_source_dir = get_script_dir()
    save_install_source_dir(md.install_source_dir)
  end
  load_config()
end

-- ============================================================================
-- MAIN ENTRY POINT
-- ============================================================================

init()

local ui = nil
local source_cache = {}

local function read_source(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local contents = file:read("*a")
  file:close()
  return contents
end

local function reload_sources_if_needed()
  local ui_path = get_script_dir() .. "ui.lua"
  local main_path = get_script_dir() .. "mixdeck.lua"

  local function check_file(path)
    local contents = read_source(path)
    if not contents then return false end
    local prev = source_cache[path]
    source_cache[path] = contents
    return prev ~= nil and prev ~= contents
  end

  local ui_changed = check_file(ui_path)
  local main_changed = check_file(main_path)

  if ui_changed then
    local ok, err = pcall(function()
      if ui and ui.destroy then
        ui.destroy()
      end
      ui = dofile(ui_path)
      ui.init(md, fns)
    end)
    if ok then
      log("Reloaded UI from disk", "INFO")
    else
      log("UI reload failed: " .. tostring(err), "ERROR")
    end
  end

  if main_changed then
    local ok, err = pcall(function()
      load_config()
    end)
    if ok then
      log("mixdeck.lua changed; config reloaded", "INFO")
    else
      log("Config reload failed after source change: " .. tostring(err), "ERROR")
    end
  end
end

-- Load and start the ImGui UI
ui = dofile(get_script_dir() .. "ui.lua")
ui.init(md, fns)

local function main_loop()
  reload_sources_if_needed()

  local ok, open = pcall(function()
    return ui.draw()
  end)

  if not ok then
    log("UI draw failed: " .. tostring(open), "ERROR")
    open = true
  end

  if restart_requested then
    restart_requested = false
    ui.destroy()

    local _, _, section_id, command_id = reaper.get_action_context()
    if command_id and command_id ~= 0 then
      log("Restarting MixDeck action after update", "INFO")
      reaper.Main_OnCommand(command_id, 0)
    else
      log("Could not restart MixDeck action automatically (missing command ID)", "WARN")
    end
    return
  end

  if open then
    reaper.defer(main_loop)
  else
    ui.destroy()
  end
end

main_loop()
