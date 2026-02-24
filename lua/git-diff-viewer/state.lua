-- state.lua — Single shared plugin state table
--
-- All mutable state lives here. No OOP — just a plain Lua table.
-- Modules read and write this directly; UI re-renders from it.

local M = {}

-- Reset to empty/initial state.
function M.reset()
  -- Git root directory for the current session
  M.git_root = nil

  -- Whether HEAD exists (false = empty repo with no commits)
  M.has_commits = false

  -- Structured file list:
  --   { conflicts = [...], changes = [...], staged = [...] }
  -- Each entry is a file_item table from parse.build_file_list()
  M.files = { conflicts = {}, changes = {}, staged = {} }

  -- Flat list of all currently visible panel lines for cursor mapping.
  -- Each entry: { type = "header"|"folder"|"file", ... }
  M.panel_lines = {}

  -- Folder expand/collapse state: path → boolean (true = expanded)
  -- Stored as flat path strings, e.g. "src/components"
  M.folder_expanded = {}

  -- Current filter string (empty = no filter)
  M.filter = ""

  -- Currently open diff:
  --   { item = file_item, section = "changes"|"staged"|"conflicts" }
  M.current_diff = nil

  -- Tab and window handles for the viewer tab
  M.tab = nil        -- tabpage handle
  M.panel_win = nil  -- left panel window
  M.panel_buf = nil  -- left panel buffer
  M.diff_wins = {}   -- list of diff window handles (1 or 2)
  M.diff_bufs = {}   -- list of diff buffer handles

  -- Cache of loaded git show buffers to avoid re-fetching.
  -- Key: "HEAD:src/app.ts" or ":0:src/app.ts"
  -- Value: buffer handle (number)
  M.buf_cache = {}

  -- File watcher handles for .git/index and .git/HEAD
  M.watchers = {}
end

-- Initialize on module load
M.reset()

return M
