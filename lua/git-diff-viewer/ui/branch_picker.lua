-- branch_picker.lua — Floating branch picker for branch diff mode
--
-- Two-window layout (like finder.lua): editable input at the top, flat list below.
-- Fuzzy filters branches on input. Selecting a branch updates state and refreshes.

local M = {}

local state = require("git-diff-viewer.state")
local git = require("git-diff-viewer.git")
local utils = require("git-diff-viewer.utils")

function M.open()
  local cwd = state.git_root
  if not cwd then return end

  git.list_branches(cwd, function(ok, raw)
    vim.schedule(function()
      if not ok then
        utils.error("Failed to list branches")
        return
      end
      if not state.is_active() then return end

      -- Parse branch list
      local branches = {}
      for line in raw:gmatch("[^\n]+") do
        local name = vim.trim(line)
        -- Strip "origin/HEAD" entries (with or without " -> ..." suffix)
        if name ~= "" and not name:match("^origin/HEAD") then
          table.insert(branches, name)
        end
      end

      -- Sort: current target first, then alphabetical
      local target = state.target_branch
      table.sort(branches, function(a, b)
        if a == target then return true end
        if b == target then return false end
        return a < b
      end)

      M._show_picker(branches)
    end)
  end)
end

function M._show_picker(branches)
  -- Dimensions
  local width = math.min(80, vim.o.columns - 4)
  local list_height = math.min(#branches + 1, vim.o.lines - 6)
  local total_visual = list_height + 4
  local start_row = math.floor((vim.o.lines - total_visual) / 2)
  local start_col = math.floor((vim.o.columns - width) / 2)

  -- ── Input window (top) ──────────────────────────────────────────────────────
  local input_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[input_buf].bufhidden = "wipe"
  vim.bo[input_buf].buftype = "nofile"
  vim.bo[input_buf].filetype = "git-diff-viewer-branch-picker"
  vim.b[input_buf].completion = false
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })

  local input_win = vim.api.nvim_open_win(input_buf, true, {
    relative = "editor",
    row = start_row + 1,
    col = start_col,
    width = width,
    height = 1,
    style = "minimal",
    border = { "╭", "─", "╮", "│", "┤", "─", "├", "│" },
    title = " Select branch ",
    title_pos = "center",
  })
  vim.wo[input_win].winhl = "Normal:Normal,FloatBorder:Comment"
  vim.wo[input_win].number = false
  vim.wo[input_win].signcolumn = "no"

  -- ── List window (below) ─────────────────────────────────────────────────────
  local list_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[list_buf].bufhidden = "wipe"
  vim.bo[list_buf].buftype = "nofile"
  vim.bo[list_buf].modifiable = false

  local list_win = vim.api.nvim_open_win(list_buf, false, {
    relative = "editor",
    row = start_row + 3,
    col = start_col,
    width = width,
    height = list_height,
    style = "minimal",
    border = { "", "", "", "│", "╯", "─", "╰", "│" },
    focusable = false,
  })
  vim.wo[list_win].cursorline = true
  vim.wo[list_win].number = false
  vim.wo[list_win].signcolumn = "no"
  vim.wo[list_win].wrap = false
  vim.wo[list_win].winhl = "Normal:Normal"

  -- ── State ───────────────────────────────────────────────────────────────────
  local filtered_branches = {}
  local ns = vim.api.nvim_create_namespace("git_diff_viewer_branch_picker")

  local function get_filter()
    if not vim.api.nvim_buf_is_valid(input_buf) then return "" end
    return vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or ""
  end

  local function render_list(filter)
    if not vim.api.nvim_buf_is_valid(list_buf) then return end

    -- Filter and sort by match quality using Vim's built-in fuzzy scorer
    filtered_branches = utils.fuzzy_filter(branches, filter)

    -- Build display lines
    local lines = {}
    for _, branch in ipairs(filtered_branches) do
      local prefix = (branch == state.target_branch) and "* " or "  "
      table.insert(lines, prefix .. branch)
    end

    if #lines == 0 then
      table.insert(lines, "  No matching branches")
    end

    vim.bo[list_buf].modifiable = true
    vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, lines)
    vim.bo[list_buf].modifiable = false

    -- Highlights
    vim.api.nvim_buf_clear_namespace(list_buf, ns, 0, -1)
    for i, branch in ipairs(filtered_branches) do
      local line_idx = i - 1
      if branch == state.target_branch then
        vim.api.nvim_buf_add_highlight(list_buf, ns, "GitDiffViewerStatusA", line_idx, 0, 2)
      end
    end

    -- Cursor to first entry
    if vim.api.nvim_win_is_valid(list_win) and #filtered_branches > 0 then
      vim.api.nvim_win_set_cursor(list_win, { 1, 0 })
    end
  end

  -- ── Actions ─────────────────────────────────────────────────────────────────
  local aug = vim.api.nvim_create_augroup("GitDiffViewerBranchPicker", { clear = true })

  local function close()
    vim.api.nvim_clear_autocmds({ group = aug })
    vim.cmd("stopinsert")
    if vim.api.nvim_win_is_valid(list_win) then
      vim.api.nvim_win_close(list_win, true)
    end
    if vim.api.nvim_win_is_valid(input_win) then
      vim.api.nvim_win_close(input_win, true)
    end
    if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
      vim.api.nvim_set_current_win(state.panel_win)
    end
  end

  local function select_branch()
    if not vim.api.nvim_win_is_valid(list_win) then return end
    local row = vim.api.nvim_win_get_cursor(list_win)[1]
    local branch = filtered_branches[row]
    if not branch then return end

    close()

    -- Update state and refresh
    state.target_branch = branch
    state.buf_cache = {}
    require("git-diff-viewer").load_and_render_branch()
  end

  local function move_selection(delta)
    if not vim.api.nvim_win_is_valid(list_win) then return end
    local row = vim.api.nvim_win_get_cursor(list_win)[1]
    local total = #filtered_branches
    if total == 0 then return end
    local target = math.max(1, math.min(total, row + delta))
    vim.api.nvim_win_set_cursor(list_win, { target, 0 })
  end

  -- ── Live filtering ──────────────────────────────────────────────────────────
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = input_buf,
    group = aug,
    callback = function()
      if not vim.api.nvim_buf_is_valid(list_buf) then return end
      if not vim.api.nvim_buf_is_valid(input_buf) then return end
      render_list(get_filter())
    end,
  })

  -- Close if either window disappears
  vim.api.nvim_create_autocmd("WinClosed", {
    group = aug,
    callback = function(ev)
      local closed = tonumber(ev.match)
      if closed == input_win or closed == list_win then
        vim.schedule(close)
      end
    end,
  })

  -- ── Keymaps: insert mode ───────────────────────────────────────────────────
  local function imap(key, fn)
    vim.keymap.set("i", key, fn, { buffer = input_buf, nowait = true })
  end
  imap("<CR>",   select_branch)
  imap("<C-c>",  close)
  imap("<Down>", function() move_selection(1) end)
  imap("<Up>",   function() move_selection(-1) end)
  imap("<C-j>",  function() move_selection(1) end)
  imap("<C-k>",  function() move_selection(-1) end)
  imap("<C-n>",  function() move_selection(1) end)
  imap("<C-p>",  function() move_selection(-1) end)

  -- ── Keymaps: normal mode ───────────────────────────────────────────────────
  local function nmap(key, fn)
    vim.keymap.set("n", key, fn, { buffer = input_buf, nowait = true })
  end
  nmap("<CR>",   select_branch)
  nmap("<Esc>",  close)
  nmap("q",      close)
  nmap("<Down>", function() move_selection(1) end)
  nmap("<Up>",   function() move_selection(-1) end)
  nmap("j",      function() move_selection(1) end)
  nmap("k",      function() move_selection(-1) end)

  -- ── Initial render and enter insert mode ────────────────────────────────────
  render_list("")
  vim.cmd("startinsert!")
end

return M
