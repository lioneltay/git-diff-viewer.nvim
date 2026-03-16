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

-- ─── Tree building and compaction ─────────────────────────────────────────────

-- Build a tree from a flat list of file items.
-- Returns root node: { display_name, full_path, children = {name → node}, files = [items], child_order = [names] }
local function build_tree(items)
  local root = { display_name = "", full_path = "", children = {}, files = {}, child_order = {} }
  for _, item in ipairs(items) do
    local parts = utils.split_path(item.path)
    local node = root
    for _, dir in ipairs(parts.dirs) do
      if not node.children[dir] then
        local child_path = node.full_path == "" and dir or (node.full_path .. "/" .. dir)
        node.children[dir] = {
          display_name = dir,
          full_path = child_path,
          children = {},
          files = {},
          child_order = {},
        }
        table.insert(node.child_order, dir)
      end
      node = node.children[dir]
    end
    table.insert(node.files, item)
  end
  return root
end

-- Compact single-child folder chains.
-- If a folder has exactly 1 child folder and 0 files, merge into "parent/child/".
local function compact_tree(node)
  -- First compact children recursively
  for _, name in ipairs(node.child_order) do
    compact_tree(node.children[name])
  end

  -- Compact: if exactly 1 child folder and 0 files, merge
  if #node.child_order == 1 and #node.files == 0 and node.full_path ~= "" then
    local child_name = node.child_order[1]
    local child = node.children[child_name]
    node.display_name = node.display_name .. "/" .. child.display_name
    node.full_path = child.full_path
    node.children = child.children
    node.files = child.files
    node.child_order = child.child_order
  end
end

-- ─── Rendering ────────────────────────────────────────────────────────────────

-- Build the panel lines from sections.
-- Groups files into folders with compact single-child chains.
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
    -- Branch mode: show target branch line
    if state.mode == "branch" and state.target_branch then
      local target_line_idx = #text
      local target_text = " Target: " .. state.target_branch
      add({ type = "header" }, target_text)
      hl("GitDiffViewerSectionHeader", target_line_idx, 0, -1)
    end

    local hint_line_idx = #text
    add({ type = "header" }, " Help: g?")
    hl("GitDiffViewerDim", hint_line_idx, 0, -1)
    add({ type = "header" }, "")
  end

  -- Emit a file line with status icon, file icon, name, counts, annotations
  local function emit_file(item, depth)
    local parts = utils.split_path(item.path)
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
    local line_idx = #text
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

  -- Recursively render a tree node (folder children + files)
  local function render_node(node, depth)
    -- Render child folders (sorted by insertion order, preserved via child_order)
    for _, child_name in ipairs(node.child_order) do
      local child = node.children[child_name]
      local is_expanded = force_expanded or state.folder_expanded[child.full_path] ~= false
      local indent = string.rep("  ", depth + 1)
      local chevron = is_expanded and "▾" or "▸"
      local folder_display = child.display_name .. "/"
      local folder_text = indent .. chevron .. " " .. folder_display

      local line_idx = #text
      add(
        { type = "folder", path = child.full_path, depth = depth, expanded = is_expanded },
        folder_text
      )
      -- Highlight chevron
      local chevron_start = #indent
      local chevron_end = chevron_start + #chevron
      hl("GitDiffViewerFolderIcon", line_idx, chevron_start, chevron_end)
      -- Highlight folder name (after "chevron ")
      local name_start = chevron_end + 1
      hl("GitDiffViewerFolderName", line_idx, name_start, name_start + #folder_display)

      if is_expanded then
        render_node(child, depth + 1)
      end
    end

    -- Render files at this level
    for _, item in ipairs(node.files) do
      emit_file(item, depth)
    end
  end

  local any_content = false

  for _, sec in ipairs(sections) do
    local items = sec.items or {}

    local filtered = {}
    for _, item in ipairs(items) do
      if filter == "" or utils.fuzzy_match(item.path, filter) then
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
    local line_idx = #text
    add(
      { type = "section_header", label = sec.label, section = sec.key, collapsed = is_collapsed },
      header_text
    )
    hl("GitDiffViewerFolderIcon", line_idx, 2, 2 + #chevron)
    local label_start = 2 + #chevron + 1
    hl("GitDiffViewerSectionHeader", line_idx, label_start, label_start + #sec.label)
    local count_start = label_start + #sec.label + 1
    hl("GitDiffViewerSectionCount", line_idx, count_start, count_start + #count_str)

    -- Skip folder/file rendering if section is collapsed
    if is_collapsed then goto continue end

    -- Build tree → compact → render
    local tree = build_tree(filtered)
    compact_tree(tree)
    render_node(tree, 0)

    ::continue::
  end

  if not any_content then
    add({ type = "empty" }, "  No changes")
  end

  return lines, text, highlights
end

-- Expose for use by finder.lua
M.build_lines = build_lines

-- Previous render key for change detection — skip redundant buffer writes.
local prev_render_key = nil

-- Render the panel buffer from current state.
-- Preserves cursor line number (cursor stays at same line after re-render).
function M.render()
  local buf = state.panel_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  -- Save cursor position and the file under cursor (before rebuild)
  local cursor_line = 1
  local cursor_item_path = nil
  local cursor_item_section = nil
  if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
    cursor_line = vim.api.nvim_win_get_cursor(state.panel_win)[1]
    local old_line = state.panel_lines[cursor_line]
    if old_line and old_line.type == "file" and old_line.item then
      cursor_item_path = old_line.item.path
      cursor_item_section = old_line.item.section
    end
  end

  -- Build new content
  local lines, text, highlights = build_lines(state.sections)
  state.panel_lines = lines

  -- Skip buffer write if content and active highlight are unchanged — avoids
  -- undo entries, extmark churn, cursor resets, and autocmd triggers
  -- (TextChanged etc.) that other plugins may react to.
  local active_key = ""
  if state.current_diff and state.current_diff.item then
    active_key = state.current_diff.item.path .. ":" .. state.current_diff.item.section
  end
  local render_key = table.concat(text, "\n") .. "\0" .. active_key
  if render_key == prev_render_key then
    return
  end
  prev_render_key = render_key

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

  -- Restore cursor: try to keep it on the same file, fall back to same line number.
  if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
    local target_line = nil

    local follow_path = cursor_item_path

    if follow_path then
      -- Find the file the cursor was on, matching both path and section.
      -- This prevents the cursor from following a file when it moves between
      -- sections (e.g. staging moves a file from "changes" to "staged").
      for i, line in ipairs(lines) do
        if line.type == "file" and line.item.path == follow_path and line.item.section == cursor_item_section then
          target_line = i
          break
        end
      end
    end

    if not target_line then
      local line_count = vim.api.nvim_buf_line_count(buf)
      target_line = math.min(cursor_line, line_count)
      target_line = math.max(target_line, 1)
    end
    vim.api.nvim_win_set_cursor(state.panel_win, { target_line, 0 })
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
  prev_render_key = nil
  local buf = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.bo[buf].undolevels = -1
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

  -- Stage/unstage/discard keymaps — only in status mode
  if state.mode ~= "branch" then
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
  end

  -- Branch mode: change target branch
  if state.mode == "branch" then
    local bk = config.options.branch_keymaps
    map(bk.change_branch, function()
      require("git-diff-viewer.ui.branch_picker").open()
    end, "Change target branch")
  end

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
    local help_lines
    if state.mode == "branch" then
      help_lines = {
        "  Git Diff Viewer (Branch Mode)",
        "  Target: " .. (state.target_branch or "?"),
        "",
        "  Panel",
        "  <CR>       open diff / toggle folder / toggle section",
        "  b          change target branch",
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
        "  <leader>ff fuzzy find changed files",
        "  <leader>fb browse viewed diffs",
        "",
        "  Press q or <Esc> to close",
      }
    else
      help_lines = {
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
        "  <leader>ff fuzzy find changed files",
        "  <leader>fb browse viewed diffs",
        "",
        "  Press q or <Esc> to close",
      }
    end
    local lines = help_lines
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
