-- layout.lua — Tab management, split creation, single-instance focus
--
-- The viewer lives in a dedicated Neovim tab.
-- If the tab already exists when open() is called, focus it instead.

local state = require("git-diff-viewer.state")
local config = require("git-diff-viewer.config")

local M = {}

-- Return true if the viewer tab still exists.
local function tab_is_valid()
  if not state.tab then return false end
  for _, t in ipairs(vim.api.nvim_list_tabpages()) do
    if t == state.tab then return true end
  end
  return false
end

-- Focus the existing viewer tab.
function M.focus()
  if tab_is_valid() then
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

  -- Create the panel as a left vertical split
  vim.cmd("topleft vsplit")
  local panel_win = vim.api.nvim_get_current_win()

  vim.api.nvim_win_set_width(panel_win, config.options.panel_width)

  -- Restore focus to the main area so callers can set up the panel from there
  vim.api.nvim_set_current_win(main_win)

  state.panel_win = panel_win
  state.diff_wins = {}
  state.diff_bufs = {}

  return { panel_win = panel_win, main_win = main_win }
end

-- Attach the panel buffer to the panel window.
function M.set_panel_buf(buf)
  state.panel_buf = buf
  if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
    vim.api.nvim_win_set_buf(state.panel_win, buf)
    vim.api.nvim_win_set_width(state.panel_win, config.options.panel_width)
  end
end

-- Close the viewer tab and clean up state.
function M.close()
  if tab_is_valid() then
    vim.cmd("tabclose")
  end
  -- State reset is handled in init.lua on TabClosed autocmd
end

-- Open diff windows in the main area (right of the panel).
-- Closes any existing diff windows first.
-- count: 1 (single pane) or 2 (side-by-side)
-- Returns list of window handles.
function M.open_diff_wins(count)
  -- Close existing diff windows (but keep the panel)
  for _, w in ipairs(state.diff_wins) do
    if vim.api.nvim_win_is_valid(w) and w ~= state.panel_win then
      vim.api.nvim_win_close(w, true)
    end
  end
  state.diff_wins = {}
  state.diff_bufs = {}

  -- Find or create the first diff window (the main area to the right)
  -- After closing old diff windows, we may need to create a new one.
  -- Focus the main area (to the right of the panel).
  if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
    -- Move focus away from panel to open splits in the right area
    vim.api.nvim_set_current_win(state.panel_win)
    vim.cmd("wincmd l") -- move to the right
  end

  -- If there's no window to the right, we're still in the panel — create one
  local current_win = vim.api.nvim_get_current_win()
  if current_win == state.panel_win then
    vim.cmd("vsplit")
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
  return wins
end

return M
