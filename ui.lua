-- ui.lua: ReaImGui UI for MixDeck
-- Requires: ReaImGui extension (install via ReaPack)

local ui = {}

-- ============================================================================
-- STATE
-- ============================================================================

local ctx     = nil
local md_ref  = nil   -- reference to md table in mixdeck.lua
local fns     = nil   -- reference to exposed functions table

local sel_idx              = 0      -- selected preset index (1-based, 0 = none)
local show_settings        = false
local new_preset_name_buf  = ""
local show_new_popup       = false
local add_track_sel        = 0      -- combo index for "Add Track" picker
local status_msg           = ""
local status_expiry        = 0
local preview_active       = false  -- preview is playing
local drag_src_idx         = nil    -- dragging preset from index

local W_LEFT   = 195
local WIN_W    = 900
local WIN_H    = 700

-- ============================================================================
-- HELPERS
-- ============================================================================

local function set_status(msg)
  status_msg    = msg
  status_expiry = reaper.time_precise() + 3.5
end

local function handle_keyboard()
  -- Ctrl+S: save preset
  if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_S()) then
    if reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_LeftCtrl()) then
      local p = get_selected_preset()
      if p and not show_settings then
        fns.save_preset_to_scope(p, p.scope or "global")
        set_status("Saved: " .. p.name)
      end
    end
  end
  -- Ctrl+E: export preset
  if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_E()) then
    if reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_LeftCtrl()) then
      local p = get_selected_preset()
      if p then
        local ok = fns.export_preset(p)
        if ok then set_status("Exported: " .. p.name)
        else set_status("Export failed") end
      end
    end
  end
  -- Delete: delete preset
  if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Delete()) then
    local p = get_selected_preset()
    if p then
      fns.delete_preset(p.name)
      sel_idx = 0
      set_status("Deleted: " .. p.name)
    end
  end
end

local function start_preview()
  local preset = get_selected_preset()
  if not preset then return end
  set_status("Preview: " .. preset.name .. " (apply routing + play 4 bars)")
  preview_active = true
end

local function reorder_presets(from_idx, to_idx)
  if from_idx < 1 or to_idx < 1 or from_idx > #md_ref.presets or to_idx > #md_ref.presets then return end
  if from_idx == to_idx then return end
  local preset = table.remove(md_ref.presets, from_idx)
  table.insert(md_ref.presets, to_idx, preset)
  sel_idx = to_idx
  -- Save current scope config
  if preset.scope == "project" then
    fns.save_config("project")
  else
    fns.save_config("global")
  end
  set_status("Reordered preset")
end

local function get_selected_preset()
  if sel_idx < 1 or sel_idx > #md_ref.presets then return nil end
  return md_ref.presets[sel_idx]
end

-- Compat: border flag for BeginChild changed in ReaImGui 0.8+
local function child_border_flag()
  if reaper.ImGui_ChildFlags_Borders then
    return reaper.ImGui_ChildFlags_Borders()
  elseif reaper.ImGui_ChildFlags_Border then
    return reaper.ImGui_ChildFlags_Border()
  end
  return 1
end

local function table_flags()
  local f = reaper.ImGui_TableFlags_Borders()
        | reaper.ImGui_TableFlags_RowBg()
        | reaper.ImGui_TableFlags_SizingFixedFit()
  return f
end

-- ============================================================================
-- LEFT PANEL: PRESET LIST
-- ============================================================================

local function draw_preset_list()
  -- Reserve 32px at bottom for the two buttons
  -- Height = available window height - buttons area (32px)
  local list_height = reaper.ImGui_GetWindowHeight(ctx) - reaper.ImGui_GetCursorPosY(ctx) - 50
  reaper.ImGui_BeginChild(ctx, "##presets", W_LEFT, list_height, child_border_flag())

  reaper.ImGui_Text(ctx, "PRESETS")
  reaper.ImGui_TextDisabled(ctx, "(drag to reorder)")
  reaper.ImGui_Separator(ctx)

  for i, p in ipairs(md_ref.presets) do
    local tag     = (p.scope == "project") and "[P] " or "[G] "
    local label   = tag .. p.name .. "##p" .. i
    local is_sel  = (sel_idx == i and not show_settings)
    if reaper.ImGui_Selectable(ctx, label, is_sel) then
      sel_idx       = i
      show_settings = false
      add_track_sel = 0
    end
    
    -- Drag-drop support for reordering
    if reaper.ImGui_BeginDragDropSource(ctx, reaper.ImGui_DragDropFlags_SourceAllowNullID()) then
      reaper.ImGui_SetDragDropPayload(ctx, "PRESET_IDX", tostring(i))
      reaper.ImGui_Text(ctx, "Moving: " .. p.name)
      reaper.ImGui_EndDragDropSource(ctx)
    end
    if reaper.ImGui_BeginDragDropTarget(ctx) then
      local payload = reaper.ImGui_AcceptDragDropPayload(ctx, "PRESET_IDX")
      if payload then
        local from_idx = tonumber(payload)
        reorder_presets(from_idx, i)
      end
      reaper.ImGui_EndDragDropTarget(ctx)
    end
  end

  reaper.ImGui_Separator(ctx)
  if reaper.ImGui_Selectable(ctx, "⚙  Settings##settings_sel", show_settings) then
    show_settings = true
    sel_idx       = 0
  end

  reaper.ImGui_EndChild(ctx)

  -- New / Delete buttons pinned to bottom of panel
  if reaper.ImGui_Button(ctx, "+ New##nb", 92, 0) then
    show_new_popup     = true
    new_preset_name_buf = ""
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "- Delete##db", 92, 0) then
    local p = get_selected_preset()
    if p then
      fns.delete_preset(p.name)
      sel_idx = 0
      set_status("Deleted: " .. p.name)
    end
  end
end

-- ============================================================================
-- RIGHT PANEL: PRESET EDITOR
-- ============================================================================

local CHANNELS      = "L (Left)\0R (Right)\0B (Both)\0"
local CHANNEL_KEYS  = { "L", "R", "B" }
local ch_to_idx     = { L = 0, R = 1, B = 2 }

local FORMATS       = "MP3\0WAV\0FLAC\0"
local FORMAT_KEYS   = { "mp3", "wav", "flac" }
local fmt_to_idx    = { mp3 = 0, wav = 1, flac = 2 }

local BITRATES      = "128k\0192k\0256k\0320k\0"
local BITRATE_KEYS  = { "128k", "192k", "256k", "320k" }
local br_to_idx     = { ["128k"] = 0, ["192k"] = 1, ["256k"] = 2, ["320k"] = 3 }

local function draw_preset_editor()
  local preset = get_selected_preset()
  if not preset then
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_TextDisabled(ctx, "Select a preset on the left, or create a new one.")
    return
  end

  -- ── Name ────────────────────────────────────────────────────────────────
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, "Name")
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_PushItemWidth(ctx, 220)
  local nc, nv = reaper.ImGui_InputText(ctx, "##name", preset.name)
  reaper.ImGui_PopItemWidth(ctx)
  if nc then preset.name = nv end

  -- ── Scope ────────────────────────────────────────────────────────────────
  reaper.ImGui_SameLine(ctx, 0, 20)
  reaper.ImGui_Text(ctx, "Scope:")
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_RadioButton(ctx, "Global##sc_g", preset.scope ~= "project") then
    preset.scope = "global"
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_RadioButton(ctx, "Project##sc_p", preset.scope == "project") then
    preset.scope = "project"
  end

  -- ── Format + Bitrate ─────────────────────────────────────────────────────
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_PushItemWidth(ctx, 72)
  local fc, fi = reaper.ImGui_Combo(ctx, "Format##fmt", fmt_to_idx[preset.format] or 0, FORMATS)
  if fc then preset.format = FORMAT_KEYS[fi + 1] end
  reaper.ImGui_SameLine(ctx)
  -- Only show bitrate for lossy formats
  if preset.format == "mp3" or preset.format == "ogg" then
    local bc, bi = reaper.ImGui_Combo(ctx, "Bitrate##br", br_to_idx[preset.bitrate] or 3, BITRATES)
    if bc then preset.bitrate = BITRATE_KEYS[bi + 1] end
  else
    reaper.ImGui_TextDisabled(ctx, "(lossless)")
  end
  reaper.ImGui_PopItemWidth(ctx)

  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Text(ctx, "TRACK ROUTING")
  reaper.ImGui_Spacing(ctx)

  -- ── Routing table ────────────────────────────────────────────────────────
  local to_remove = nil
  if reaper.ImGui_BeginTable(ctx, "##routing", 3, table_flags()) then
    reaper.ImGui_TableSetupColumn(ctx, "Track",   reaper.ImGui_TableColumnFlags_WidthStretch())
    reaper.ImGui_TableSetupColumn(ctx, "Channel", reaper.ImGui_TableColumnFlags_WidthFixed(), 105)
    reaper.ImGui_TableSetupColumn(ctx, "##rm",    reaper.ImGui_TableColumnFlags_WidthFixed(), 26)
    reaper.ImGui_TableHeadersRow(ctx)

    for track_name, channel in pairs(preset.routing) do
      reaper.ImGui_TableNextRow(ctx)
      reaper.ImGui_TableNextColumn(ctx)
      reaper.ImGui_Text(ctx, track_name)

      reaper.ImGui_TableNextColumn(ctx)
      reaper.ImGui_PushItemWidth(ctx, 100)
      local cc, ci = reaper.ImGui_Combo(ctx, "##ch_" .. track_name, ch_to_idx[channel] or 0, CHANNELS)
      if cc then preset.routing[track_name] = CHANNEL_KEYS[ci + 1] end
      reaper.ImGui_PopItemWidth(ctx)

      reaper.ImGui_TableNextColumn(ctx)
      if reaper.ImGui_SmallButton(ctx, "x##x_" .. track_name) then
        to_remove = track_name
      end
    end

    -- Implicit catch-all row
    reaper.ImGui_TableNextRow(ctx)
    reaper.ImGui_TableNextColumn(ctx)
    reaper.ImGui_TextDisabled(ctx, "(everything else)")
    reaper.ImGui_TableNextColumn(ctx)
    reaper.ImGui_TextDisabled(ctx, "opposite channel")
    reaper.ImGui_TableNextColumn(ctx)

    reaper.ImGui_EndTable(ctx)
  end

  if to_remove then
    preset.routing[to_remove] = nil
  end

  -- ── Add Track row ────────────────────────────────────────────────────────
  reaper.ImGui_Spacing(ctx)
  local all_tracks   = fns.get_all_tracks()
  local avail_names  = {}
  local avail_str    = ""
  for _, t in ipairs(all_tracks) do
    if not preset.routing[t.name] then
      table.insert(avail_names, t.name)
      avail_str = avail_str .. t.name .. "\0"
    end
  end

  if #avail_names > 0 then
    avail_str = avail_str .. "\0"
    reaper.ImGui_PushItemWidth(ctx, 200)
    local _, new_sel = reaper.ImGui_Combo(ctx, "##add_t", add_track_sel, avail_str)
    add_track_sel = new_sel
    reaper.ImGui_PopItemWidth(ctx)
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "+ Add Track##add") then
      local chosen = avail_names[add_track_sel + 1]
      if chosen then
        preset.routing[chosen] = "L"
        add_track_sel = 0
      end
    end
  else
    reaper.ImGui_TextDisabled(ctx, "All project tracks are already in this preset.")
  end

  reaper.ImGui_Separator(ctx)

  -- ── Output preview ───────────────────────────────────────────────────────
  local proj_name   = fns.get_project_name() or "Untitled"
  local out_folder  = fns.get_export_path() or "(project folder)"
  reaper.ImGui_Text(ctx, "Output folder: " .. out_folder)
  reaper.ImGui_TextDisabled(ctx, "  → " .. proj_name .. "_" .. preset.name .. "." .. preset.format)

  reaper.ImGui_Spacing(ctx)

  -- ── Action buttons ───────────────────────────────────────────────────────
  if reaper.ImGui_Button(ctx, "▶ Preview##prev", 60, 0) then
    start_preview()
  end
  reaper.ImGui_SameLine(ctx, 0, 20)
  if reaper.ImGui_Button(ctx, "Save Preset##sv", 100, 0) then
    fns.save_preset_to_scope(preset, preset.scope or "global")
    set_status("Saved: " .. preset.name)
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Export This##ex1", 100, 0) then
    if not fns.get_project_name() then
      set_status("Error: save your project before exporting.")
    else
      local ok = fns.export_preset(preset)
      if ok then set_status("Exported: " .. preset.name)
      else set_status("Export failed — check Reaper console.") end
    end
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Export All##exall", 100, 0) then
    if not fns.get_project_name() then
      set_status("Error: save your project before exporting.")
    else
      fns.batch_export()
      set_status("Batch export complete (" .. #md_ref.presets .. " presets)")
    end
  end
end

-- ============================================================================
-- RIGHT PANEL: SETTINGS
-- ============================================================================

local function draw_settings()
  reaper.ImGui_Text(ctx, "EXPORT SETTINGS")
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  -- Global export folder
  reaper.ImGui_Text(ctx, "Common export folder  (used for all projects)")
  reaper.ImGui_TextDisabled(ctx, "  Leave blank to export next to the project file.")
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_PushItemWidth(ctx, -1)
  local gc, gv = reaper.ImGui_InputText(ctx, "##g_exp", md_ref.global_export_path or "")
  reaper.ImGui_PopItemWidth(ctx)
  if gc then md_ref.global_export_path = gv end

  reaper.ImGui_Spacing(ctx)

  -- Per-project override
  reaper.ImGui_Text(ctx, "Project export folder  (overrides common for this project only)")
  reaper.ImGui_TextDisabled(ctx, "  Leave blank to use the common folder above.")
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_PushItemWidth(ctx, -1)
  local pc, pv = reaper.ImGui_InputText(ctx, "##p_exp", md_ref.project_export_path or "")
  reaper.ImGui_PopItemWidth(ctx)
  if pc then md_ref.project_export_path = pv end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  -- Resolved path preview
  local resolved = fns.get_export_path()
  reaper.ImGui_Text(ctx, "Resolved export path:")
  reaper.ImGui_TextDisabled(ctx, "  " .. (resolved or "(project folder)"))

  reaper.ImGui_Spacing(ctx)

  if reaper.ImGui_Button(ctx, "Save Settings##saveset") then
    fns.save_config("global")
    if md_ref.project_export_path and md_ref.project_export_path ~= "" then
      fns.save_config("project")
    end
    set_status("Settings saved.")
  end
end

-- ============================================================================
-- NEW PRESET POPUP
-- ============================================================================

local new_scope_idx = 0  -- 0 = global, 1 = project

local function draw_new_preset_popup()
  if show_new_popup then
    -- Center the dialog over the MixDeck window
    local win_x, win_y = reaper.ImGui_GetWindowPos(ctx)
    local win_w = reaper.ImGui_GetWindowWidth(ctx)
    local win_h = reaper.ImGui_GetWindowHeight(ctx)
    local dialog_w = 300
    local dialog_h = 160
    reaper.ImGui_SetNextWindowPos(ctx, win_x + (win_w - dialog_w) / 2, win_y + (win_h - dialog_h) / 2, reaper.ImGui_Cond_Appearing())
    reaper.ImGui_OpenPopup(ctx, "New Preset##popup")
    show_new_popup = false  -- flag to open; ImGui manages visibility thereafter
  end

  local visible, p_open = reaper.ImGui_BeginPopupModal(ctx, "New Preset##popup", true,
    reaper.ImGui_WindowFlags_AlwaysAutoResize())

  if visible then
    reaper.ImGui_Text(ctx, "Preset name:")
    reaper.ImGui_PushItemWidth(ctx, 280)
    local nc, nv = reaper.ImGui_InputText(ctx, "##preset_name_input", new_preset_name_buf)
    if nc then new_preset_name_buf = nv end
    reaper.ImGui_PopItemWidth(ctx)

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Text(ctx, "Scope:")
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_RadioButton(ctx, "Global (all projects)##scope_global", new_scope_idx == 0) then
      new_scope_idx = 0
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_RadioButton(ctx, "Project (this project only)##scope_project", new_scope_idx == 1) then
      new_scope_idx = 1
    end

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)

    local scope = (new_scope_idx == 1) and "project" or "global"
    
    if reaper.ImGui_Button(ctx, "Create", 100, 0) then
      if new_preset_name_buf ~= "" then
        local p = fns.create_preset(new_preset_name_buf, scope)
        if p then
          sel_idx       = #md_ref.presets
          show_settings = false
          set_status("Created " .. scope .. " preset: " .. new_preset_name_buf)
          new_preset_name_buf = ""
          new_scope_idx = 0
          reaper.ImGui_CloseCurrentPopup(ctx)
        end
      end
    end
    
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Cancel", 100, 0) then
      new_preset_name_buf = ""
      new_scope_idx = 0
      reaper.ImGui_CloseCurrentPopup(ctx)
    end

    reaper.ImGui_EndPopup(ctx)
  end
end

-- ============================================================================
-- MAIN DRAW (called every frame via defer)
-- ============================================================================

function ui.draw()
  if not ctx then
    -- Context not initialized or was destroyed
    return false
  end
  
  reaper.ImGui_SetNextWindowSize(ctx, WIN_W, WIN_H, reaper.ImGui_Cond_FirstUseEver())

  local visible, open = reaper.ImGui_Begin(ctx, "MixDeck  v" .. md_ref.version, true)

  if visible then
    -- Handle keyboard shortcuts
    handle_keyboard()

    -- Save the starting Y position for both panels to align them horizontally
    local panel_start_y = reaper.ImGui_GetCursorPosY(ctx)
    local panel_start_x = reaper.ImGui_GetCursorPosX(ctx)
    local avail_height = reaper.ImGui_GetWindowHeight(ctx) - panel_start_y - 50  -- leave 50px for status bar
    
    -- ── Left panel ──────────────────────────────────────────────────────────
    draw_preset_list()

    -- ── Right panel ─────────────────────────────────────────────────────────
    -- Restore Y to align with left panel, move X to the right
    reaper.ImGui_SetCursorPosY(ctx, panel_start_y)
    reaper.ImGui_SetCursorPosX(ctx, panel_start_x + W_LEFT + 8)
    local right_panel_width = reaper.ImGui_GetWindowWidth(ctx) - (panel_start_x + W_LEFT + 8) - 8
    reaper.ImGui_BeginChild(ctx, "##right_panel", right_panel_width, avail_height, child_border_flag())

    if show_settings then
      draw_settings()
    else
      draw_preset_editor()
    end

    reaper.ImGui_EndChild(ctx)

    -- ── Status bar ───────────────────────────────────────────────────────────
    reaper.ImGui_SetCursorPosY(ctx, reaper.ImGui_GetWindowHeight(ctx) - 46)
    reaper.ImGui_Separator(ctx)
    if reaper.time_precise() < status_expiry then
      reaper.ImGui_Text(ctx, status_msg)
    else
      reaper.ImGui_TextDisabled(ctx, "Ready")
    end

    -- ── Popups ───────────────────────────────────────────────────────────────
    draw_new_preset_popup()

    reaper.ImGui_End(ctx)
  end

  return open
end

-- ============================================================================
-- INIT / DESTROY
-- ============================================================================

function ui.init(md, functions)
  md_ref = md
  fns    = functions
  ctx    = reaper.ImGui_CreateContext("MixDeck")
  
  -- If no presets exist, create a default one so UI isn't blank on first launch
  if #md_ref.presets == 0 then
    local default = fns.create_preset("Default Mix", "global")
    if default then
      sel_idx = 1  -- Select the default preset
    end
  end
end

function ui.destroy()
  if ctx then
    -- ReaImGui manages context cleanup; we just clear our reference
    ctx = nil
  end
end

return ui
