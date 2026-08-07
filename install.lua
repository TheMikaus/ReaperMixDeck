-- MixDeck Installer
-- Run this script once in Reaper (Actions > Load ReaScript, run it)
-- It will check dependencies and install MixDeck to your Scripts folder.

local MIXDECK_VERSION = "1.3.26"
local REAIMGUI_MIN    = "0.8"

-- ============================================================================
-- HELPERS
-- ============================================================================

local function msg(text)
  reaper.ShowConsoleMsg(text .. "\n")
end

local function reaimgui_installed()
  return reaper.APIExists("ImGui_CreateContext")
end

local function reaimgui_version_ok()
  if not reaper.APIExists("ImGui_GetVersion") then return false end
  local ver = reaper.ImGui_GetVersion()
  -- Compare major.minor only
  local maj, min = ver:match("^(%d+)%.(%d+)")
  local req_maj, req_min = REAIMGUI_MIN:match("^(%d+)%.(%d+)")
  if not maj then return false end
  maj, min       = tonumber(maj), tonumber(min)
  req_maj, req_min = tonumber(req_maj), tonumber(req_min)
  return (maj > req_maj) or (maj == req_maj and min >= req_min)
end

local function reappack_installed()
  return reaper.APIExists("ReaPack_GetOwner")
end

local function has_folder_browser_support()
  local has_js = reaper.APIExists("JS_Dialog_BrowseForFolder")
  local has_sws = reaper.APIExists("CF_DialogBrowseForFolder")
  return has_js or has_sws, has_js, has_sws
end

local function get_script_dir()
  local src = debug.getinfo(1).source
  -- Remove @ prefix if present
  if src:sub(1, 1) == "@" then
    src = src:sub(2)
  end
  -- Get directory and ensure trailing slash
  local dir = src:match("(.*[/\\])")
  return dir or ""
end

local function copy_file(src, dst)
  local f_in = io.open(src, "rb")
  if not f_in then return false, "Cannot read: " .. src end
  local data = f_in:read("*all")
  f_in:close()
  local f_out = io.open(dst, "wb")
  if not f_out then return false, "Cannot write: " .. dst end
  f_out:write(data)
  f_out:close()
  return true
end

-- ============================================================================
-- DEPENDENCY CHECK
-- ============================================================================

local function open_reapck_browser()
  -- Try ReaPack: Browse packages command
  local cmd_id = reaper.NamedCommandLookup("_REAPACK_BROWSE")
  if cmd_id and cmd_id ~= 0 then
    reaper.Main_OnCommand(cmd_id, 0)
    return true
  end
  return false
end

local function check_deps()
  msg("=== MixDeck Installer v" .. MIXDECK_VERSION .. " ===")
  msg("")

  -- Check for ReaPack first (makes ReaImGui installation easier)
  if not reappack_installed() then
    msg("⚠️   ReaPack (package manager) not found.")
    msg("")
    msg("    ReaPack makes installing extensions much easier.")
    msg("    Please install ReaPack first:")
    msg("")
    msg("    1. Download:  https://reapack.com/")
    msg("    2. Extract to: " .. reaper.GetResourcePath() .. "/UserPlugins/")
    msg("    3. Restart Reaper")
    msg("    4. Run this installer again")
    msg("")
    return false
  else
    msg("✅  ReaPack found")
  end

  msg("")

  -- ReaImGui check
  if not reaimgui_installed() then
    msg("❌  ReaImGui NOT found.")
    msg("")
    msg("    MixDeck requires the ReaImGui extension.")
    msg("")
    
    -- Try to open ReaPack browser automatically
    if open_reapck_browser() then
      msg("    ✅ ReaPack browser opened!")
      msg("")
      msg("    Please search for and install ReaImGui:")
      msg("    1. In the browser search box:  ReaImGui")
      msg("    2. Click the ReaImGui entry by cfillion")
      msg("    3. Click 'Install'")
      msg("    4. Restart Reaper")
      msg("    5. Run this installer again")
    else
      msg("    Could not auto-open ReaPack browser.")
      msg("    Please install ReaImGui manually:")
      msg("")
      msg("    Option A: Use ReaPack")
      msg("    1. Open Reaper")
      msg("    2. Press ? to open Actions list")
      msg("    3. Search: 'ReaPack' or 'Browse'")
      msg("    4. Double-click the ReaPack browser command")
      msg("    5. Search for: ReaImGui and Install")
      msg("")
      msg("    Option B: Manual download")
      msg("    1. Download:  https://github.com/cfillion/reaimgui/releases")
      msg("    2. Extract to: " .. reaper.GetResourcePath() .. "/UserPlugins/")
      msg("")
      msg("    After installing ReaImGui:")
      msg("    1. Restart Reaper")
      msg("    2. Run this installer again")
    end
    msg("")
    return false
  end

  if not reaimgui_version_ok() then
    msg("⚠️   ReaImGui found but version may be outdated (need >= " .. REAIMGUI_MIN .. ")")
    msg("    Please update via ReaPack > Synchronize packages")
    msg("    Restart Reaper, then run this installer again")
    msg("")
    return false
  else
    msg("✅  ReaImGui found (v" .. reaper.ImGui_GetVersion() .. ")")
  end

  msg("")
  local has_folder_support, has_js, has_sws = has_folder_browser_support()
  if has_folder_support then
    if has_js then
      msg("✅  Folder browse support: JS_ReaScriptAPI")
    else
      msg("✅  Folder browse support: SWS")
    end
  else
    msg("⚠️   Folder browse support not found.")
    msg("    MixDeck folder Browse buttons require one of:")
    msg("    1. JS_ReaScriptAPI extension (recommended)")
    msg("    2. SWS extension")
    msg("")
    msg("    How to install via ReaPack:")
    msg("    1. Open ReaPack browser")
    msg("    2. Search: JS_ReaScriptAPI  (or SWS)")
    msg("    3. Install, restart Reaper, then run installer again")
    msg("")
    return false
  end

  return true
end

-- ============================================================================
-- INSTALL FILES
-- ============================================================================

local FILES = {
  "mixdeck.lua",
  "ui.lua",
  "install.lua",
  "json_utils.lua",
  "routing_utils.lua",
}

local function install_files()
  local src_dir  = get_script_dir()
  local dst_dir  = reaper.GetResourcePath() .. "/Scripts/MixDeck"

  reaper.RecursiveCreateDirectory(dst_dir, 0)
  msg("📁  Installing to: " .. dst_dir)
  msg("")

  local all_ok = true
  for _, fname in ipairs(FILES) do
    local src  = src_dir .. fname
    local dst  = dst_dir .. "/" .. fname
    local ok, err = copy_file(src, dst)
    if ok then
      msg("  ✅  " .. fname)
    else
      msg("  ❌  " .. fname .. "  —  " .. tostring(err))
      all_ok = false
    end
  end

  -- Also copy default config if it doesn't already exist (don't overwrite user config)
  local cfg_dir = dst_dir .. "/config"
  reaper.RecursiveCreateDirectory(cfg_dir, 0)
  local cfg_dst = cfg_dir .. "/default_config.json"
  local cfg_existing = io.open(cfg_dst, "r")
  if cfg_existing then
    cfg_existing:close()
    msg("  ⏭️   config/default_config.json  (skipped — user config exists)")
  else
    copy_file(src_dir .. "config/default_config.json", cfg_dst)
    msg("  ✅  config/default_config.json  (default template)")
  end

  -- Persist install source directory so Update can re-run install.lua from origin.
  local source_state_path = dst_dir .. "/mixdeck_install_source.txt"
  local source_state = io.open(source_state_path, "w")
  if source_state then
    source_state:write(src_dir)
    source_state:close()
    msg("  ✅  mixdeck_install_source.txt  (installer source saved)")
  else
    msg("  ⚠️   mixdeck_install_source.txt  (failed to save installer source)")
    all_ok = false
  end

  return all_ok, dst_dir
end

-- ============================================================================
-- REGISTER ACTION
-- ============================================================================

local function register_action(install_dir)
  -- Add the main script as a Reaper action so it shows in the Actions list
  local main_script = install_dir .. "/mixdeck.lua"
  local cmd_id = reaper.AddRemoveReaScript(true, 0, main_script, true)
  if cmd_id and cmd_id > 0 then
    msg("")
    msg("✅  Registered as Reaper action  (command ID: " .. cmd_id .. ")")
    msg("")
    msg("  MixDeck is ready! To launch it:")
    msg("  1. Press ? (or go to Actions > Action list)")
    msg("  2. Search: MixDeck")
    msg("  3. Double-click to run")
    msg("")
    msg("  (Optional: Assign a keyboard shortcut for quick access)")
    return cmd_id
  else
    msg("")
    msg("⚠️   Could not auto-register action.")
    msg("    To run MixDeck manually:")
    msg("    Actions > Load ReaScript > " .. main_script)
    return nil
  end
end

-- ============================================================================
-- MAIN
-- ============================================================================

local function run()
  reaper.ClearConsole()

  if not check_deps() then
    return
  end

  local ok, install_dir = install_files()

  if ok then
    register_action(install_dir)
    msg("")
    msg("========================================")
    msg("  MixDeck v" .. MIXDECK_VERSION .. " installed successfully!")
    msg("========================================")
  else
    msg("")
    msg("⚠️  Install completed with errors.")
    msg("   Check messages above for details.")
  end
end

run()
