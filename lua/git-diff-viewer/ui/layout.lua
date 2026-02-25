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

-- Open diff windows in the main area (right of the panel).
-- Closes any existing diff windows first.
-- count: 1 (single pane) or 2 (side-by-side)
-- Returns list of window handles.
function M.open_diff_wins(count)
  -- Prevent Neovim from equalizing window widths during open/close
  local ea = vim.o.equalalways
  vim.o.equalalways = false

  -- Close existing diff windows (but keep the panel)
  for _, w in ipairs(state.diff_wins) do
    if vim.api.nvim_win_is_valid(w) and w ~= state.panel_win then
      vim.api.nvim_win_close(w, true)
    end
  end
  state.diff_wins = {}
  state.diff_bufs = {}

  -- Use tracked main_win handle instead of fragile wincmd l
  local current_win
  if state.main_win and vim.api.nvim_win_is_valid(state.main_win) then
    current_win = state.main_win
    vim.api.nvim_set_current_win(current_win)
  elseif state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
    -- main_win was closed — create a new one via vsplit from panel
    vim.api.nvim_set_current_win(state.panel_win)
    vim.cmd("vsplit")
    current_win = vim.api.nvim_get_current_win()
    state.main_win = current_win
  else
    current_win = vim.api.nvim_get_current_win()
  end

  local wins = { current_win }

  if count == 2 then
    -- Split the current window vertically for the second pane
    vim.cmd("vsplit")
    table.insert(wins, vim.api.nvim_get_current_win())
    -- Focus the left (first) pane
    vim.api.nvim_set_current_win(wins[1])
  end

  state.diff_wins = wins

  -- Re-enforce panel width and restore equalalways
  if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
    vim.api.nvim_win_set_width(state.panel_win, config.options.panel_width)
  end
  vim.o.equalalways = ea

  return wins
end

return M
