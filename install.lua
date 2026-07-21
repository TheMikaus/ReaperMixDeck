-- MixDeck Installer
-- Run this script once in Reaper (Actions > Load ReaScript, run it)
-- It will check dependencies and install MixDeck to your Scripts folder.

local MIXDECK_VERSION = "1.0.0"
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

local function get_script_dir()
  return debug.getinfo(1).source:match("@?(.*/?)") or ""
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
  -- Try known ReaPack command IDs
  local cmd_ids = {
    "_REAPK_BROWSEPKGS",  -- ReaPack: Browse packages (most common)
    "_REAPK_FETCH",       -- Alternative name
  }
  
  for _, cmd_name in ipairs(cmd_ids) do
    local cmd_id = reaper.NamedCommandLookup(cmd_name)
    if cmd_id and cmd_id ~= 0 then
      msg("    (Opening ReaPack browser...)")
      reaper.Main_OnCommand(cmd_id, 0)
      return true
    end
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
      msg("    ReaPack browser is now open.")
      msg("")
      msg("    In the browser:")
      msg("    1. Search for:  ReaImGui")
      msg("    2. Click Install")
      msg("    3. Restart Reaper")
      msg("    4. Run this installer again")
    else
      msg("    Please install ReaImGui:")
      msg("")
      msg("    1. In Reaper, search Actions for: 'ReaPack: Browse packages'")
      msg("    2. Search for:        ReaImGui")
      msg("    3. Click 'Install'")
      msg("    4. Restart Reaper")
      msg("    5. Run this installer again")
      msg("")
      msg("    OR install manually:")
      msg("    1. Download:  https://github.com/cfillion/reaimgui/releases")
      msg("    2. Extract to: " .. reaper.GetResourcePath() .. "/UserPlugins/")
      msg("    3. Restart Reaper")
      msg("    4. Run this installer again")
    end
    msg("")
    return false
  end

  if not reaimgui_version_ok() then
    msg("⚠️   ReaImGui found but version may be outdated (need >= " .. REAIMGUI_MIN .. ")")
    msg("    Consider updating via ReaPack > Synchronize packages")
    msg("    Continuing install anyway...")
    msg("")
  else
    msg("✅  ReaImGui found (v" .. reaper.ImGui_GetVersion() .. ")")
  end

  return true
end

-- ============================================================================
-- INSTALL FILES
-- ============================================================================

local FILES = {
  "mixdeck.lua",
  "ui.lua",
  "json_utils.lua",
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
  if not io.open(cfg_dst, "r") then
    copy_file(src_dir .. "config/default_config.json", cfg_dst)
    msg("  ✅  config/default_config.json  (default template)")
  else
    msg("  ⏭️   config/default_config.json  (skipped — user config exists)")
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
    msg("    You can now find MixDeck in:  Actions > Action list")
    msg("    Search for: MixDeck")
    msg("    Assign a shortcut key if you like!")
  else
    msg("")
    msg("⚠️   Could not auto-register action.")
    msg("    To run MixDeck manually:")
    msg("    Actions > Load ReaScript > " .. main_script)
  end
  return install_dir .. "/mixdeck.lua"
end

local function launch_mixdeck(main_script_path)
  msg("")
  msg("  Launching MixDeck...")
  reaper.dofile(main_script_path)
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
    local main_script = register_action(install_dir)
    msg("")
    msg("========================================")
    msg("  MixDeck v" .. MIXDECK_VERSION .. " installed successfully!")
    msg("========================================")
    msg("")
    launch_mixdeck(main_script)
  else
    msg("")
    msg("⚠️  Install completed with errors.")
    msg("   Check messages above for details.")
  end
end

run()
