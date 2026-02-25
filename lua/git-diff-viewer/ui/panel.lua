-- panel.lua — File panel: tree rendering, keymaps, cursor management
--
-- The panel is a scratch buffer that is fully re-rendered from state on every change.
-- Navigation state (folder expand, cursor position, filter) is stored in state.lua.

local state = require("git-diff-viewer.state")
local config = require("git-diff-viewer.config")
local utils = require("git-diff-viewer.utils")

local M = {}

-- ─── File icons via mini.icons ──────────────────────────────────────────────

local has_mini_icons, MiniIcons = pcall(require, "mini.icons")

-- Return icon string and highlight group for a filename, or nil if unavailable.
local function file_icon(filename)
  if not has_mini_icons then return nil, nil end
  local ok, icon, hl = pcall(MiniIcons.get, "file", filename)
  if ok and icon then
    return icon, hl
  end
  return nil, nil
end

-- ─── Rendering ────────────────────────────────────────────────────────────────

-- Build the tree structure from a flat list of file_items.
-- Groups files into folders, respecting the expand/collapse state.
--
-- Returns three values:
--   lines:      list of panel_line metadata (1:1 with buffer lines)
--   text:       list of display strings
--   highlights: list of { line, group, col_start, col_end } for nvim_buf_add_highlight
local function build_lines(sections, opts)
  opts = opts or {}
  local filter = opts.filter or ""
  local force_expanded = opts.force_expanded or false

  local lines = {}      -- panel_line metadata
  local text = {}       -- display strings
  local highlights = {} -- { line_idx (0-based), group, col_start, col_end }

  local function add(line, display)
    table.insert(lines, line)
    table.insert(text, display)
  end

  -- Helper: record a highlight. line_idx is 0-based.
  local function hl(group, line_idx, col_start, col_end)
    table.insert(highlights, { line = line_idx, group = group, col_start = col_start, col_end = col_end })
  end

  -- Determine the currently-open file path+section for active highlighting
  local active_path, active_section
  if state.current_diff and state.current_diff.item then
    active_path = state.current_diff.item.path
    active_section = state.current_diff.item.section
  end

  -- Header: repo path + help hint (only in panel, not in finder)
  if not opts.skip_header then
    local root = state.git_root or ""
    local basename = root:match("[^/]+$") or root
    local display_path = (#root > #basename) and (".../" .. basename) or root
    local path_line_idx = #text
    add({ type = "header" }, " " .. display_path)
    hl("GitDiffViewerDim", path_line_idx, 0, -1)
    local hint_line_idx = #text
    add({ type = "header" }, " Help: g?")
    hl("GitDiffViewerDim", hint_line_idx, 0, -1)
    add({ type = "header" }, "")
  end

  local any_content = false

  for _, sec in ipairs(sections) do
    local items = sec.items or {}

    local filtered = {}
    for _, item in ipairs(items) do
      if filter == "" or item.path:lower():find(filter:lower(), 1, true) then
        table.insert(filtered, item)
      end
    end

    if #filtered == 0 then
      goto continue
    end

    any_content = true

    -- Section header: "  ▾ Changes (3)" or "  ▸ Changes (3)"
    local is_collapsed = not force_expanded and state.section_collapsed[sec.key] == true
    local chevron = is_collapsed and "▸" or "▾"
    local count_str = "(" .. #filtered .. ")"
    local header_text = "  " .. chevron .. " " .. sec.label .. " " .. count_str
    local line_idx = #text -- 0-based index for the line about to be added
    add(
      { type = "section_header", label = sec.label, section = sec.key, collapsed = is_collapsed },
      header_text
    )
    -- Chevron: cols 2 to 2+#chevron (byte length)
    hl("GitDiffViewerFolderIcon", line_idx, 2, 2 + #chevron)
    -- Label: after "  ▾ "
    local label_start = 2 + #chevron + 1
    hl("GitDiffViewerSectionHeader", line_idx, label_start, label_start + #sec.label)
    -- Count: after label + space
    local count_start = label_start + #sec.label + 1
    hl("GitDiffViewerSectionCount", line_idx, count_start, count_start + #count_str)

    -- Skip folder/file rendering if section is collapsed
    if is_collapsed then goto continue end

    -- Build folder tree for this section
    local folder_seen = {}

    for _, item in ipairs(filtered) do
      local rel = item.path
      local parts = utils.split_path(rel)
      local dirs = parts.dirs

      -- Emit folder nodes for each directory segment (depth-first, no duplicates).
      for d = 1, #dirs do
        local ancestor_collapsed = false
        for ad = 1, d - 1 do
          local ap = utils.dirs_to_path({ unpack(dirs, 1, ad) })
          if state.folder_expanded[ap] == false then
            ancestor_collapsed = true
            break
          end
        end
        if ancestor_collapsed then break end

        local folder_path = utils.dirs_to_path({ unpack(dirs, 1, d) })
        if not folder_seen[folder_path] then
          folder_seen[folder_path] = true
          local is_expanded = force_expanded or state.folder_expanded[folder_path] ~= false
          local indent = string.rep("  ", d + 1)
          local chevron = is_expanded and "▾" or "▸"
          local folder_name = dirs[d]
          local folder_text = indent .. chevron .. " " .. folder_name .. "/"

          line_idx = #text
          add(
            { type = "folder", path = folder_path, depth = d, expanded = is_expanded },
            folder_text
          )
          -- Highlight chevron
          local chevron_start = #indent
          local chevron_end = chevron_start + #chevron
          hl("GitDiffViewerFolderIcon", line_idx, chevron_start, chevron_end)
          -- Highlight folder name (after "chevron ")
          local name_start = chevron_end + 1
          hl("GitDiffViewerFolderName", line_idx, name_start, name_start + #folder_name + 1) -- +1 for "/"
        end
      end

      -- Check if this file should be visible (all parent folders expanded)
      local visible = true
      if not force_expanded then
        for d = 1, #dirs do
          local fp = utils.dirs_to_path({ unpack(dirs, 1, d) })
          if state.folder_expanded[fp] == false then
            visible = false
            break
          end
        end
      end

      if visible then
        local depth = #dirs
        local indent = string.rep("  ", depth + 2)
        local status_char = utils.status_icon(item.xy, item.section)
        local name = parts.file

        -- Rename: show "old_name → new_name" for the filename part
        if item.orig_path then
          local old_parts = utils.split_path(item.orig_path)
          name = old_parts.file .. " → " .. name
        end

        -- Build the line piece by piece, tracking column positions
        local col = 0
        local line_parts = {}

        -- Indent
        table.insert(line_parts, indent)
        col = col + #indent

        -- Status character
        local status_col = col
        table.insert(line_parts, status_char)
        col = col + #status_char

        -- Gap after status
        table.insert(line_parts, "  ")
        col = col + 2

        -- File icon (from mini.icons)
        local icon, icon_hl = file_icon(parts.file)
        local icon_col
        if icon then
          icon_col = col
          table.insert(line_parts, icon .. " ")
          col = col + #icon + 1
        end

        -- Filename
        local name_col = col
        table.insert(line_parts, name)
        col = col + #name

        -- +/- counts
        local added_str = item.added and item.added > 0 and ("+" .. item.added) or nil
        local removed_str = item.removed and item.removed > 0 and ("-" .. item.removed) or nil
        local added_col, removed_col
        if added_str or removed_str then
          table.insert(line_parts, "  ")
          col = col + 2
          if added_str then
            added_col = col
            table.insert(line_parts, added_str)
            col = col + #added_str
            if removed_str then
              table.insert(line_parts, " ")
              col = col + 1
            end
          end
          if removed_str then
            removed_col = col
            table.insert(line_parts, removed_str)
            col = col + #removed_str
          end
        end

        -- Binary / submodule annotation
        local dim_col
        local dim_text
        if item.binary then
          dim_text = "[binary]"
        elseif item.submodule then
          dim_text = "[submodule]"
        end
        if dim_text then
          table.insert(line_parts, "  ")
          col = col + 2
          dim_col = col
          table.insert(line_parts, dim_text)
          col = col + #dim_text
        end

        local label = table.concat(line_parts)
        line_idx = #text
        add({ type = "file", item = item, depth = depth }, label)

        -- Apply highlights
        hl(utils.get_status_hl(status_char), line_idx, status_col, status_col + #status_char)

        if icon_col and icon_hl then
          hl(icon_hl, line_idx, icon_col, icon_col + #icon)
        end

        local is_active = (item.path == active_path and item.section == active_section)
        local name_hl = is_active and "GitDiffViewerFileNameActive" or "GitDiffViewerFileName"
        hl(name_hl, line_idx, name_col, name_col + #name)

        if added_col and added_str then
          hl("GitDiffViewerInsertions", line_idx, added_col, added_col + #added_str)
        end
        if removed_col and removed_str then
          hl("GitDiffViewerDeletions", line_idx, removed_col, removed_col + #removed_str)
        end
        if dim_col and dim_text then
          hl("GitDiffViewerDim", line_idx, dim_col, dim_col + #dim_text)
        end
      end
    end

    ::continue::
  end

  if not any_content then
    add({ type = "empty" }, "  No changes")
  end

  return lines, text, highlights
end

-- Expose for use by finder.lua
M.build_lines = build_lines

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
  local lines, text, highlights = build_lines(state.sections)
  state.panel_lines = lines

  -- Write to buffer (temporarily make modifiable)
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, text)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  -- Apply highlights
  local ns = state.ns
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(buf, ns, h.group, h.line, h.col_start, h.col_end)
  end

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
  vim.api.nvim_buf_set_name(buf, "GitDiffViewer")

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

  -- Open file in the originating tab
  map(km.open_file, function()
    local line = current_line()
    if line and line.type == "file" then
      local full_path = state.git_root .. "/" .. line.item.path
      -- Bug #12: use tracked origin tab instead of tabprevious
      if state.origin_tab and vim.api.nvim_tabpage_is_valid(state.origin_tab) then
        vim.api.nvim_set_current_tabpage(state.origin_tab)
      else
        vim.cmd("tabprevious")
      end
      vim.cmd("edit " .. vim.fn.fnameescape(full_path))
    end
  end, "Open file in previous tab")

  -- Focus diff pane, or fall through to tmux navigation if no diff is open
  map(km.focus_diff, function()
    if state.diff_wins[1] and vim.api.nvim_win_is_valid(state.diff_wins[1]) then
      vim.api.nvim_set_current_win(state.diff_wins[1])
    elseif vim.fn.exists(":TmuxNavigateRight") == 2 then
      vim.cmd("TmuxNavigateRight")
    else
      vim.cmd("wincmd l")
    end
  end, "Focus diff pane")

  -- Enter on file → open diff; Enter on folder/section → toggle collapse
  map("<CR>", function()
    local line = current_line()
    if not line then return end

    if line.type == "file" then
      require("git-diff-viewer.ui.diff").open(line.item)
    elseif line.type == "folder" then
      local current = state.folder_expanded[line.path]
      state.folder_expanded[line.path] = current == false and true or false
      M.render()
    elseif line.type == "section_header" then
      state.section_collapsed[line.section] = not state.section_collapsed[line.section]
      M.render()
    end
  end, "Open diff / toggle folder / toggle section")

  -- Stage
  map(km.stage, function()
    local line = current_line()
    if not line then return end
    require("git-diff-viewer.operations").stage_item(line)
  end, "Stage file/folder")

  -- Unstage
  map(km.unstage, function()
    local line = current_line()
    if not line then return end
    require("git-diff-viewer.operations").unstage_item(line)
  end, "Unstage file/folder")

  -- Discard
  map(km.discard, function()
    local line = current_line()
    if not line then return end
    require("git-diff-viewer.operations").discard_item(line)
  end, "Discard file/folder")

  -- Stage all
  map(km.stage_all, function()
    require("git-diff-viewer.operations").stage_all()
  end, "Stage all")

  -- Unstage all
  map(km.unstage_all, function()
    require("git-diff-viewer.operations").unstage_all()
  end, "Unstage all")

  -- Tab/S-Tab: cycle to next/previous file
  map(km.next_file, function()
    require("git-diff-viewer").next_file()
  end, "Next file")

  map(km.prev_file, function()
    require("git-diff-viewer").prev_file()
  end, "Previous file")

  -- Open floating tree picker
  map("<leader>ff", function()
    require("git-diff-viewer.ui.finder").open()
  end, "Find changed files")

  -- Open viewed diffs picker
  map("<leader>fb", function()
    require("git-diff-viewer.ui.viewed").open()
  end, "Browse viewed diffs")

  -- Help popup
  map("g?", function()
    local lines = {
      "  Git Diff Viewer",
      "",
      "  Panel",
      "  <CR>       open diff / toggle folder / toggle section",
      "  s          stage file or folder",
      "  u          unstage file or folder",
      "  S          stage all",
      "  U          unstage all",
      "  x          discard changes",
      "  <Tab>      next file",
      "  <S-Tab>    previous file",
      "  gf         open file in previous tab",
      "  <C-l>      focus diff pane",
      "  <leader>ff fuzzy find changed files",
      "  R          refresh",
      "  q          close",
      "",
      "  Diff pane",
      "  q          close diff",
      "  gf         open file in previous tab",
      "  <C-h>      focus panel",
      "",
      "  Press q or <Esc> to close",
    }
    local width = 54
    local height = #lines
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)
    local help_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(help_buf, 0, -1, false, lines)
    vim.bo[help_buf].modifiable = false
    vim.bo[help_buf].bufhidden = "wipe"
    local help_win = vim.api.nvim_open_win(help_buf, true, {
      relative = "editor",
      row = row, col = col,
      width = width, height = height,
      style = "minimal",
      border = "rounded",
      title = " Help ",
      title_pos = "center",
    })
    vim.wo[help_win].winhl = "Normal:Normal,FloatBorder:Comment"
    local function close_help()
      if vim.api.nvim_win_is_valid(help_win) then
        vim.api.nvim_win_close(help_win, true)
      end
    end
    vim.keymap.set("n", "q", close_help, { buffer = help_buf, nowait = true })
    vim.keymap.set("n", "<Esc>", close_help, { buffer = help_buf, nowait = true })
  end, "Show help")

  state.panel_buf = buf
  return buf
end

return M
