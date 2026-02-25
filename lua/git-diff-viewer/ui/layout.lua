-- layout.lua — Tab management, split creation, single-instance focus
--
-- The viewer lives in a dedicated Neovim tab.
-- If the tab already exists when open() is called, focus it instead.

local state = require("git-diff-viewer.state")
local config = require("git-diff-viewer.config")

local M = {}

-- Focus the existing viewer tab.
function M.focus()
  if state.is_active() then
    vim.api.nvim_set_current_tabpage(state.tab)
    if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
      vim.api.nvim_set_current_win(state.panel_win)
    end
    return true
  end
  return false
end

-- Create the viewer tab and its two main windows.
-- Returns { panel_win, main_win } window handles.
--
-- Layout: [panel (left, fixed width)] | [main area (right, fills rest)]
-- The main area is where diff panes are opened.
function M.create_tab()
  -- Open a new tab with an empty scratch buffer in the main area
  vim.cmd("tabnew")
  state.tab = vim.api.nvim_get_current_tabpage()

  -- The new tab starts with one window; this becomes the main diff area
  local main_win = vim.api.nvim_get_current_win()

  -- tabnew always creates an unnamed listed buffer — hide it so it doesn't
  -- pollute the buffer list or tab label
  local initial_buf = vim.api.nvim_get_current_buf()
  vim.bo[initial_buf].buflisted = false
  vim.bo[initial_buf].buftype = "nofile"
  vim.bo[initial_buf].bufhidden = "wipe"

  -- Create the panel as a left vertical split
  vim.cmd("topleft vsplit")
  local panel_win = vim.api.nvim_get_current_win()

  vim.api.nvim_win_set_width(panel_win, config.options.panel_width)

  -- Restore focus to the main area so callers can set up the panel from there
  vim.api.nvim_set_current_win(main_win)

  state.main_win = main_win
  state.panel_win = panel_win
  state.diff_wins = {}
  state.diff_bufs = {}

  return { panel_win = panel_win, main_win = main_win }
end

-- Apply visual options to the panel window.
local function set_panel_win_opts(win)
  vim.api.nvim_set_option_value("cursorline", true, { win = win })
  vim.api.nvim_set_option_value("number", false, { win = win })
  vim.api.nvim_set_option_value("relativenumber", false, { win = win })
  vim.api.nvim_set_option_value("signcolumn", "no", { win = win })
  vim.api.nvim_set_option_value("wrap", false, { win = win })
  vim.api.nvim_set_option_value("winfixwidth", true, { win = win })
  vim.wo[win].winhl = "Normal:Normal,EndOfBuffer:Normal"
end

-- Attach the panel buffer to the panel window.
function M.set_panel_buf(buf)
  state.panel_buf = buf
  if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
    vim.api.nvim_win_set_buf(state.panel_win, buf)
    vim.api.nvim_win_set_width(state.panel_win, config.options.panel_width)
    set_panel_win_opts(state.panel_win)
  end
end

-- Close the viewer tab.
function M.close()
  if state.is_active() then
    -- Use the tab number (1-indexed position) for tabclose
    local tab_nr = vim.api.nvim_tabpage_get_number(state.tab)
    vim.cmd(tab_nr .. "tabclose")
  end
end

-- Count the number of valid diff windows.
local function valid_diff_win_count()
  local n = 0
  for _, w in ipairs(state.diff_wins) do
    if vim.api.nvim_win_is_valid(w) and w ~= state.panel_win then
      n = n + 1
    end
  end
  return n
end

-- Open diff windows in the main area (right of the panel).
-- Reuses existing windows when pane count matches to preserve jumplist (Ctrl-O/I).
-- count: 1 (single pane) or 2 (side-by-side)
-- Returns list of window handles.
function M.open_diff_wins(count)
  -- Bug #25: Prevent Neovim from equalizing window widths during open/close.
  -- Use pcall to guarantee equalalways is always restored even if operations throw.
  local ea = vim.o.equalalways
  vim.o.equalalways = false

  local ok, wins = pcall(function()
    local current_count = valid_diff_win_count()

    -- Reuse: if current pane count matches requested, keep windows for jumplist
    if current_count == count then
      state.diff_bufs = {}
      return state.diff_wins
    end

    -- Transition: 2 → 1 — close the second window, keep the first for jumplist
    if current_count == 2 and count == 1 then
      local w2 = state.diff_wins[2]
      if w2 and vim.api.nvim_win_is_valid(w2) then
        vim.api.nvim_win_close(w2, true)
      end
      state.diff_wins = { state.diff_wins[1] }
      state.diff_bufs = {}
      return state.diff_wins
    end

    -- Transition: 1 → 2 — split the existing window to add a second pane
    if current_count == 1 and count == 2 then
      local w1 = state.diff_wins[1]
      if w1 and vim.api.nvim_win_is_valid(w1) then
        vim.api.nvim_set_current_win(w1)
        vim.cmd("vsplit")
        local w2 = vim.api.nvim_get_current_win()
        vim.api.nvim_set_current_win(w1)
        state.diff_wins = { w1, w2 }
        state.diff_bufs = {}
        return state.diff_wins
      end
    end

    -- No existing windows (0 → N) or invalid state — create from scratch
    for _, w in ipairs(state.diff_wins) do
      if vim.api.nvim_win_is_valid(w) and w ~= state.panel_win then
        vim.api.nvim_win_close(w, true)
      end
    end
    state.diff_wins = {}
    state.diff_bufs = {}

    -- Use tracked main_win handle
    local current_win
    if state.main_win and vim.api.nvim_win_is_valid(state.main_win) then
      current_win = state.main_win
      vim.api.nvim_set_current_win(current_win)
    elseif state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
      vim.api.nvim_set_current_win(state.panel_win)
      vim.cmd("vsplit")
      current_win = vim.api.nvim_get_current_win()
      state.main_win = current_win
    else
      current_win = vim.api.nvim_get_current_win()
    end

    local w = { current_win }

    if count == 2 then
      vim.cmd("vsplit")
      table.insert(w, vim.api.nvim_get_current_win())
      vim.api.nvim_set_current_win(w[1])
    end

    state.diff_wins = w
    return w
  end)

  -- Always restore panel width and equalalways
  if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
    pcall(vim.api.nvim_win_set_width, state.panel_win, config.options.panel_width)
  end
  vim.o.equalalways = ea

  if not ok then error(wins) end
  return wins
end

return M
