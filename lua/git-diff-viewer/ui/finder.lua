-- finder.lua — Floating filtered tree picker
--
-- Two-window layout: editable input at the top, read-only tree below.
-- Arrow keys move the selection in the tree. Enter opens the selected file.
-- Standard vim editing works in the input (cc to clear, etc).

local M = {}

local state = require("git-diff-viewer.state")
local ns = vim.api.nvim_create_namespace("git_diff_viewer_finder")

function M.open()
  local panel = require("git-diff-viewer.ui.panel")
  local diff = require("git-diff-viewer.ui.diff")

  -- Dimensions
  local width = math.min(100, vim.o.columns - 4)
  local tree_height = vim.o.lines - 6
  -- Total visual height: top border(1) + input(1) + separator(1) + tree(tree_height) + bottom border(1)
  local total_visual = tree_height + 4
  local start_row = math.floor((vim.o.lines - total_visual) / 2)
  local start_col = math.floor((vim.o.columns - width) / 2)

  -- ── Input window (top) ──────────────────────────────────────────────────────
  local input_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[input_buf].bufhidden = "wipe"
  vim.bo[input_buf].buftype = "nofile"
  vim.bo[input_buf].filetype = "git-diff-viewer-finder"
  vim.bo[input_buf].complete = ""
  vim.bo[input_buf].omnifunc = ""
  vim.bo[input_buf].completefunc = ""
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })

  local input_win = vim.api.nvim_open_win(input_buf, true, {
    relative = "editor",
    row = start_row + 1,
    col = start_col,
    width = width,
    height = 1,
    style = "minimal",
    border = { "╭", "─", "╮", "│", "┤", "─", "├", "│" },
    title = " Changed files ",
    title_pos = "center",
  })
  vim.wo[input_win].winhl = "Normal:Normal,FloatBorder:Comment"
  vim.wo[input_win].number = false
  vim.wo[input_win].signcolumn = "no"

  -- ── Tree window (below) ─────────────────────────────────────────────────────
  local tree_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[tree_buf].bufhidden = "wipe"
  vim.bo[tree_buf].buftype = "nofile"
  vim.bo[tree_buf].modifiable = false

  local tree_win = vim.api.nvim_open_win(tree_buf, false, {
    relative = "editor",
    row = start_row + 3, -- input content(1) + separator border(1) offset from start_row+1
    col = start_col,
    width = width,
    height = tree_height,
    style = "minimal",
    border = { "", "", "", "│", "╯", "─", "╰", "│" },
    focusable = false,
  })
  vim.wo[tree_win].cursorline = true
  vim.wo[tree_win].number = false
  vim.wo[tree_win].signcolumn = "no"
  vim.wo[tree_win].wrap = false
  vim.wo[tree_win].winhl = "Normal:Normal"

  -- ── State ───────────────────────────────────────────────────────────────────
  local finder_lines = {}
  local rendering = false

  local function get_filter()
    if not vim.api.nvim_buf_is_valid(input_buf) then return "" end
    return vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or ""
  end

  local function render_tree(filter)
    if rendering then return end
    if not vim.api.nvim_buf_is_valid(tree_buf) then return end
    rendering = true

    local lines, text, hls = panel.build_lines(state.sections, {
      filter = filter,
      force_expanded = true,
      skip_header = true,
    })
    finder_lines = lines

    vim.bo[tree_buf].modifiable = true
    vim.api.nvim_buf_set_lines(tree_buf, 0, -1, false, text)
    vim.bo[tree_buf].modifiable = false

    vim.api.nvim_buf_clear_namespace(tree_buf, ns, 0, -1)
    for _, h in ipairs(hls) do
      vim.api.nvim_buf_add_highlight(tree_buf, ns, h.group, h.line, h.col_start, h.col_end)
    end

    -- Move tree cursor to first file
    if vim.api.nvim_win_is_valid(tree_win) then
      for i, line in ipairs(finder_lines) do
        if line.type == "file" then
          vim.api.nvim_win_set_cursor(tree_win, { i, 0 })
          break
        end
      end
    end

    rendering = false
  end

  -- ── Actions ─────────────────────────────────────────────────────────────────
  local aug = vim.api.nvim_create_augroup("GitDiffViewerFinder", { clear = true })

  local function close()
    vim.api.nvim_clear_autocmds({ group = aug })
    vim.cmd("stopinsert")
    if vim.api.nvim_win_is_valid(tree_win) then
      vim.api.nvim_win_close(tree_win, true)
    end
    if vim.api.nvim_win_is_valid(input_win) then
      vim.api.nvim_win_close(input_win, true)
    end
    if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
      vim.api.nvim_set_current_win(state.panel_win)
    end
  end

  local function open_selected()
    if not vim.api.nvim_win_is_valid(tree_win) then return end
    local row = vim.api.nvim_win_get_cursor(tree_win)[1]
    local line = finder_lines[row]
    if line and line.type == "file" then
      close()
      diff.open(line.item)
    end
  end

  local function move_selection(delta)
    if not vim.api.nvim_win_is_valid(tree_win) then return end
    local row = vim.api.nvim_win_get_cursor(tree_win)[1]
    local total = #finder_lines
    local target = row + delta
    while target >= 1 and target <= total do
      if finder_lines[target] and finder_lines[target].type == "file" then
        vim.api.nvim_win_set_cursor(tree_win, { target, 0 })
        return
      end
      target = target + delta
    end
  end

  -- ── Live filtering ──────────────────────────────────────────────────────────
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = input_buf,
    group = aug,
    callback = function()
      vim.schedule(function()
        render_tree(get_filter())
      end)
    end,
  })

  -- Close if either window disappears
  vim.api.nvim_create_autocmd("WinClosed", {
    group = aug,
    callback = function(ev)
      local closed = tonumber(ev.match)
      if closed == input_win or closed == tree_win then
        vim.schedule(close)
      end
    end,
  })

  -- ── Keymaps: insert mode ───────────────────────────────────────────────────
  local function imap(key, fn)
    vim.keymap.set("i", key, fn, { buffer = input_buf, nowait = true })
  end
  imap("<CR>",   open_selected)
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
  nmap("<CR>",       open_selected)
  nmap("<Esc>",      close)
  nmap("q",          close)
  nmap("<Down>",     function() move_selection(1) end)
  nmap("<Up>",       function() move_selection(-1) end)
  nmap("j",          function() move_selection(1) end)
  nmap("k",          function() move_selection(-1) end)
  nmap("<leader>ff", close)

  -- ── Initial render and enter insert mode ────────────────────────────────────
  render_tree("")
  vim.cmd("startinsert!")
end

return M
