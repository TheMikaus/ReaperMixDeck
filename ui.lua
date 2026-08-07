-- ui.lua: ReaImGui UI for MixDeck
-- Requires: ReaImGui extension (install via ReaPack)
-- Version: 1.3.26

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
local install_source_buf   = ""     -- editable installer source folder for Update
local status_msg           = ""
local status_expiry        = 0
local preview_active       = false  -- preview is playing
local drag_src_idx         = nil    -- dragging preset from index

local W_LEFT   = 295
local W_CENTER = 500  -- center column for editor
local WIN_W    = 1300
local WIN_H    = 700

-- ============================================================================
-- HELPERS
-- ============================================================================

local function get_selected_preset()
  if sel_idx < 1 or sel_idx > #md_ref.presets then return nil end
  return md_ref.presets[sel_idx]
end

local function set_status(msg)
  status_msg    = msg
  status_expiry = reaper.time_precise() + 3.5
  if fns and fns.log_message then
    fns.log_message("UI: " .. msg, "INFO")
  end
end

local function ensure_context()
  if not ctx then
    ctx = reaper.ImGui_CreateContext("MixDeck")
  end

  if ctx and reaper.ImGui_SetCurrentContext then
    local ok, err = pcall(function()
      reaper.ImGui_SetCurrentContext(ctx)
    end)
    if not ok then
      if fns and fns.log_message then
        fns.log_message("UI: context reset after error — " .. tostring(err), "ERROR")
      end
      ctx = reaper.ImGui_CreateContext("MixDeck")
      if ctx and reaper.ImGui_SetCurrentContext then
        pcall(function()
          reaper.ImGui_SetCurrentContext(ctx)
        end)
      end
    end
  end

  return ctx ~= nil
end

local function handle_keyboard()
  -- Ctrl+S: save preset
  if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_S()) then
    if reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_LeftCtrl()) then
      local p = get_selected_preset()
      if p then
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
  set_status("Preview is not implemented yet for preset: " .. preset.name)
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

-- Compat: border flag for BeginChild changed in ReaImGui 0.8+
local function child_border_flag()
  if reaper.ImGui_ChildFlags_Borders then
    return reaper.ImGui_ChildFlags_Borders()
  elseif reaper.ImGui_ChildFlags_Border then
    return reaper.ImGui_ChildFlags_Border()
  end
  return 1
end

local function safe_draw_child(label, width, height, border, draw_fn)
  local ok, child_open = pcall(function()
    return reaper.ImGui_BeginChild(ctx, label, width, height, border)
  end)

  if not ok then
    if fns and fns.log_message then
      fns.log_message("UI: BeginChild failed for " .. tostring(label) .. " — " .. tostring(child_open), "ERROR")
    end
    return
  end

  if child_open then
    local draw_ok, err = pcall(draw_fn)
    if not draw_ok and fns and fns.log_message then
      fns.log_message("UI: child content failed for " .. tostring(label) .. " — " .. tostring(err), "ERROR")
    end
  end

  pcall(function()
    reaper.ImGui_EndChild(ctx)
  end)
end

local function table_flags()
  local f = reaper.ImGui_TableFlags_Borders()
        | reaper.ImGui_TableFlags_RowBg()
        | reaper.ImGui_TableFlags_SizingFixedFit()
  return f
end

local function make_row_widget_id(row_idx, suffix)
  return "row_" .. tostring(row_idx) .. (suffix or "")
end

local function browse_for_folder(title, initial_dir)
  if reaper.APIExists and reaper.APIExists("JS_Dialog_BrowseForFolder") then
    local ok, a, b = pcall(reaper.JS_Dialog_BrowseForFolder, title or "Select Folder", initial_dir or "")
    if ok then
      if type(a) == "string" and a ~= "" then
        return a
      end
      if (a == 1 or a == true) and type(b) == "string" and b ~= "" then
        return b
      end
    elseif fns and fns.log_message then
      fns.log_message("UI: JS_Dialog_BrowseForFolder failed — " .. tostring(a), "ERROR")
    end
  elseif reaper.APIExists and reaper.APIExists("CF_DialogBrowseForFolder") then
    local ok_two_args, path = pcall(reaper.CF_DialogBrowseForFolder, title or "Select Folder", initial_dir or "")
    if ok_two_args and path and path ~= "" then
      return path
    end

    local ok_one_arg, path_one_arg = pcall(reaper.CF_DialogBrowseForFolder, initial_dir or "")
    if ok_one_arg and path_one_arg and path_one_arg ~= "" then
      return path_one_arg
    end

    if (not ok_two_args or not ok_one_arg) and fns and fns.log_message then
      fns.log_message("UI: CF_DialogBrowseForFolder failed", "ERROR")
    end
  end

  set_status("Folder browser unavailable. Install JS_ReaScriptAPI or SWS.")
  return nil
end

-- Color scheme for track table
local TABLE_COLORS = {
  parent      = 0x3A3A3AFF,  -- medium gray for parents
  child       = 0x2A2A2AFF,  -- darker gray for children
  hover       = 0x5A5A5AFF,  -- bright gray for hover
  catchall    = 0x252525FF,  -- darker for catch-all
}

-- ============================================================================
-- LEFT PANEL: PRESET LIST
-- ============================================================================

local function draw_preset_list()
  -- Reserve 32px at bottom for the two buttons
  -- Height = available window height - buttons area (32px)
  local list_height = reaper.ImGui_GetWindowHeight(ctx) - reaper.ImGui_GetCursorPosY(ctx) - 50
  safe_draw_child("##presets", W_LEFT, list_height, child_border_flag(), function()
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
  end)

  -- New / Delete / Update buttons pinned to bottom of panel
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
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Update##up", 92, 0) then
    set_status("Launching installer...")
    if fns and fns.run_installer then
      if install_source_buf ~= "" and fns.set_install_source_dir then
        fns.set_install_source_dir(install_source_buf)
      end

      local launched = fns.run_installer()
      if fns.get_install_source_dir then
        md_ref.install_source_dir = fns.get_install_source_dir()
      end
      install_source_buf = md_ref.install_source_dir or install_source_buf

      if launched then
        set_status("Installer completed. Reloading...")
        if fns.restart_mixdeck_action then
          fns.restart_mixdeck_action()
        end
      else
        set_status("Installer failed — check log")
      end
    else
      set_status("Installer unavailable")
    end
  end
end

-- ============================================================================
-- RIGHT PANEL: PRESET EDITOR
-- ============================================================================

local CHANNELS      = "L (Left)\0R (Right)\0C (Center)\0None (Mute)\0"
local CHANNEL_KEYS  = { "L", "R", "C", "none" }
local ch_to_idx     = { L = 0, R = 1, B = 2, C = 2, none = 3 }  -- B maps to C

local FORMATS       = "MP3\0WAV\0FLAC\0"
local FORMAT_KEYS   = { "mp3", "wav", "flac" }
local fmt_to_idx    = { mp3 = 0, wav = 1, flac = 2 }

local BITRATES      = "128k\0" .. "192k\0" .. "256k\0" .. "320k\0"
local BITRATE_KEYS  = { "128k", "192k", "256k", "320k" }
local br_to_idx     = { ["128k"] = 0, ["192k"] = 1, ["256k"] = 2, ["320k"] = 3 }

local function build_combo_items(items)
  local out = ""
  for _, item in ipairs(items) do
    out = out .. item .. "\0"
  end
  return out
end

local function contains_value(list, value)
  for _, v in ipairs(list) do
    if v == value then return true end
  end
  return false
end

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

  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Text(ctx, "TRACK ROUTING")
  reaper.ImGui_Spacing(ctx)

  local function resolve_routing_key(track_info)
    local route_key = track_info.route_key or track_info.name
    if preset.routing[route_key] then
      return route_key
    end

    local legacy_key = nil
    if preset.routing[track_info.name] then
      legacy_key = track_info.name
    else
      for existing_key, _ in pairs(preset.routing) do
        local legacy_name = tostring(existing_key):match("^%d+:%s*(.+)$")
        if legacy_name and legacy_name == track_info.name then
          legacy_key = existing_key
          break
        end
      end
    end

    if legacy_key then
      preset.routing[route_key] = preset.routing[legacy_key]
      if legacy_key ~= route_key then
        preset.routing[legacy_key] = nil
      end
      return route_key
    end

    return nil
  end

  -- ── Routing table ────────────────────────────────────────────────────────
  -- This table lets the user assign a routing channel to each track. The UI draws
  -- one row per track that already has an entry in the preset routing map, and each
  -- row gets a stable widget ID based on the table row counter.
  local to_remove = nil
  local table_started = false
  local table_closed = false
  local table_ok, table_err = pcall(function()
    if reaper.ImGui_BeginTable(ctx, "##routing", 3, table_flags()) then
      table_started = true
      reaper.ImGui_TableSetupColumn(ctx, "Track",   reaper.ImGui_TableColumnFlags_WidthStretch())
      reaper.ImGui_TableSetupColumn(ctx, "Channel", reaper.ImGui_TableColumnFlags_WidthFixed(), 105)
      reaper.ImGui_TableSetupColumn(ctx, "##rm",    reaper.ImGui_TableColumnFlags_WidthFixed(), 26)
      reaper.ImGui_TableHeadersRow(ctx)

      -- Display tracks in file order with nesting visualization.
      local all_tracks = fns.get_all_tracks()
      local row_index = 0
      for track_position, track_info in ipairs(all_tracks) do
        local track_key = resolve_routing_key(track_info)
        if track_key then

          row_index = row_index + 1
          reaper.ImGui_TableNextRow(ctx)
          reaper.ImGui_TableNextColumn(ctx)

          -- Keep the row selection limited to the first column so the combo box can still open.
          local indent = string.rep("      ", track_info.is_folder)
          local selection_id = indent .. track_info.name .. "##sel_" .. make_row_widget_id(row_index, "")
          reaper.ImGui_Selectable(ctx, selection_id, false)

          -- Color the row based on whether it is hovered or whether it is a folder/child row.
          if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_TableSetBgColor(ctx, reaper.ImGui_TableBgTarget_RowBg0(), TABLE_COLORS.hover)
          else
            local row_bg_color = (track_info.is_folder == 0) and TABLE_COLORS.parent or TABLE_COLORS.child
            reaper.ImGui_TableSetBgColor(ctx, reaper.ImGui_TableBgTarget_RowBg0(), row_bg_color)
          end

          reaper.ImGui_TableNextColumn(ctx)
          reaper.ImGui_PushItemWidth(ctx, 100)
          local current_channel = preset.routing[track_key]
          local combo_id = "##ch_" .. make_row_widget_id(row_index, "")
          local combo_changed, combo_index = reaper.ImGui_Combo(ctx, combo_id, ch_to_idx[current_channel] or 0, CHANNELS)
          if combo_changed then
            local selected_channel = CHANNEL_KEYS[combo_index + 1] or "C"
            if selected_channel ~= current_channel then
              preset.routing[track_key] = selected_channel

              local parent_depth = track_info.is_folder or 0
              for child_pos = track_position + 1, #all_tracks do
                local child_track = all_tracks[child_pos]
                local child_depth = child_track.is_folder or 0
                if child_depth <= parent_depth then
                  break
                end

                local child_key = child_track.route_key or child_track.name
                preset.routing[child_key] = selected_channel
              end
            end
          end
          reaper.ImGui_PopItemWidth(ctx)

          reaper.ImGui_TableNextColumn(ctx)
          local remove_button_id = "x##x_" .. make_row_widget_id(row_index, "")
          if reaper.ImGui_SmallButton(ctx, remove_button_id) then
            to_remove = track_key
          end
        end
      end

      -- Implicit catch-all row
      reaper.ImGui_TableNextRow(ctx)
      reaper.ImGui_TableNextColumn(ctx)
      local flags = reaper.ImGui_SelectableFlags_SpanAllColumns() | reaper.ImGui_SelectableFlags_AllowItemOverlap()
      reaper.ImGui_Selectable(ctx, "(everything else)", false, flags)
      
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_TableSetBgColor(ctx, reaper.ImGui_TableBgTarget_RowBg0(), TABLE_COLORS.hover)
      else
        reaper.ImGui_TableSetBgColor(ctx, reaper.ImGui_TableBgTarget_RowBg0(), TABLE_COLORS.catchall)
      end
      
      reaper.ImGui_TableNextColumn(ctx)
      reaper.ImGui_TextDisabled(ctx, "center")
      reaper.ImGui_TableNextColumn(ctx)

      reaper.ImGui_EndTable(ctx)
      table_closed = true
    end
  end)

  if not table_ok then
    if fns and fns.log_message then
      fns.log_message("UI: routing table draw failed — " .. tostring(table_err), "ERROR")
    end
  end

  if table_started and not table_closed then
    pcall(function()
      reaper.ImGui_EndTable(ctx)
    end)
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
    local track_key = resolve_routing_key(t) or (t.route_key or t.name)
    if not preset.routing[track_key] then
      table.insert(avail_names, track_key)
      avail_str = avail_str .. track_key .. "\0"
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

end

local function draw_center_action_bar(center_width)
  local preset = get_selected_preset()

  if reaper.ImGui_Button(ctx, "Save Preset##sv_top", 110, 0) then
    if preset then
      fns.save_preset_to_scope(preset, preset.scope or "global")
      set_status("Saved: " .. preset.name)
    else
      set_status("Select a preset first.")
    end
  end
  reaper.ImGui_SameLine(ctx)

  if reaper.ImGui_Button(ctx, "▶ Preview##prev_top", 90, 0) then
    if preset then
      start_preview()
    else
      set_status("Select a preset first.")
    end
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Export This##ex1_top", 110, 0) then
    if not preset then
      set_status("Select a preset first.")
    elseif not fns.get_project_name() then
      set_status("Error: save your project before exporting.")
    else
      local ok = fns.export_preset(preset)
      if ok then set_status("Exported: " .. preset.name)
      else set_status("Export failed — check Reaper console.") end
    end
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Export All##exall_top", 110, 0) then
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
  reaper.ImGui_PushItemWidth(ctx, -88)
  local gc, gv = reaper.ImGui_InputText(ctx, "##g_exp", md_ref.global_export_path or "")
  reaper.ImGui_PopItemWidth(ctx)
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Browse##g_exp", 78, 0) then
    local chosen = browse_for_folder("Choose common export folder", md_ref.global_export_path or "")
    if chosen then
      md_ref.global_export_path = chosen
      if fns and fns.log_message then
        fns.log_message("UI: selected common export folder " .. tostring(chosen), "INFO")
      end
    end
  end
  if gc then
    md_ref.global_export_path = gv
    if fns and fns.log_message then
      fns.log_message("UI: changed common export folder to " .. tostring(gv), "INFO")
    end
  end

  reaper.ImGui_Spacing(ctx)

  -- Per-project override
  reaper.ImGui_Text(ctx, "Project export folder  (overrides common for this project only)")
  reaper.ImGui_TextDisabled(ctx, "  Leave blank to use the common folder above.")
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_PushItemWidth(ctx, -88)
  local pc, pv = reaper.ImGui_InputText(ctx, "##p_exp", md_ref.project_export_path or "")
  reaper.ImGui_PopItemWidth(ctx)
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Browse##p_exp", 78, 0) then
    local chosen = browse_for_folder("Choose project export folder", md_ref.project_export_path or md_ref.global_export_path or "")
    if chosen then
      md_ref.project_export_path = chosen
      if fns and fns.log_message then
        fns.log_message("UI: selected project export folder " .. tostring(chosen), "INFO")
      end
    end
  end
  if pc then
    md_ref.project_export_path = pv
    if fns and fns.log_message then
      fns.log_message("UI: changed project export folder to " .. tostring(pv), "INFO")
    end
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  -- Installer source folder (used by Update)
  reaper.ImGui_Text(ctx, "Installer source folder")
  reaper.ImGui_TextDisabled(ctx, "  Update runs install.lua from this location.")
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_PushItemWidth(ctx, -88)
  local src_changed, src_value = reaper.ImGui_InputText(ctx, "##install_source", install_source_buf)
  reaper.ImGui_PopItemWidth(ctx)
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Browse##install_src", 78, 0) then
    local chosen = browse_for_folder("Choose installer source folder", install_source_buf or "")
    if chosen then
      install_source_buf = chosen
    end
  end
  if src_changed then
    install_source_buf = src_value
  end

  if reaper.ImGui_Button(ctx, "Save Source##save_src", 120, 0) then
    if install_source_buf ~= "" and fns and fns.set_install_source_dir then
      local saved = fns.set_install_source_dir(install_source_buf)
      if saved then
        if fns.get_install_source_dir then
          md_ref.install_source_dir = fns.get_install_source_dir()
        else
          md_ref.install_source_dir = install_source_buf
        end
        install_source_buf = md_ref.install_source_dir or install_source_buf
        set_status("Installer source saved")
      else
        set_status("Failed to save installer source")
      end
    else
      set_status("Enter an installer source folder first")
    end
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  -- ── Format + Bitrate (global settings) ────────────────────────────────────
  reaper.ImGui_Text(ctx, "DEFAULT EXPORT FORMAT")
  reaper.ImGui_PushItemWidth(ctx, 72)
  local supported_formats = FORMAT_KEYS
  if fns and fns.get_supported_render_formats then
    local probed = fns.get_supported_render_formats()
    if probed and #probed > 0 then
      supported_formats = probed
    else
      supported_formats = { "wav" }
    end
  end

  if not contains_value(supported_formats, md_ref.format) then
    md_ref.format = supported_formats[1] or "wav"
  end

  local current_fmt_index = 0
  for i, fmt in ipairs(supported_formats) do
    if fmt == md_ref.format then
      current_fmt_index = i - 1
      break
    end
  end

  local format_labels = {}
  for _, fmt in ipairs(supported_formats) do
    table.insert(format_labels, string.upper(fmt))
  end

  local fc, fi = reaper.ImGui_Combo(ctx, "Format##fmt_global", current_fmt_index, build_combo_items(format_labels))
  if fc and supported_formats[fi + 1] then
    md_ref.format = supported_formats[fi + 1]
    if fns and fns.log_message then
      fns.log_message("UI: changed export format to " .. tostring(md_ref.format), "INFO")
    end
  end
  reaper.ImGui_SameLine(ctx)
  -- Only show bitrate for lossy formats
  if md_ref.format == "mp3" or md_ref.format == "ogg" then
    local bc, bi = reaper.ImGui_Combo(ctx, "Bitrate##br_global", br_to_idx[md_ref.bitrate] or 3, BITRATES)
    if bc then
      md_ref.bitrate = BITRATE_KEYS[bi + 1]
      if fns and fns.log_message then
        fns.log_message("UI: changed bitrate to " .. tostring(md_ref.bitrate), "INFO")
      end
    end
  else
    reaper.ImGui_TextDisabled(ctx, "(lossless)")
  end
  reaper.ImGui_PopItemWidth(ctx)

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

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  if fns and fns.get_default_state_status then
    local has_default, count = fns.get_default_state_status()
    if has_default then
      reaper.ImGui_TextDisabled(ctx, "Default state saved: yes (" .. tostring(count or 0) .. " tracks)")
    else
      reaper.ImGui_TextDisabled(ctx, "Default state saved: no")
    end
    reaper.ImGui_Spacing(ctx)
  end

  -- ── Default state management ───────────────────────────────────────────────
  reaper.ImGui_Text(ctx, "PROJECT DEFAULT STATE")
  reaper.ImGui_TextDisabled(ctx, "Save the current pan, volume, mute, and solo for all tracks.")
  reaper.ImGui_TextDisabled(ctx, "Restore anytime to return to this state after running presets.")
  reaper.ImGui_Spacing(ctx)

  if reaper.ImGui_Button(ctx, "Save Default State##save_default", 150, 0) then
    local success = fns.save_default_state()
    if success then
      set_status("Default state saved for this project.")
      if fns and fns.log_message then
        fns.log_message("UI: saved default project state", "INFO")
      end
    else
      set_status("Failed to save default state.")
      if fns and fns.log_message then
        fns.log_message("UI: failed to save default project state", "ERROR")
      end
    end
  end

  reaper.ImGui_SameLine(ctx)

  if reaper.ImGui_Button(ctx, "Restore Default State##restore_default", 150, 0) then
    local success = fns.restore_default_state()
    if success then
      set_status("Default state restored.")
      if fns and fns.log_message then
        fns.log_message("UI: restored default project state", "INFO")
      end
    else
      set_status("No default state found for this project.")
      if fns and fns.log_message then
        fns.log_message("UI: failed to restore default project state", "ERROR")
      end
    end
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  -- ── Log viewer ────────────────────────────────────────────────────────────
  reaper.ImGui_Text(ctx, "LOG")
  if fns and fns.get_supported_render_formats then
    local supported = fns.get_supported_render_formats()
    if supported and #supported > 0 then
      reaper.ImGui_TextDisabled(ctx, "Available render formats: " .. table.concat(supported, ", "))
    end
  end
  local active_status = (reaper.time_precise() < status_expiry) and status_msg or "Ready"
  reaper.ImGui_TextDisabled(ctx, "Status: " .. active_status)
  reaper.ImGui_Spacing(ctx)
  safe_draw_child("##log_panel", -1, 140, true, function()
    local lines = md_ref.log_lines or {}
    for i = #lines, math.max(1, #lines - 49), -1 do  -- show last 50 lines, newest first
      reaper.ImGui_TextDisabled(ctx, lines[i])
    end
  end)
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
  if not ensure_context() then
    return false
  end

  local ok, result = pcall(function()
    reaper.ImGui_SetNextWindowSize(ctx, WIN_W, WIN_H, reaper.ImGui_Cond_FirstUseEver())

    local visible, open = reaper.ImGui_Begin(ctx, "MixDeck  v" .. md_ref.version, true)

    if visible then
      -- Handle keyboard shortcuts
      handle_keyboard()

      -- Save the starting Y position for all three panels to align them horizontally
      local panel_start_y = reaper.ImGui_GetCursorPosY(ctx)
      local panel_start_x = reaper.ImGui_GetCursorPosX(ctx)
      local avail_height = reaper.ImGui_GetWindowHeight(ctx) - panel_start_y - 50  -- leave 50px for status bar
      
      -- ── Left panel: Presets List ────────────────────────────────────────────
      draw_preset_list()

      -- ── Center panel: Preset Editor ────────────────────────────────────────
      reaper.ImGui_SetCursorPosY(ctx, panel_start_y)
      reaper.ImGui_SetCursorPosX(ctx, panel_start_x + W_LEFT + 4)
      local center_width = W_CENTER

      draw_center_action_bar(center_width)

      local center_body_y = panel_start_y + 28
      reaper.ImGui_SetCursorPosY(ctx, center_body_y)
      reaper.ImGui_SetCursorPosX(ctx, panel_start_x + W_LEFT + 4)
      safe_draw_child("##center_panel", center_width, avail_height - 28, child_border_flag(), function()
        draw_preset_editor()
      end)

    -- ── Right panel: Settings ──────────────────────────────────────────────
    reaper.ImGui_SetCursorPosY(ctx, panel_start_y)
    reaper.ImGui_SetCursorPosX(ctx, panel_start_x + W_LEFT + 4 + center_width + 4)
    local right_width = reaper.ImGui_GetWindowWidth(ctx) - (panel_start_x + W_LEFT + 4 + center_width + 4) - 8
    safe_draw_child("##right_panel", right_width, avail_height, child_border_flag(), function()
      draw_settings()
    end)

      -- ── Popups ───────────────────────────────────────────────────────────────
      draw_new_preset_popup()

      reaper.ImGui_End(ctx)
    end

    return open
  end)

  if not ok then
    if fns and fns.log_message then
      fns.log_message("UI draw failed: " .. tostring(result), "ERROR")
    end
    ctx = nil
    ui.init(md_ref, fns)
    return false
  end

  return result
end

-- ============================================================================
-- INIT / DESTROY
-- ============================================================================

function ui.init(md, functions)
  md_ref = md
  fns    = functions
  if ctx then
    ctx = nil
  end
  ctx = reaper.ImGui_CreateContext("MixDeck")
  if fns and fns.get_install_source_dir then
    md_ref.install_source_dir = fns.get_install_source_dir()
  end
  install_source_buf = md_ref.install_source_dir or ""
  
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
