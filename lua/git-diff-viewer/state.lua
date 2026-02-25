-- state.lua — Single shared plugin state table
--
-- All mutable state lives here. No OOP — just a plain Lua table.
-- Modules read and write this directly; UI re-renders from it.

local M = {}

-- Generation counter for async callback staleness detection.
-- Monotonically increasing; never resets to 0.
-- Each load_and_render call gets a generation number; if state.generation
-- has moved on by the time the callback fires, the callback is stale.
M.generation = 0

--- Increment and return the next generation number.
function M.next_generation()
  M.generation = M.generation + 1
  return M.generation
end

-- Reset to empty/initial state.
function M.reset()
  -- Bug #15: Delete old panel buffer to prevent E95 name collision on reopen
  if M.panel_buf and vim.api.nvim_buf_is_valid(M.panel_buf) then
    pcall(vim.api.nvim_buf_delete, M.panel_buf, { force = true })
  end

  -- Git root directory for the current session
  M.git_root = nil

  -- Whether HEAD exists (false = empty repo with no commits)
  M.has_commits = false

  -- Unified file sections — ordered list of { key, label, items }
  -- Status mode: conflicts, changes, staged
  -- Branch mode: changes only
  -- Panel and finder iterate this directly — no mode-specific branching.
  M.sections = {}

  -- Flat list of all currently visible panel lines for cursor mapping.
  -- Each entry: { type = "header"|"folder"|"file", ... }
  M.panel_lines = {}

  -- Folder expand/collapse state: path → boolean (true = expanded)
  -- Stored as flat path strings, e.g. "src/components"
  M.folder_expanded = {}

  -- Section collapse state: section key → boolean (true = collapsed)
  M.section_collapsed = {}

  -- Currently open diff:
  --   { item = file_item, section = "changes"|"staged"|"conflicts" }
  M.current_diff = nil

  -- Tab and window handles for the viewer tab
  M.tab = nil         -- tabpage handle
  M.origin_tab = nil  -- tab we came from (for gf navigation)
  M.main_win = nil    -- main diff area window (right of panel)
  M.panel_win = nil   -- left panel window
  M.panel_buf = nil   -- left panel buffer
  M.diff_wins = {}    -- list of diff window handles (1 or 2)
  M.diff_bufs = {}    -- list of diff buffer handles

  -- Cache of loaded git show buffers to avoid re-fetching.
  -- Key: "HEAD:src/app.ts" or ":0:src/app.ts"
  -- Value: buffer handle (number)
  M.buf_cache = {}

  -- Buffers that have diff keymaps applied (for cleanup on close).
  -- Key: buffer handle, Value: true
  M.keymap_bufs = {}

  -- File watcher handles for .git/index and .git/HEAD
  M.watchers = {}

  -- Namespace for panel highlights
  M.ns = vim.api.nvim_create_namespace("git_diff_viewer_panel")
end

--- Return true if the viewer is currently active (tab exists and is valid).
function M.is_active()
  if not M.tab then return false end
  for _, t in ipairs(vim.api.nvim_list_tabpages()) do
    if t == M.tab then return true end
  end
  return false
end

-- Initialize on module load
M.reset()

return M
