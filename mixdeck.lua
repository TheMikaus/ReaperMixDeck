-- MixDeck: Export Preset Manager for Reaper
-- Manage multiple export configurations and batch render with custom track routing
-- @author ReaperAutomation
-- @version 1.5.1

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
local installer_utils = dofile(get_script_dir() .. "installer_utils.lua")

local md = {
  version = "1.5.1",
  name = "MixDeck",
  global_presets = {},      -- Presets shared across all projects
  project_presets = {},     -- Presets specific to the current project
  presets = {},             -- Merged view: global + project (read-only, rebuilt on load/save)
  global_export_path = "", -- Common output folder for all projects
  project_export_path = "",-- Per-project output folder override
  project_track_remap = {}, -- Per-project route-key remaps for missing tracks
  global_track_automap = {},-- Global missing-only name-to-name automap
  format = "mp3",           -- Global default format for exports
  bitrate = "320k",         -- Global default bitrate for MP3/OGG
  metronome_in_export = false,    -- Put the click in the rendered files
  metronome_in_recording = false, -- Leave the metronome on for recording
  export_song_as_is = false,      -- Render the untouched mix before the presets
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
  if not proj_path or proj_path == "" then
    return nil
  end
  -- Filename without its extension. Strip only the *last* dot so a project
  -- called "My.Song.rpp" stays "My.Song" instead of collapsing to "My".
  local filename = proj_path:match("([^\\/]+)$")
  if not filename or filename == "" then
    return nil
  end
  local name = filename:match("^(.+)%.[^.]*$") or filename
  if name == "" then
    return nil
  end
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
  if success and type(result) == "table" then
    return result
  end

  -- Unreadable config. Keep a copy rather than letting the next save overwrite
  -- it, so a hand-edit typo or a half-written file is still recoverable.
  log("Failed to parse: " .. path .. " - " .. tostring(result), "ERROR")
  local backup = path .. ".corrupt"
  os.remove(backup)
  if os.rename(path, backup) then
    log("Moved unreadable config aside: " .. backup, "WARN")
  end
  return {}
end

-- Write JSON via a temp file so an interrupted save cannot leave a half-written
-- config behind (which used to be unparseable and took Reaper down with it).
local function write_json_file(path, tbl)
  local encoded_ok, encoded = pcall(json_encode, tbl)
  if not encoded_ok then
    log("Failed to encode config for " .. path .. ": " .. tostring(encoded), "ERROR")
    return false
  end

  local tmp_path = path .. ".tmp"
  local file = io.open(tmp_path, "w")
  if not file then
    log("Failed to open config for writing: " .. tmp_path, "ERROR")
    return false
  end
  file:write(encoded)
  file:close()

  os.remove(path)  -- os.rename will not clobber an existing file on Windows
  local renamed, rename_err = os.rename(tmp_path, path)
  if not renamed then
    log("Failed to move config into place: " .. tostring(rename_err), "ERROR")
    os.remove(tmp_path)
    return false
  end
  return true
end

-- Merge `updates` into whatever is already on disk and write the result back.
-- Config files are shared between concerns (presets, export path, format,
-- remaps, default state), so a blind full-file write would drop the keys the
-- caller does not know about.
local function update_config_file(path, updates)
  if not path then return false end
  local data = load_config_file(path)
  for key, value in pairs(updates) do
    data[key] = value
  end
  data.version = md.version
  data.timestamp = os.time()
  return write_json_file(path, data)
end

local function load_config()
  -- Load global config (presets + global export path + format settings)
  local global_path = get_global_config_path()
  local global_data = load_config_file(global_path)
  md.global_presets = global_data.presets or {}
  md.global_export_path = global_data.export_path or ""
  md.global_track_automap = global_data.track_automap or {}
  md.format = global_data.format or "mp3"
  md.bitrate = global_data.bitrate or "320k"
  md.metronome_in_export = global_data.metronome_in_export == true
  md.metronome_in_recording = global_data.metronome_in_recording == true
  md.export_song_as_is = global_data.export_song_as_is == true
  log("Loaded " .. #md.global_presets .. " global presets from: " .. global_path, "INFO")

  -- Load project config (presets + project export path override)
  local project_path = get_project_config_path()
  if project_path then
    local project_data = load_config_file(project_path)
    md.project_presets = project_data.presets or {}
    md.project_export_path = project_data.export_path or ""
    md.project_track_remap = project_data.track_remap or {}
    log("Loaded " .. #md.project_presets .. " project presets from: " .. project_path, "INFO")
  else
    md.project_presets = {}
    md.project_export_path = ""
    md.project_track_remap = {}
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

  if not update_config_file(path, { presets = target }) then
    log("Failed to write " .. scope .. " config: " .. path, "ERROR")
    return false
  end

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
  local updates = {
    presets = target,
    export_path = export_path_val,
  }
  -- Format/bitrate are global-only settings; remaps differ per scope.
  if scope == "global" then
    updates.format = md.format
    updates.bitrate = md.bitrate
    updates.metronome_in_export = md.metronome_in_export == true
    updates.metronome_in_recording = md.metronome_in_recording == true
    updates.export_song_as_is = md.export_song_as_is == true
    updates.track_automap = md.global_track_automap or {}
  else
    updates.track_remap = md.project_track_remap or {}
  end

  if not update_config_file(path, updates) then
    log("Failed to open config for writing: " .. path, "ERROR")
    return false
  end
  log("Saved " .. scope .. " config to: " .. path, "INFO")
  return true
end

-- ============================================================================
-- TRACK INFORMATION (defined before PRESET MANAGEMENT so get_all_tracks is available)
-- ============================================================================

local function get_all_tracks()
  local tracks = {}
  local track_count = reaper.CountTracks(0)
  local parent_stack = {}

  local function make_track_route_key(parent_name, track_name)
    local parent_part = parent_name or "<ROOT>"
    return parent_part .. " > " .. track_name
  end

  for i = 0, track_count - 1 do
    local track = reaper.GetTrack(0, i)
    local retval, track_name = reaper.GetTrackName(track)
    local depth = reaper.GetTrackDepth(track)
    local parent_name = parent_stack[depth - 1]

    local clear_depth = depth
    while parent_stack[clear_depth] do
      parent_stack[clear_depth] = nil
      clear_depth = clear_depth + 1
    end

    parent_stack[depth] = track_name

    table.insert(tracks, {
      index = i,
      track = track,
      name = track_name,
      parent_name = parent_name,
      route_key = make_track_route_key(parent_name, track_name),
      is_folder = depth,
    })
  end
  return tracks
end

local function build_track_key_lookup()
  local lookup = {}
  local lookup_lc = {}
  local tracks = get_all_tracks()
  for _, track_info in ipairs(tracks) do
    lookup[track_info.route_key] = true
    lookup[track_info.name] = true
    lookup_lc[string.lower(track_info.route_key)] = track_info.route_key
    lookup_lc[string.lower(track_info.name)] = track_info.name
  end
  return lookup, lookup_lc, tracks
end

local function extract_track_name_from_key(route_key)
  if not route_key then return "" end
  local txt = tostring(route_key)
  local rhs = txt:match("^.*%s>%s(.+)$")
  if rhs and rhs ~= "" then
    return rhs
  end
  local legacy = txt:match("^%d+:%s*(.+)$")
  if legacy and legacy ~= "" then
    return legacy
  end
  return txt
end

local function get_missing_tracks_for_preset(preset)
  local missing = {}
  if not preset or not preset.routing then
    return missing
  end

  local lookup, lookup_lc = build_track_key_lookup()
  for source_key, _ in pairs(preset.routing) do
    if source_key ~= "Master" then
      local mapped = (md.project_track_remap and md.project_track_remap[source_key]) or source_key
      local mapped_lc = string.lower(tostring(mapped))
      local resolved_ok = lookup[mapped] or lookup_lc[mapped_lc]

      if not resolved_ok then
        local source_name = extract_track_name_from_key(source_key)
        local source_name_lc = string.lower(source_name)
        local auto_target_name = (md.global_track_automap and md.global_track_automap[source_name_lc]) or ""
        if auto_target_name ~= "" then
          local auto_target_lc = string.lower(auto_target_name)
          resolved_ok = lookup[auto_target_name] or lookup_lc[auto_target_lc]
        end
      end

      if not resolved_ok then
        table.insert(missing, {
          source_key = source_key,
          mapped_key = (md.project_track_remap and md.project_track_remap[source_key]) or "",
        })
      end
    end
  end

  table.sort(missing, function(a, b)
    return tostring(a.source_key) < tostring(b.source_key)
  end)

  return missing
end

-- Forward declaration: get_preset is defined under PRESET MANAGEMENT below, but
-- is called from here. Without this the call would resolve to a nil global.
local get_preset

local function remove_track_from_preset(preset_name, route_key)
  local preset = get_preset(preset_name)
  if not preset or not preset.routing then
    log("Cannot remove track from preset — preset not found: " .. tostring(preset_name), "WARN")
    return false
  end

  local removed = false
  if preset.routing[route_key] ~= nil then
    preset.routing[route_key] = nil
    removed = true
  else
    local route_key_lc = string.lower(tostring(route_key or ""))
    for existing_key, _ in pairs(preset.routing) do
      if string.lower(tostring(existing_key)) == route_key_lc then
        preset.routing[existing_key] = nil
        removed = true
        break
      end
    end
  end

  if not removed then
    log("Track route key not found in preset: " .. tostring(route_key), "WARN")
    return false
  end

  local scope = preset.scope or "global"
  local ok = save_preset_to_scope(preset, scope)
  if ok then
    log("Removed route from preset: " .. tostring(route_key), "INFO")
  end
  return ok
end

local function set_permanent_track_automap(source_key, target_key)
  local source_name = extract_track_name_from_key(source_key)
  local source_name_lc = string.lower(source_name or "")
  if source_name_lc == "" then
    return false
  end

  md.global_track_automap = md.global_track_automap or {}

  if not target_key or target_key == "" then
    md.global_track_automap[source_name_lc] = nil
  else
    local target_name = extract_track_name_from_key(target_key)
    if not target_name or target_name == "" then
      return false
    end
    md.global_track_automap[source_name_lc] = target_name
  end

  return save_config("global")
end

local function get_project_track_remap_target(source_key)
  if not md.project_track_remap then return "" end
  return md.project_track_remap[source_key] or ""
end

local function set_project_track_remap(source_key, target_key)
  if not source_key or source_key == "" then return false end
  if not get_project_config_path() then
    log("Cannot save track remap — no active project", "WARN")
    return false
  end

  md.project_track_remap = md.project_track_remap or {}
  if not target_key or target_key == "" then
    md.project_track_remap[source_key] = nil
  else
    md.project_track_remap[source_key] = target_key
  end

  return save_config("project")
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

function get_preset(name)
  for _, preset in ipairs(md.presets) do
    if preset.name == name then
      return preset
    end
  end
  return nil
end

-- Move a preset to a new position in the merged list. The order has to be
-- written back to the scope list the preset actually lives in, otherwise it is
-- lost the next time the merged view is rebuilt.
--
-- Note: the merged view is always global presets first, then project presets,
-- so a move across that boundary snaps back to the scope grouping on reload.
-- Ordering within a scope is preserved.
local function reorder_preset(preset_name, to_index)
  to_index = math.floor(tonumber(to_index) or 0)
  if to_index < 1 or to_index > #md.presets then
    log("Reorder target out of range: " .. tostring(to_index), "WARN")
    return false
  end

  local from_index = nil
  for i, preset in ipairs(md.presets) do
    if preset.name == preset_name then
      from_index = i
      break
    end
  end
  if not from_index then
    log("Cannot reorder — preset not found: " .. tostring(preset_name), "WARN")
    return false
  end
  if from_index == to_index then
    return true
  end

  local moved = table.remove(md.presets, from_index)
  table.insert(md.presets, to_index, moved)

  -- Rewrite each scope list in the merged order so the change survives a reload.
  local scope = moved.scope or "global"
  local target = (scope == "project") and md.project_presets or md.global_presets
  local reordered = {}
  for _, preset in ipairs(md.presets) do
    for _, candidate in ipairs(target) do
      if candidate.name == preset.name then
        reordered[#reordered + 1] = candidate
        break
      end
    end
  end
  for i = 1, math.max(#target, #reordered) do
    target[i] = reordered[i]
  end

  local saved = save_config(scope)
  if saved then
    rebuild_merged_presets()
    log("Reordered preset '" .. tostring(preset_name) .. "' to position " .. to_index, "INFO")
  end
  return saved
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

-- ── Metronome ───────────────────────────────────────────────────────────────
--
-- 40364 is "Options: Toggle metronome". It is a toggle rather than a setter, so
-- the state is read first and the command only fired when it needs to change.
--
-- Whether the click actually lands in a rendered file depends on the metronome
-- being routed to the master, which is Reaper's default but can be changed in
-- the metronome settings. If a render comes out silent on the click, that
-- routing is the thing to check.
local METRONOME_TOGGLE_COMMAND = 40364

local function get_metronome_enabled()
  if not reaper.GetToggleCommandState then return nil end
  local state = reaper.GetToggleCommandState(METRONOME_TOGGLE_COMMAND)
  if state == -1 then return nil end
  return state == 1
end

-- Returns the previous state so a caller can put it back, or nil when the
-- state could not be read on this build.
local function set_metronome_enabled(enabled)
  local previous = get_metronome_enabled()
  if previous == nil then
    log("Metronome state unavailable on this Reaper build", "WARN")
    return nil
  end
  if previous ~= (enabled == true) then
    reaper.Main_OnCommand(METRONOME_TOGGLE_COMMAND, 0)
    log("Metronome " .. ((enabled == true) and "enabled" or "disabled"), "INFO")
  end
  return previous
end

-- Turn the metronome on (or off) and leave it that way, for tracking takes.
local function set_metronome_for_recording(enabled)
  md.metronome_in_recording = enabled == true
  set_metronome_enabled(md.metronome_in_recording)
  save_config("global")
  return md.metronome_in_recording
end

-- ── Click track ─────────────────────────────────────────────────────────────
--
-- Enabling the transport metronome does NOT reliably put a click in a render:
-- it is a monitoring feature, and whether it reaches the master depends on the
-- user's metronome output routing. The renderable equivalent is Reaper's click
-- *source* -- the same thing Insert > Click source creates -- which is a real
-- media item on a real track and renders like any other audio.
--
-- So the export click is a temporary track carrying a click item, added after
-- routing has been applied (so routing does not mute or pan it) and removed
-- again before the track state is restored.

local CLICK_TRACK_NAME = "MixDeck Click"

local function create_click_source()
  if not reaper.PCM_Source_CreateFromType then return nil end

  for _, type_name in ipairs({ "click", "CLICK" }) do
    local ok, source = pcall(reaper.PCM_Source_CreateFromType, type_name)
    if ok and source then
      -- Confirm what came back really is a click source rather than an empty
      -- one, so a wrong type string fails loudly instead of rendering silence.
      if not reaper.GetMediaSourceType then
        return source
      end
      -- Builds differ in whether this returns just the type string or a
      -- (retval, string) pair, so check whichever of the two is the string.
      local typed, first, second = pcall(reaper.GetMediaSourceType, source, "")
      local kind = tostring(second or first or "")
      if typed and kind:upper():find("CLICK", 1, true) then
        return source
      end
      if reaper.PCM_Source_Destroy then
        pcall(reaper.PCM_Source_Destroy, source)
      end
    end
  end
  return nil
end

-- Whether this Reaper build can give us a renderable click at all. The UI asks
-- before offering the option, so the answer arrives before an export, not after.
local function click_source_available()
  local source = create_click_source()
  if not source then return false end
  if reaper.PCM_Source_Destroy then
    pcall(reaper.PCM_Source_Destroy, source)
  end
  return true
end

local function get_project_length()
  if reaper.GetProjectLength then
    local length = reaper.GetProjectLength(0)
    if length and length > 0 then return length end
  end
  return 0
end

-- Appends the click track at the end, so the indices used by save_track_state /
-- restore_track_state still line up.
local function add_click_track()
  local source = create_click_source()
  if not source then
    return nil, "This Reaper build did not provide a click source"
  end

  local length = get_project_length()
  if length <= 0 then
    return nil, "Project has no length to lay a click over"
  end

  local index = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(index, false)
  local track = reaper.GetTrack(0, index)
  if not track then
    return nil, "Could not create the click track"
  end

  reaper.GetSetMediaTrackInfo_String(track, "P_NAME", CLICK_TRACK_NAME, true)

  local item = reaper.AddMediaItemToTrack(track)
  local take = item and reaper.AddTakeToMediaItem(item)
  if not take then
    reaper.DeleteTrack(track)
    return nil, "Could not create the click item"
  end

  reaper.SetMediaItemTake_Source(take, source)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", 0)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", length)

  log("Click track added for render (" .. string.format("%.2f", length) .. "s)", "INFO")
  return track
end

local function remove_click_track(track)
  if not track then return end
  pcall(function()
    reaper.DeleteTrack(track)
  end)
end


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

-- Probing a format means writing it to the project and reading back what stuck,
-- so the previous value is always put back — including if the round trip throws.
local function is_render_format_supported(fmt, bitrate)
  local desired = get_render_format_string(fmt, bitrate)
  local _, previous = reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", "", false)

  local ok, applied = pcall(function()
    reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", desired, true)
    local _, current = reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", "", false)
    return current
  end)

  reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", previous or "", true)

  if not ok then
    log("Render format probe failed for " .. tostring(fmt) .. ": " .. tostring(applied), "WARN")
    return false
  end
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

-- ── Default state management (save/restore entire project state) ─────────────

local function save_default_state()
  local project_path = get_project_config_path()
  if not project_path then
    log("Cannot save default state — no active project", "WARN")
    return false
  end

  -- Keyed by route key, not bare name: duplicate track names are routine in
  -- Reaper, and name keys silently collapsed them into one entry.
  local all_tracks = get_all_tracks()
  local default_state = {}
  for _, track_info in ipairs(all_tracks) do
    local track = track_info.track
    default_state[track_info.route_key] = {
      name  = track_info.name,
      pan   = reaper.GetMediaTrackInfo_Value(track, "D_PAN"),
      vol   = reaper.GetMediaTrackInfo_Value(track, "D_VOL"),
      mute  = reaper.GetMediaTrackInfo_Value(track, "B_MUTE"),
      solo  = reaper.GetMediaTrackInfo_Value(track, "I_SOLO"),
    }
  end

  if not update_config_file(project_path, { default_state = default_state }) then
    log("Failed to write default state: " .. project_path, "ERROR")
    return false
  end

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
    -- Route key first; fall back to the bare name for states saved before
    -- route keys existed.
    local state = default_state[track_info.route_key] or default_state[track_info.name]

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

local function configure_render(out_folder, out_pattern)
  -- Output file setup:
  -- RENDER_FILE is the destination folder, and RENDER_PATTERN is the base filename.
  -- This avoids REAPER interpreting the intended stem as an extra subfolder.
  reaper.GetSetProjectInfo_String(0, "RENDER_FILE",    out_folder, true)
  reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", out_pattern, true)

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

  -- Caller needs the real extension to verify the output.
  return format_to_use
end

-- ── Track routing ───────────────────────────────────────────────────────────

local function apply_routing(preset)
  log("Applying routing for preset: " .. preset.name, "INFO")

  local function make_track_route_key(parent_name, track_name)
    local parent_part = parent_name or "<ROOT>"
    return parent_part .. " > " .. track_name
  end

  -- Build a flat map of indexed_track_key -> channel for explicit routes.
  -- Legacy presets may still use plain track names, so those are still accepted.
  local channel_map = {}
  local channel_map_lc = {}

  local track_lookup, track_lookup_lc = build_track_key_lookup()

  for track_ref, channel in pairs(preset.routing) do
    if track_ref ~= "Master" and channel then
      local mapped_ref = (md.project_track_remap and md.project_track_remap[track_ref]) or track_ref
      local canonical = track_lookup_lc[string.lower(tostring(mapped_ref))] or mapped_ref

      if not track_lookup[canonical] and not track_lookup_lc[string.lower(tostring(canonical))] then
        local source_name = extract_track_name_from_key(track_ref)
        local auto_target_name = (md.global_track_automap and md.global_track_automap[string.lower(source_name)]) or ""
        if auto_target_name ~= "" then
          local auto_canonical = track_lookup_lc[string.lower(auto_target_name)] or auto_target_name
          if track_lookup[auto_canonical] or track_lookup_lc[string.lower(tostring(auto_canonical))] then
            canonical = auto_canonical
          end
        end
      end

      channel_map[canonical] = channel
      channel_map_lc[string.lower(tostring(canonical))] = channel
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
  local tracks = get_all_tracks()
  for _, track_info in ipairs(tracks) do
    local track = track_info.track
    local track_name = track_info.name
    local track_key = make_track_route_key(track_info.parent_name, track_name)

    local ch = channel_map[track_key]
      or channel_map[track_name]
      or channel_map_lc[string.lower(track_key)]
      or channel_map_lc[string.lower(track_name)]
      or implicit_ch

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

-- Shared render machinery for both the preset exports and the as-is pass.
--
-- `prepare` is called inside the protected section to set the project up for
-- this particular render (routing, for a preset) and may be nil for a render of
-- the mix exactly as it stands. Everything it touches is restored afterwards,
-- including on failure.
local function render_project(out_folder, out_pattern, label, prepare)
  save_render_settings()
  save_track_state()

  reaper.Undo_BeginBlock()
  local format_used = md.format
  local click_track = nil
  local click_error = nil

  local ok, err = pcall(function()
    format_used = configure_render(out_folder, out_pattern)
    if prepare then prepare() end

    -- After routing, so the click is not muted or panned along with everything
    -- else, and appended last so track indices stay stable for the restore.
    if md.metronome_in_export then
      click_track, click_error = add_click_track()
      if not click_track then
        log("Export click unavailable: " .. tostring(click_error), "ERROR")
      end
    end

    -- 42230 = render using current settings, auto-close the dialog
    reaper.Main_OnCommand(42230, 0)
  end)

  -- Remove the click track before restoring, so the restore sees the project
  -- exactly as it was snapshotted.
  remove_click_track(click_track)
  restore_track_state()
  restore_render_settings()
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("MixDeck: Export " .. tostring(label), -1)

  if not ok then
    log("Export failed for '" .. tostring(label) .. "': " .. tostring(err), "ERROR")
    return false, "Render failed: " .. tostring(err)
  end

  -- Verify the file actually landed, using the format the render really used
  -- (configure_render falls back to WAV when a format is unavailable).
  local expected = out_folder .. "/" .. out_pattern .. "." .. format_used
  local f = io.open(expected, "r")
  if f then
    f:close()
    log("Output: " .. expected, "INFO")
    return true
  end

  log("No output file found after render: " .. expected, "ERROR")
  return false, "No output file was produced at " .. expected
end

local function get_export_root()
  local out_folder = get_export_path() or get_project_folder() or ""
  if out_folder ~= "" and not out_folder:match("[\\/]$") then
    out_folder = out_folder .. "/"
  end
  return out_folder
end

local function sanitize_filename(text)
  return tostring(text or ""):gsub('[\\/:*?"<>|]', "_")
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

  -- {export_folder}/{preset_name}/{project-name}-{preset_name}.{ext}
  local safe_project = sanitize_filename(project_name)
  local safe_preset = sanitize_filename(preset.name)
  local preset_dir = get_export_root() .. safe_preset
  reaper.RecursiveCreateDirectory(preset_dir, 0)

  return render_project(preset_dir, safe_project .. "-" .. safe_preset, preset.name, function()
    apply_routing(preset)
  end)
end

-- Render the mix exactly as it stands: no routing, no muting, nothing touched.
-- Lands beside the preset folders rather than inside one, because it is not a
-- preset.
local function export_song_as_is()
  local project_name = get_project_name()
  if not project_name then
    return false, "Project must be saved before exporting"
  end

  log("Exporting song as-is", "INFO")

  local out_dir = get_export_root()
  if out_dir ~= "" then
    -- Strip the trailing separator: RENDER_FILE wants the folder itself.
    out_dir = out_dir:sub(1, -2)
  end
  if out_dir == "" then
    return false, "No export folder is configured"
  end
  reaper.RecursiveCreateDirectory(out_dir, 0)

  return render_project(out_dir, sanitize_filename(project_name), "song as-is", nil)
end

local function batch_export()
  if #md.presets == 0 and not md.export_song_as_is then
    log("No presets defined", "WARN")
    return false
  end

  log("Starting batch export of " .. #md.presets .. " presets", "INFO")
  local failed = {}

  -- The untouched mix goes first, so the reference file exists even if a preset
  -- later fails.
  if md.export_song_as_is then
    local ok, err = export_song_as_is()
    if not ok then
      log("Failed: song as-is — " .. tostring(err), "ERROR")
      failed[#failed + 1] = "song as-is"
    end
  end

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
  return installer_utils.normalize_install_dir(dir)
end

local function set_install_source_dir(dir)
  if not dir or dir == "" then return false end
  local normalized = normalize_install_dir(dir)
  return save_install_source_dir(normalized)
end

local function resolve_installer_path(preferred_dir, saved_dir)
  return installer_utils.resolve_installer_path(preferred_dir, saved_dir)
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
  reorder_preset       = reorder_preset,
  update_preset_routing = update_preset_routing,
  save_preset_to_scope = save_preset_to_scope,
  save_config          = save_config,
  load_config          = load_config,
  get_all_tracks       = get_all_tracks,
  get_project_name     = get_project_name,
  get_export_path      = get_export_path,
  export_preset        = export_preset,
  export_song_as_is    = export_song_as_is,
  get_metronome_enabled = get_metronome_enabled,
  click_source_available = click_source_available,
  set_metronome_enabled = set_metronome_enabled,
  set_metronome_for_recording = set_metronome_for_recording,
  batch_export         = batch_export,
  save_default_state   = save_default_state,
  restore_default_state = restore_default_state,
  get_default_state_status = get_default_state_status,
  get_supported_render_formats = get_supported_render_formats,
  get_missing_tracks_for_preset = get_missing_tracks_for_preset,
  get_project_track_remap_target = get_project_track_remap_target,
  set_project_track_remap = set_project_track_remap,
  remove_track_from_preset = remove_track_from_preset,
  set_permanent_track_automap = set_permanent_track_automap,
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
