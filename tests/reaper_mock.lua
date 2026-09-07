-- reaper_mock.lua — a fake `reaper` API good enough to load and drive mixdeck.lua
-- outside of Reaper. Tests build a project with RMOCK.add_track / RMOCK.set_project,
-- call into the real code, then assert against RMOCK state.
--
-- The host (conftest.py) must provide __host_mkdir(path) before this is loaded,
-- since Lua has no directory-creation primitive.

local RMOCK = {
  resource_path = "",
  project_path = "",
  tracks = {},
  project_info_str = {},
  project_info_num = {},
  commands = {},
  deferred = nil,
  render_hook = nil,      -- function(RMOCK) called on the render command
  updates = 0,
  metronome_on = false,
  metronome_toggles = 0,
  project_length = 120.0,
  -- Set false to model a build with no click source available.
  click_source_supported = true,
  action_command_id = 1234,
}

local RENDER_COMMAND = 42230
local METRONOME_TOGGLE = 40364

function RMOCK.reset()
  RMOCK.project_path = ""
  RMOCK.tracks = {}
  RMOCK.project_info_str = {}
  RMOCK.project_info_num = {}
  RMOCK.commands = {}
  RMOCK.renders = {}
  RMOCK.deferred = nil
  RMOCK.render_hook = nil
  RMOCK.updates = 0
  RMOCK.metronome_on = false
  RMOCK.metronome_toggles = 0
  RMOCK.click_source_supported = true
end

function RMOCK.set_project(path)
  RMOCK.project_path = path or ""
end

-- spec: { name = "Kick", depth = 1, pan = 0, vol = 1, mute = 0, solo = 0 }
function RMOCK.add_track(spec)
  local track = {
    name  = spec.name or ("Track " .. tostring(#RMOCK.tracks + 1)),
    depth = spec.depth or 0,
    pan   = spec.pan or 0.0,
    vol   = spec.vol or 1.0,
    mute  = spec.mute or 0,
    solo  = spec.solo or 0,
    guid  = spec.guid or ("{GUID-" .. tostring(#RMOCK.tracks + 1) .. "}"),
    items = spec.items or 0,
  }
  RMOCK.tracks[#RMOCK.tracks + 1] = track
  return track
end

function RMOCK.find_track(name)
  for _, t in ipairs(RMOCK.tracks) do
    if t.name == name then return t end
  end
  return nil
end

-- Snapshot of every track's mixer state, for asserting restore-after-export.
function RMOCK.mixer_state()
  local state = {}
  for i, t in ipairs(RMOCK.tracks) do
    state[i] = { name = t.name, pan = t.pan, vol = t.vol, mute = t.mute, solo = t.solo }
  end
  return state
end

local reaper = {}

function reaper.GetResourcePath()
  return RMOCK.resource_path
end

function reaper.EnumProjects(idx)
  return 0, RMOCK.project_path
end

function reaper.RecursiveCreateDirectory(path, _)
  __host_mkdir(path)
  return 1
end

function reaper.CountTracks(_)
  return #RMOCK.tracks
end

function reaper.GetTrack(_, i)
  return RMOCK.tracks[i + 1]
end

function reaper.GetTrackName(track)
  if not track then return false, "" end
  return true, track.name
end

function reaper.GetTrackDepth(track)
  return track and track.depth or 0
end

function reaper.GetTrackGUID(track)
  return track and track.guid or ""
end

function reaper.CountTrackMediaItems(track)
  return track and track.items or 0
end

local TRACK_KEYS = {
  D_PAN = "pan", D_VOL = "vol", B_MUTE = "mute", I_SOLO = "solo",
}

function reaper.GetMediaTrackInfo_Value(track, key)
  if not track then return 0 end
  if key == "I_FOLDERDEPTH" then return track.folder_depth or 0 end
  local field = TRACK_KEYS[key]
  if not field then return 0 end
  return track[field]
end

function reaper.SetMediaTrackInfo_Value(track, key, value)
  if not track then return false end
  local field = TRACK_KEYS[key]
  if not field then return false end
  track[field] = value
  return true
end

function reaper.GetSetMediaTrackInfo_String(track, key, value, is_set)
  if key ~= "P_NAME" then return false, "" end
  if is_set then
    track.name = value
    return true, value
  end
  return true, track.name
end

function reaper.GetSetProjectInfo_String(_, key, value, is_set)
  if is_set then
    RMOCK.project_info_str[key] = value
    return true, value
  end
  return true, RMOCK.project_info_str[key] or ""
end

function reaper.GetSetProjectInfo(_, key, value, is_set)
  if is_set then
    RMOCK.project_info_num[key] = value
    return value
  end
  return RMOCK.project_info_num[key] or 0
end

function reaper.Main_OnCommand(cmd, _)
  RMOCK.commands[#RMOCK.commands + 1] = cmd
  if cmd == METRONOME_TOGGLE then
    RMOCK.metronome_on = not RMOCK.metronome_on
    RMOCK.metronome_toggles = RMOCK.metronome_toggles + 1
  end
  if cmd == RENDER_COMMAND then
    -- Record whether the click was live at the moment of each render.
    RMOCK.renders = RMOCK.renders or {}
    RMOCK.renders[#RMOCK.renders + 1] = {
      folder = RMOCK.project_info_str["RENDER_FILE"],
      pattern = RMOCK.project_info_str["RENDER_PATTERN"],
      metronome_on = RMOCK.metronome_on,
      click_track = RMOCK.find_click_track() ~= nil,
      track_count = #RMOCK.tracks,
    }
    if RMOCK.render_hook then
      RMOCK.render_hook(RMOCK)
    end
  end
end

function reaper.GetToggleCommandState(cmd)
  if cmd == METRONOME_TOGGLE then
    return RMOCK.metronome_on and 1 or 0
  end
  return -1
end

function reaper.UpdateArrange()
  RMOCK.updates = RMOCK.updates + 1
end

function reaper.TrackList_AdjustWindows(_) end

function reaper.Undo_BeginBlock()
  RMOCK.undo_depth = (RMOCK.undo_depth or 0) + 1
end

function reaper.Undo_EndBlock(name, _)
  RMOCK.undo_depth = (RMOCK.undo_depth or 0) - 1
  RMOCK.last_undo_name = name
end

function reaper.defer(fn)
  -- Record but never run: the real main_loop would recurse forever.
  RMOCK.deferred = fn
end

function reaper.get_action_context()
  return false, "", 0, RMOCK.action_command_id
end

function reaper.ShowConsoleMsg(_) end

function reaper.APIExists(name)
  return reaper[name] ~= nil
end

-- ── Click source / items / track insert ─────────────────────────────────────

function RMOCK.find_click_track()
  for _, t in ipairs(RMOCK.tracks) do
    if t.name == "MixDeck Click" then return t end
  end
  return nil
end

function reaper.GetProjectLength(_)
  return RMOCK.project_length
end

function reaper.PCM_Source_CreateFromType(sourcetype)
  if not RMOCK.click_source_supported then return nil end
  -- Only the click type is modelled; anything else comes back as an empty
  -- source, which is what the real API does for an unknown type.
  local lowered = tostring(sourcetype or ""):lower()
  if lowered == "click" then
    return { kind = "CLICK" }
  end
  return { kind = "EMPTY" }
end

function reaper.GetMediaSourceType(source, _)
  if not source then return "" end
  return source.kind or "EMPTY"
end

function reaper.PCM_Source_Destroy(_) end

function reaper.InsertTrackAtIndex(index, _)
  local track = {
    name = "Track " .. tostring(index + 1),
    depth = 0, pan = 0.0, vol = 1.0, mute = 0, solo = 0,
    guid = "{GUID-INSERTED-" .. tostring(index + 1) .. "}",
    items = 0, media_items = {},
  }
  table.insert(RMOCK.tracks, index + 1, track)
  return track
end

function reaper.DeleteTrack(track)
  for i, t in ipairs(RMOCK.tracks) do
    if t == track then
      table.remove(RMOCK.tracks, i)
      return true
    end
  end
  return false
end

function reaper.AddMediaItemToTrack(track)
  if not track then return nil end
  track.media_items = track.media_items or {}
  local item = { track = track, take = nil, position = 0, length = 0 }
  track.media_items[#track.media_items + 1] = item
  return item
end

function reaper.AddTakeToMediaItem(item)
  if not item then return nil end
  item.take = { item = item, source = nil }
  return item.take
end

function reaper.SetMediaItemTake_Source(take, source)
  if take then take.source = source end
end

local ITEM_KEYS = { D_POSITION = "position", D_LENGTH = "length" }

function reaper.SetMediaItemInfo_Value(item, key, value)
  if not item then return false end
  local field = ITEM_KEYS[key]
  if not field then return false end
  item[field] = value
  return true
end

function reaper.GetMediaItemInfo_Value(item, key)
  if not item then return 0 end
  local field = ITEM_KEYS[key]
  return field and item[field] or 0
end

_G.reaper = reaper
return RMOCK
