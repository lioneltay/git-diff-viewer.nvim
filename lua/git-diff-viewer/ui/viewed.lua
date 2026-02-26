-- viewed.lua — Floating picker for recently viewed diffs
--
-- Shows a flat list of previously opened diffs (most recent first).
-- Selecting an entry re-opens that diff. Similar UI to finder.lua.

local M = {}

local state = require("git-diff-viewer.state")
local utils = require("git-diff-viewer.utils")
local ns = vim.api.nvim_create_namespace("git_diff_viewer_viewed")

function M.open()
  local diff = require("git-diff-viewer.ui.diff")

  if #state.viewed_diffs == 0 then
    utils.notify("No viewed diffs yet")
    return
  end

  -- Resolve viewed_diffs entries to actual items from sections
  local items = {}
  for _, vd in ipairs(state.viewed_diffs) do
    for _, sec in ipairs(state.sections) do
      for _, item in ipairs(sec.items) do
        if item.path == vd.path and item.section == vd.section then
          table.insert(items, item)
          goto found
        end
      end
    end
    ::found::
  end

  if #items == 0 then
    utils.notify("No viewed diffs available (files may have been resolved)")
    return
  end

  -- Dimensions
  local width = math.min(120, vim.o.columns - 4)
  local height = math.min(#items + 2, vim.o.lines - 6)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  -- Build display lines
  local lines = {}
  local highlights = {}
  for i, item in ipairs(items) do
    local status_char = utils.status_icon(item.xy, item.section)
    local section_label = item.section == "staged" and " [staged]"
      or item.section == "conflicts" and " [conflict]"
      or ""
    local line = "  " .. status_char .. "  " .. item.path .. section_label
    table.insert(lines, line)

    local line_idx = i - 1
    local path_start = 2 + #status_char + 2

    -- Status highlight
    table.insert(highlights, {
      line = line_idx,
      group = utils.get_status_hl(status_char),
      col_start = 2,
      col_end = 2 + #status_char,
    })

    -- Split path into folder prefix and filename
    local folder, filename = item.path:match("^(.+/)([^/]+)$")
    if folder then
      -- Dim folder prefix, bold filename
      table.insert(highlights, {
        line = line_idx,
        group = "GitDiffViewerDim",
        col_start = path_start,
        col_end = path_start + #folder,
      })
      table.insert(highlights, {
        line = line_idx,
        group = "GitDiffViewerFileName",
        col_start = path_start + #folder,
        col_end = path_start + #item.path,
      })
    else
      -- Root-level file
      table.insert(highlights, {
        line = line_idx,
        group = "GitDiffViewerFileName",
        col_start = path_start,
        col_end = path_start + #item.path,
      })
    end

    -- Section label highlight
    if section_label ~= "" then
      local label_start = path_start + #item.path
      table.insert(highlights, {
        line = line_idx,
        group = "GitDiffViewerDim",
        col_start = label_start,
        col_end = label_start + #section_label,
      })
    end
  end

  -- Create buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].modifiable = false

  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  -- Apply highlights
  for _, h in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(buf, ns, h.group, h.line, h.col_start, h.col_end)
  end

  -- Create window
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Viewed Diffs ",
    title_pos = "center",
  })
  vim.wo[win].cursorline = true
  vim.wo[win].winhl = "Normal:Normal,FloatBorder:Comment"

  -- Actions
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
      vim.api.nvim_set_current_win(state.panel_win)
    end
  end

  local function open_selected()
    local row_nr = vim.api.nvim_win_get_cursor(win)[1]
    local item = items[row_nr]
    if item then
      close()
      diff.open(item)
    end
  end

  -- Keymaps
  local function map(mode, key, fn)
    vim.keymap.set(mode, key, fn, { buffer = buf, nowait = true })
  end
  map("n", "<CR>", open_selected)
  map("n", "<Esc>", close)
  map("n", "q", close)
  map("n", "<leader>fb", close)
end

return M
