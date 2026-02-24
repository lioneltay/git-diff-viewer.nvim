-- panel.lua — File panel: tree rendering, keymaps, cursor management
--
-- The panel is a scratch buffer that is fully re-rendered from state on every change.
-- Navigation state (folder expand, cursor position, filter) is stored in state.lua.

local state = require("git-diff-viewer.state")
local config = require("git-diff-viewer.config")
local utils = require("git-diff-viewer.utils")

local M = {}

-- ─── Rendering ────────────────────────────────────────────────────────────────

-- Build the tree structure from a flat list of file_items.
-- Groups files into folders, respecting the expand/collapse state.
--
-- Returns a list of panel_line tables which map 1:1 to buffer lines:
--   { type = "section_header", label = string }
--   { type = "folder",         path = string, depth = number, label = string, expanded = boolean }
--   { type = "file",           item = file_item, depth = number, label = string }
--   { type = "empty",          label = string }
local function build_lines(sections)
  local lines = {} -- panel_line metadata
  local text = {}  -- display strings

  local function add(line, display)
    table.insert(lines, line)
    table.insert(text, display)
  end

  local section_defs = {
    { key = "conflicts", label = "Merge Conflicts" },
    { key = "changes",   label = "Changes" },
    { key = "staged",    label = "Staged Changes" },
  }

  local any_content = false

  for _, sec in ipairs(section_defs) do
    local items = sections[sec.key] or {}

    -- Apply filter
    local filtered = {}
    for _, item in ipairs(items) do
      if state.filter == "" or item.path:lower():find(state.filter:lower(), 1, true) then
        table.insert(filtered, item)
      end
    end

    if #filtered == 0 then
      goto continue
    end

    any_content = true

    -- Section header
    add(
      { type = "section_header", label = sec.label, section = sec.key },
      "  " .. sec.label .. " (" .. #filtered .. ")"
    )

    -- Build folder tree for this section
    -- folder_seen[folder_path] prevents duplicate folder headers
    local folder_seen = {}

    for _, item in ipairs(filtered) do
      local rel = item.path
      local parts = utils.split_path(rel)
      local dirs = parts.dirs

      -- Emit folder nodes for each directory segment (depth-first, no duplicates)
      for d = 1, #dirs do
        local folder_path = utils.dirs_to_path({ unpack(dirs, 1, d) })
        if not folder_seen[folder_path] then
          folder_seen[folder_path] = true
          local is_expanded = state.folder_expanded[folder_path] ~= false -- default expanded
          local indent = string.rep("  ", d + 1)
          local icon = is_expanded and "▾ " or "▸ "
          local folder_name = dirs[d]
          add(
            { type = "folder", path = folder_path, depth = d, expanded = is_expanded },
            indent .. icon .. folder_name .. "/"
          )
        end
      end

      -- Check if this file should be visible (all parent folders expanded)
      local visible = true
      for d = 1, #dirs do
        local fp = utils.dirs_to_path({ unpack(dirs, 1, d) })
        if state.folder_expanded[fp] == false then
          visible = false
          break
        end
      end

      if visible then
        local depth = #dirs
        local indent = string.rep("  ", depth + 2)
        local icon = utils.status_icon(item.xy, item.section)
        local name = parts.file

        -- Rename: show "old_name → new_name" for the filename part
        if item.orig_path then
          local old_parts = utils.split_path(item.orig_path)
          name = old_parts.file .. " → " .. name
        end

        local counts = utils.format_counts(item.added, item.removed)
        local label
        if counts ~= "" then
          label = indent .. icon .. "  " .. name .. "  " .. counts
        else
          label = indent .. icon .. "  " .. name
        end

        -- Binary / submodule annotation
        if item.binary then
          label = label .. "  [binary]"
        elseif item.submodule then
          label = label .. "  [submodule]"
        end

        add({ type = "file", item = item, depth = depth }, label)
      end
    end

    ::continue::
  end

  if not any_content then
    add({ type = "empty" }, "  No changes")
  end

  return lines, text
end

-- Render the panel buffer from current state.
-- Preserves cursor line number (cursor stays at same line after re-render).
function M.render()
  local buf = state.panel_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  -- Save cursor position
  local cursor_line = 1
  if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
    cursor_line = vim.api.nvim_win_get_cursor(state.panel_win)[1]
  end

  -- Build new content
  local lines, text = build_lines(state.files)
  state.panel_lines = lines

  -- Write to buffer (temporarily make modifiable)
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, text)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  -- Restore cursor (clamped to new line count)
  if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
    local line_count = vim.api.nvim_buf_line_count(buf)
    cursor_line = math.min(cursor_line, line_count)
    cursor_line = math.max(cursor_line, 1)
    vim.api.nvim_win_set_cursor(state.panel_win, { cursor_line, 0 })
  end
end

-- ─── Buffer creation and keymaps ──────────────────────────────────────────────

-- Return the panel_line entry for the current cursor position.
local function current_line()
  if not state.panel_win or not vim.api.nvim_win_is_valid(state.panel_win) then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(state.panel_win)[1]
  return state.panel_lines[row]
end

-- Create and configure the panel scratch buffer with all keymaps.
-- Returns the buffer handle.
function M.create_buf()
  local buf = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_set_option_value("filetype", "git-diff-viewer-panel", { buf = buf })

  local km = config.options.keymaps

  -- Helper: set a buffer-local normal-mode keymap
  local function map(key, fn, desc)
    vim.keymap.set("n", key, fn, { buffer = buf, desc = desc, nowait = true })
  end

  -- Close viewer
  map(km.close, function()
    require("git-diff-viewer").close()
  end, "Close diff viewer")

  -- Refresh
  map(km.refresh, function()
    require("git-diff-viewer").refresh()
  end, "Refresh")

  -- Open file in previous tab
  map(km.open_file, function()
    local line = current_line()
    if line and line.type == "file" then
      local full_path = state.git_root .. "/" .. line.item.path
      -- Open in the tab that was active before the viewer
      vim.cmd("tabprevious")
      vim.cmd("edit " .. vim.fn.fnameescape(full_path))
    end
  end, "Open file in previous tab")

  -- Focus diff pane
  map(km.focus_diff, function()
    if state.diff_wins[1] and vim.api.nvim_win_is_valid(state.diff_wins[1]) then
      vim.api.nvim_set_current_win(state.diff_wins[1])
    end
  end, "Focus diff pane")

  -- Enter on file → open diff; Enter on folder → toggle
  map("<CR>", function()
    local line = current_line()
    if not line then return end

    if line.type == "file" then
      require("git-diff-viewer.ui.diff").open(line.item)
    elseif line.type == "folder" then
      -- Toggle expand/collapse
      local current = state.folder_expanded[line.path]
      state.folder_expanded[line.path] = current == false and true or false
      M.render()
    end
  end, "Open diff / toggle folder")

  -- Stage
  map(km.stage, function()
    local line = current_line()
    if not line then return end
    require("git-diff-viewer").stage_item(line)
  end, "Stage file/folder")

  -- Unstage
  map(km.unstage, function()
    local line = current_line()
    if not line then return end
    require("git-diff-viewer").unstage_item(line)
  end, "Unstage file/folder")

  -- Discard
  map(km.discard, function()
    local line = current_line()
    if not line then return end
    require("git-diff-viewer").discard_item(line)
  end, "Discard file/folder")

  -- Stage all
  map(km.stage_all, function()
    require("git-diff-viewer").stage_all()
  end, "Stage all")

  -- Unstage all
  map(km.unstage_all, function()
    require("git-diff-viewer").unstage_all()
  end, "Unstage all")

  -- Tab/S-Tab: cycle to next/previous file
  map(km.next_file, function()
    require("git-diff-viewer").next_file()
  end, "Next file")

  map(km.prev_file, function()
    require("git-diff-viewer").prev_file()
  end, "Previous file")

  -- Filter prompt (buffer-local, does not conflict with vim's / in other buffers)
  map(km.filter, function()
    vim.ui.input({ prompt = "Filter: ", default = state.filter }, function(input)
      if input == nil then
        -- Escape pressed — clear filter
        state.filter = ""
      else
        state.filter = input
      end
      M.render()
    end)
  end, "Filter files")

  state.panel_buf = buf
  return buf
end

return M
