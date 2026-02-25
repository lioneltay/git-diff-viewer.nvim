-- init.lua — Entry point: setup(), open(), close(), refresh(), navigation
--
-- Single-instance: only one viewer tab open at a time.
-- All git work is async (vim.system → on_exit → vim.schedule).
-- Operations (stage/unstage/discard) are in operations.lua.

local M = {}

local config = require("git-diff-viewer.config")
local state = require("git-diff-viewer.state")
local git = require("git-diff-viewer.git")
local parse = require("git-diff-viewer.parse")
local utils = require("git-diff-viewer.utils")
local layout = require("git-diff-viewer.ui.layout")
local panel = require("git-diff-viewer.ui.panel")
local diff = require("git-diff-viewer.ui.diff")
local operations = require("git-diff-viewer.operations")

-- Augroup for all plugin autocmds — ensures clean teardown on close/reopen
local augroup = vim.api.nvim_create_augroup("GitDiffViewer", { clear = true })

-- ─── Setup ────────────────────────────────────────────────────────────────────

function M.setup(opts)
  config.setup(opts)
  utils.setup_highlights()
end

-- ─── Internal: load git data and render ───────────────────────────────────────

-- Bug #3: After sections are rebuilt, update current_diff to reference
-- the new item object (by path+section match, then path-only fallback).
local function reconcile_current_diff()
  if not state.current_diff or not state.current_diff.item then return end
  local cd = state.current_diff.item
  -- Exact match: same path and section
  for _, sec in ipairs(state.sections) do
    for _, item in ipairs(sec.items) do
      if item.path == cd.path and item.section == cd.section then
        state.current_diff = { item = item }
        return
      end
    end
  end
  -- Fallback: item may have moved sections (e.g., staged after staging)
  for _, sec in ipairs(state.sections) do
    for _, item in ipairs(sec.items) do
      if item.path == cd.path then
        state.current_diff = { item = item }
        return
      end
    end
  end
  -- Item no longer exists — clear
  state.current_diff = nil
end

-- After refresh, prune viewed_diffs entries that no longer exist in any section.
local function reconcile_viewed_diffs()
  local all_paths = {}
  for _, sec in ipairs(state.sections) do
    for _, item in ipairs(sec.items) do
      all_paths[item.path .. ":" .. item.section] = true
    end
  end
  local pruned = {}
  for _, vd in ipairs(state.viewed_diffs) do
    if all_paths[vd.path .. ":" .. vd.section] then
      table.insert(pruned, vd)
    end
  end
  state.viewed_diffs = pruned
end

-- Fetch git status + numstat in parallel, then render the panel.
-- Called on open and on refresh.
-- Uses generation counter to discard stale callbacks.
function M.load_and_render()
  local cwd = state.git_root
  local gen = state.next_generation()

  local status_raw = nil
  local unstaged_raw = nil
  local staged_raw = nil
  local errors = {}
  local pending = 3

  local function try_render()
    pending = pending - 1
    if pending > 0 then return end

    -- Stale callback — a newer load_and_render was started
    if state.generation ~= gen then return end

    -- If any git command failed, show error and bail
    if #errors > 0 then
      utils.error("Git error: " .. table.concat(errors, "; "))
      return
    end

    -- Viewer closed while we were loading
    if not state.is_active() then return end

    -- Parse everything on the main thread (inside vim.schedule)
    local entries = parse.parse_status(status_raw or "")
    local unstaged_numstat = parse.parse_numstat(unstaged_raw or "")
    local staged_numstat = parse.parse_numstat(staged_raw or "")

    local files = parse.build_file_list(entries, unstaged_numstat, staged_numstat)
    state.sections = {
      { key = "conflicts", label = "Merge Conflicts", items = files.conflicts },
      { key = "changes",   label = "Changes",         items = files.changes },
      { key = "staged",    label = "Staged Changes",  items = files.staged },
    }
    reconcile_current_diff()
    reconcile_viewed_diffs()
    panel.render()
  end

  git.status(cwd, function(ok, raw)
    vim.schedule(function()
      if not ok then
        table.insert(errors, "status: " .. (raw or "unknown"))
      else
        status_raw = raw
      end
      try_render()
    end)
  end)

  git.diff_numstat(cwd, function(ok, raw)
    vim.schedule(function()
      if not ok then
        table.insert(errors, "diff numstat: " .. (raw or "unknown"))
      else
        unstaged_raw = raw
      end
      try_render()
    end)
  end)

  git.diff_cached_numstat(cwd, function(ok, raw)
    vim.schedule(function()
      if not ok then
        table.insert(errors, "diff cached numstat: " .. (raw or "unknown"))
      else
        staged_raw = raw
      end
      try_render()
    end)
  end)
end

-- Wire the refresh callback so operations can trigger load_and_render
operations.refresh = function()
  M.load_and_render()
end

-- ─── Autocmd lifecycle ──────────────────────────────────────────────────────

-- Forward declaration
local teardown_autocmds

-- Debounced refresh timer — shared across autocmds
local refresh_timer = nil

local function debounced_refresh()
  if not state.is_active() then return end
  if refresh_timer then
    refresh_timer:stop()
  end
  refresh_timer = vim.defer_fn(function()
    refresh_timer = nil
    if state.is_active() then
      M.load_and_render()
    end
  end, 200)
end

-- Register all plugin autocmds under the "GitDiffViewer" augroup.
-- Called once during open(), after tab/panel are created.
local function setup_autocmds()
  -- Clean up state when the viewer tab is closed externally.
  -- TabClosed fires for ANY tab, so we check whether ours still exists.
  vim.api.nvim_create_autocmd("TabClosed", {
    group = augroup,
    callback = function()
      if not state.tab then return end
      if not state.is_active() then
        -- Our tab was the one closed
        teardown_autocmds()
        teardown_watchers()
        state.reset()
      end
    end,
  })

  -- Auto-refresh when files are saved
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = augroup,
    callback = function(ev)
      if not state.is_active() then return end
      -- Only refresh for files within the git root
      local file = ev.file or ""
      if file ~= "" and state.git_root and vim.startswith(file, state.git_root) then
        debounced_refresh()
      end
    end,
  })

  -- Auto-refresh when Neovim regains focus
  vim.api.nvim_create_autocmd("FocusGained", {
    group = augroup,
    callback = function()
      if not state.is_active() then return end
      debounced_refresh()
    end,
  })
end

-- Remove all plugin autocmds. Called on close() and when tab is closed externally.
teardown_autocmds = function()
  vim.api.nvim_clear_autocmds({ group = augroup })
  if refresh_timer then
    refresh_timer:stop()
    refresh_timer = nil
  end
end

-- ─── File watching ────────────────────────────────────────────────────────

-- Schedule a debounced refresh from a file watcher callback.
-- Uses vim.schedule since watcher callbacks fire on the libuv thread.
local function watcher_refresh()
  vim.schedule(function()
    if state.is_active() then
      debounced_refresh()
    end
  end)
end

-- Start file watchers for .git/index and .git/HEAD.
-- These detect external changes (staging from CLI, other tools, etc.)
local function setup_watchers()
  teardown_watchers()
  local root = state.git_root
  if not root then return end

  local git_dir = root .. "/.git"

  -- Watch .git/index — changes when files are staged/unstaged externally
  local index_watcher = vim.uv.new_fs_event()
  if index_watcher then
    local ok = pcall(function()
      index_watcher:start(git_dir .. "/index", {}, function(err)
        if not err then watcher_refresh() end
      end)
    end)
    if ok then
      table.insert(state.watchers, index_watcher)
    else
      index_watcher:close()
    end
  end

  -- Watch .git/HEAD — changes on branch switch, commit, etc.
  local head_watcher = vim.uv.new_fs_event()
  if head_watcher then
    local ok = pcall(function()
      head_watcher:start(git_dir .. "/HEAD", {}, function(err)
        if not err then watcher_refresh() end
      end)
    end)
    if ok then
      table.insert(state.watchers, head_watcher)
    else
      head_watcher:close()
    end
  end
end

-- Stop and clean up all file watchers.
local function teardown_watchers()
  for _, w in ipairs(state.watchers) do
    if not w:is_closing() then
      w:stop()
      w:close()
    end
  end
  state.watchers = {}
end

-- ─── Open ─────────────────────────────────────────────────────────────────────

function M.open()
  -- Single-instance: focus existing tab if it is still open
  if layout.focus() then return end

  local cwd = vim.fn.getcwd()
  -- Bug #12: remember which tab we came from for gf navigation
  local origin_tab = vim.api.nvim_get_current_tabpage()

  -- get_root fails for non-git dirs, so no separate is_git_repo check needed
  git.get_root(cwd, function(ok, root)
    vim.schedule(function()
      if not ok then
        utils.error("Not inside a git repository")
        return
      end

      state.reset()
      state.git_root = root
      state.origin_tab = origin_tab

      git.has_commits(root, function(has)
        vim.schedule(function()
          state.has_commits = has

          -- Build UI
          layout.create_tab()
          local buf = panel.create_buf()
          layout.set_panel_buf(buf)

          -- Focus the panel
          if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
            vim.api.nvim_set_current_win(state.panel_win)
          end

          -- Register autocmds and file watchers
          setup_autocmds()
          setup_watchers()

          -- Load git data and render panel
          M.load_and_render()
        end)
      end)
    end)
  end)
end

-- ─── Close ────────────────────────────────────────────────────────────────────

function M.close()
  teardown_autocmds()
  teardown_watchers()
  diff.cleanup_all_keymaps()
  layout.close()
  state.reset()
end

-- ─── Refresh ──────────────────────────────────────────────────────────────────

function M.refresh()
  if not state.is_active() then return end
  -- Bug #18: Preserve cache entries for currently displayed buffers,
  -- clear the rest so git show content is re-fetched on next diff open.
  local preserved = {}
  for key, buf in pairs(state.buf_cache) do
    for _, db in ipairs(state.diff_bufs) do
      if buf == db then
        preserved[key] = buf
        break
      end
    end
  end
  state.buf_cache = preserved
  M.load_and_render()
end

-- ─── Tab/S-Tab file cycling ───────────────────────────────────────────────────

-- Collect all file items across all sections in display order.
local function all_file_items()
  local items = {}
  for _, line in ipairs(state.panel_lines) do
    if line.type == "file" then
      table.insert(items, { item = line.item })
    end
  end
  return items
end

function M.next_file()
  local items = all_file_items()
  if #items == 0 then return end

  local current = state.current_diff
  if not current then
    diff.open(items[1].item)
    return
  end

  for i, entry in ipairs(items) do
    if entry.item.path == current.item.path and entry.item.section == current.item.section then
      local next_entry = items[i + 1] or items[1]
      diff.open(next_entry.item)
      return
    end
  end
end

function M.prev_file()
  local items = all_file_items()
  if #items == 0 then return end

  local current = state.current_diff
  if not current then
    diff.open(items[#items].item)
    return
  end

  for i, entry in ipairs(items) do
    if entry.item.path == current.item.path and entry.item.section == current.item.section then
      local prev_entry = items[i - 1] or items[#items]
      diff.open(prev_entry.item)
      return
    end
  end
end

-- ─── Operations (delegated to operations.lua) ────────────────────────────────

function M.stage_item(line) operations.stage_item(line) end
function M.unstage_item(line) operations.unstage_item(line) end
function M.discard_item(line) operations.discard_item(line) end
function M.stage_all() operations.stage_all() end
function M.unstage_all() operations.unstage_all() end

-- ─── Commands ─────────────────────────────────────────────────────────────────

vim.api.nvim_create_user_command("GitDiffViewer", function()
  M.open()
end, { desc = "Open Git Diff Viewer" })

vim.api.nvim_create_user_command("GitDiffViewerClose", function()
  M.close()
end, { desc = "Close Git Diff Viewer" })

return M
