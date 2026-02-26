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

-- Guard: prevent watcher → load_and_render → watcher infinite loop.
-- Watcher events during a refresh are dropped (not queued) to break the
-- feedback cycle where git commands read .git/index and re-trigger the watcher.
local refresh_in_flight = false

-- Forward declaration (assigned later, used in try_render)
local debounced_refresh

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
  -- Item no longer exists — clear diff state but leave panes as-is.
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
  refresh_in_flight = true
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

    refresh_in_flight = false

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
    if not state.current_diff and #(state.diff_bufs or {}) > 0 then
      diff.show_empty()
    else
      diff.refresh_diff_bufs()
    end
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
  if state.mode == "branch" then
    M.load_and_render_branch()
  else
    M.load_and_render()
  end
end

-- ─── Autocmd lifecycle ──────────────────────────────────────────────────────

-- Forward declarations
local teardown_autocmds
local teardown_watchers

-- Debounced refresh timer — shared across autocmds
local refresh_timer = nil

debounced_refresh = function()
  if not state.is_active() then return end
  if refresh_timer then
    refresh_timer:stop()
  end
  refresh_timer = vim.defer_fn(function()
    refresh_timer = nil
    if state.is_active() then
      if state.mode == "branch" then
        M.load_and_render_branch()
      else
        M.load_and_render()
      end
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
        teardown_autocmds()
        teardown_watchers()
        diff.restore_bufhidden()
        state.reset()
      end
    end,
  })

  -- Protect diff and panel windows from external closure (e.g., claudecode.nvim's
  -- closeAllDiffTabs tool closes all windows with diff=true globally).
  -- Our own code uses state._orig_win_close to bypass this when needed.
  local orig_win_close = vim.api.nvim_win_close
  state._orig_win_close = orig_win_close
  vim.api.nvim_win_close = function(win, force)
    if state.is_active() then
      if win == state.panel_win then return end
      for _, w in ipairs(state.diff_wins) do
        if w == win then return end
      end
    end
    return orig_win_close(win, force)
  end

  -- Fix: floating windows (noice.nvim cmdline, which-key popup, snacks
  -- backdrop) inherit diff=true from the diff window that had focus when
  -- they open. This causes Neovim's diff engine to include the floating
  -- window as a participant, corrupting filler lines and highlights.
  -- See: https://github.com/folke/noice.nvim/issues/1169
  --
  -- Strategy: intercept nvim_open_win to strip diff from new floating
  -- windows immediately at creation time — before the diff engine
  -- recalculates. This catches all plugins regardless of whether they
  -- suppress autocmds. CmdlineLeave and WinEnter act as safety fallbacks.
  --
  -- Previous approach also disabled diff in CmdlineEnter as a backup,
  -- but that caused the diff to visibly vanish when pressing `:`. Since
  -- the nvim_open_win hook reliably prevents floating windows from
  -- inheriting diff, the proactive disable is no longer needed.

  local function restore_diff_wins()
    local dw = state.diff_wins or {}
    if #dw < 2 then return end
    for _, w in ipairs(dw) do
      if vim.api.nvim_win_is_valid(w) then
        vim.api.nvim_set_option_value("diff", true, { win = w })
        vim.api.nvim_set_option_value("scrollbind", true, { win = w })
        vim.api.nvim_set_option_value("cursorbind", true, { win = w })
        vim.api.nvim_set_option_value("foldmethod", "diff", { win = w })
        vim.api.nvim_set_option_value("foldlevel", 999, { win = w })
      end
    end
    vim.cmd("diffupdate")
  end

  -- Intercept nvim_open_win: strip diff from any floating window that
  -- inherits it from our diff panes. This runs at window creation time,
  -- before the diff engine sees the new participant.
  local orig_open_win = vim.api.nvim_open_win
  vim.api.nvim_open_win = function(buf, enter, config, ...)
    local win = orig_open_win(buf, enter, config, ...)
    if state.is_active() and config and config.relative and config.relative ~= "" then
      if vim.api.nvim_win_is_valid(win) and vim.wo[win].diff then
        vim.wo[win].diff = false
        -- Deferred restore: ensure diff windows weren't disrupted by the
        -- diff engine momentarily seeing a third participant.
        vim.schedule(restore_diff_wins)
      end
    end
    return win
  end

  -- Restore the original nvim_open_win on teardown
  state._orig_open_win = orig_open_win

  -- Safety net: restore diff after cmdline closes, in case any plugin
  -- managed to disrupt diff mode during cmdline interaction.
  vim.api.nvim_create_autocmd("CmdlineLeave", {
    group = augroup,
    callback = function()
      if not state.is_active() then return end
      vim.schedule(restore_diff_wins)
    end,
  })

  -- WinEnter fallback: (1) strip diff from floating windows that bypassed
  -- the nvim_open_win hook, and (2) restore diff if any diff window lost it.
  vim.api.nvim_create_autocmd("WinEnter", {
    group = augroup,
    callback = function()
      if not state.is_active() then return end
      if vim.api.nvim_get_current_tabpage() ~= state.tab then return end

      -- Strip diff from floating windows (catches hook bypasses, e.g.
      -- plugins that cached nvim_open_win before our intercept was installed)
      local win = vim.api.nvim_get_current_win()
      local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
      if ok and cfg.relative and cfg.relative ~= "" and vim.wo[win].diff then
        vim.wo[win].diff = false
        vim.schedule(restore_diff_wins)
        return
      end

      -- Restore diff on diff windows if any lost it
      local dw = state.diff_wins or {}
      if #dw < 2 then return end
      for _, w in ipairs(dw) do
        if vim.api.nvim_win_is_valid(w) and not vim.wo[w].diff then
          restore_diff_wins()
          return
        end
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
  -- Restore original nvim_open_win / nvim_win_close if we intercepted them
  if state._orig_open_win then
    vim.api.nvim_open_win = state._orig_open_win
    state._orig_open_win = nil
  end
  if state._orig_win_close then
    vim.api.nvim_win_close = state._orig_win_close
    state._orig_win_close = nil
  end
end

-- ─── File watching ────────────────────────────────────────────────────────

-- Stop and clean up all file watchers.
teardown_watchers = function()
  for _, w in ipairs(state.watchers) do
    if not w:is_closing() then
      w:stop()
      w:close()
    end
  end
  state.watchers = {}
end

-- Schedule a debounced refresh from a file watcher callback.
-- Uses vim.schedule since watcher callbacks fire on the libuv thread.
-- Events during an in-flight refresh are dropped to break the feedback
-- loop (git commands reading .git/index re-trigger the watcher on macOS).
local function watcher_refresh()
  vim.schedule(function()
    if not state.is_active() then return end
    if refresh_in_flight then return end
    debounced_refresh()
  end)
end

-- Start directory watchers for git state changes.
-- Watches directories (not individual files) because git replaces files
-- via rename (.git/index.lock → .git/index), which changes the inode.
-- On macOS, kqueue watches by inode, so file-level watchers die after
-- the first git operation. Directory watchers survive file replacements.
local function setup_watchers()
  teardown_watchers()
  local root = state.git_root
  if not root then return end

  local git_dir = root .. "/.git"

  -- Helper: start a directory watcher with an optional filename filter.
  local function watch_dir(dir, filter_fn)
    local watcher = vim.uv.new_fs_event()
    if not watcher then return end
    local ok = pcall(function()
      watcher:start(dir, {}, function(err, filename)
        if err then return end
        if filter_fn and not filter_fn(filename) then return end
        watcher_refresh()
      end)
    end)
    if ok then
      table.insert(state.watchers, watcher)
    else
      watcher:close()
    end
  end

  -- Watch .git/ directory for index and HEAD changes (staging, branch switch)
  watch_dir(git_dir, function(filename)
    return filename == "index" or filename == "HEAD"
  end)

  -- Watch .git/refs/heads/ for branch ref changes (commits, rebase, etc.)
  local refs_dir = git_dir .. "/refs/heads"
  if vim.fn.isdirectory(refs_dir) == 1 then
    watch_dir(refs_dir)
  end
end

-- ─── Open ─────────────────────────────────────────────────────────────────────

function M.open()
  -- Mutual exclusion: close branch mode if active
  if state.is_active() and state.mode == "branch" then
    M.close()
  end

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
      state.mode = "status"

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

-- ─── Branch diff mode ──────────────────────────────────────────────────────

-- Fetch branch diff data and render panel (branch mode equivalent of load_and_render).
function M.load_and_render_branch()
  refresh_in_flight = true
  local cwd = state.git_root
  local target = state.target_branch
  local gen = state.next_generation()

  local name_status_raw = nil
  local numstat_raw = nil
  local errors = {}
  local pending = 2

  local function try_render()
    pending = pending - 1
    if pending > 0 then return end

    refresh_in_flight = false

    if state.generation ~= gen then return end

    if #errors > 0 then
      utils.error("Git error: " .. table.concat(errors, "; "))
      return
    end

    if not state.is_active() then return end

    local name_status_entries = parse.parse_name_status(name_status_raw or "")
    local numstat = parse.parse_numstat(numstat_raw or "")

    local files = parse.build_branch_file_list(name_status_entries, numstat)
    state.sections = {
      { key = "changes", label = "Changes", items = files.changes },
    }
    reconcile_current_diff()
    reconcile_viewed_diffs()
    panel.render()
    if not state.current_diff and #(state.diff_bufs or {}) > 0 then
      diff.show_empty()
    else
      diff.refresh_diff_bufs()
    end
  end

  git.diff_branch_name_status(cwd, target, function(ok, raw)
    vim.schedule(function()
      if not ok then
        table.insert(errors, "branch name-status: " .. (raw or "unknown"))
      else
        name_status_raw = raw
      end
      try_render()
    end)
  end)

  git.diff_branch_numstat(cwd, target, function(ok, raw)
    vim.schedule(function()
      if not ok then
        table.insert(errors, "branch numstat: " .. (raw or "unknown"))
      else
        numstat_raw = raw
      end
      try_render()
    end)
  end)
end

-- Open branch diff viewer.
-- target_arg: optional branch name (e.g. "main"). If nil, auto-detects default branch.
function M.open_branch(target_arg)
  -- Mutual exclusion: close status mode if active
  if state.is_active() and state.mode == "status" then
    M.close()
  end

  -- Already in branch mode with same target — just focus
  if state.is_active() and state.mode == "branch" then
    if target_arg and target_arg ~= state.target_branch then
      -- Different target: update and refresh
      state.target_branch = target_arg
      state.buf_cache = {}
      M.load_and_render_branch()
      return
    end
    layout.focus()
    return
  end

  local cwd = vim.fn.getcwd()
  local origin_tab = vim.api.nvim_get_current_tabpage()

  git.get_root(cwd, function(ok, root)
    vim.schedule(function()
      if not ok then
        utils.error("Not inside a git repository")
        return
      end

      local function start_branch_viewer(target)
        -- Validate the target ref exists
        vim.system({ "git", "rev-parse", "--verify", target }, {
          cwd = root,
          text = true,
        }, function(result)
          vim.schedule(function()
            if result.code ~= 0 then
              utils.error("Branch not found: " .. target)
              return
            end

            state.reset()
            state.git_root = root
            state.origin_tab = origin_tab
            state.mode = "branch"
            state.target_branch = target
            state.has_commits = true -- branch diff implies commits exist

            -- Build UI
            layout.create_tab()
            local buf = panel.create_buf()
            layout.set_panel_buf(buf)

            if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
              vim.api.nvim_set_current_win(state.panel_win)
            end

            setup_autocmds()
            setup_watchers()
            M.load_and_render_branch()
          end)
        end)
      end

      if target_arg then
        start_branch_viewer(target_arg)
      else
        -- Auto-detect default branch
        git.detect_default_branch(root, function(det_ok, branch)
          vim.schedule(function()
            start_branch_viewer(det_ok and branch or "main")
          end)
        end)
      end
    end)
  end)
end

-- ─── Close ────────────────────────────────────────────────────────────────────

function M.close()
  teardown_autocmds()
  teardown_watchers()
  diff.cleanup_all_keymaps()
  -- Close the tab FIRST while buffers are still pinned (bufhidden="hide").
  -- This prevents auto-reload.nvim's debounced checktime from hitting E94
  -- on buffers that were unloaded during tab close.
  layout.close()
  -- Now restore original bufhidden. Buffers are already hidden, so the
  -- restored value only takes effect next time they leave a window.
  diff.restore_bufhidden()
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
  if state.mode == "branch" then
    M.load_and_render_branch()
  else
    M.load_and_render()
  end
end

-- ─── Tab/S-Tab file cycling ───────────────────────────────────────────────────

-- Collect all file items across all sections in display order.
local function all_file_items()
  local items = {}
  for _, line in ipairs(state.panel_lines) do
    if line.type == "file" then
      table.insert(items, line.item)
    end
  end
  return items
end

local function cycle_file(direction)
  local items = all_file_items()
  if #items == 0 then return end
  local current = state.current_diff
  if not current then
    diff.open(items[direction == 1 and 1 or #items])
    return
  end
  for i, item in ipairs(items) do
    if item.path == current.item.path and item.section == current.item.section then
      local target = items[i + direction] or items[direction == 1 and 1 or #items]
      diff.open(target)
      return
    end
  end
end

function M.next_file() cycle_file(1) end
function M.prev_file() cycle_file(-1) end

-- ─── Commands ─────────────────────────────────────────────────────────────────

vim.api.nvim_create_user_command("GitDiffViewer", function()
  M.open()
end, { desc = "Open Git Diff Viewer" })

vim.api.nvim_create_user_command("GitDiffViewerClose", function()
  M.close()
end, { desc = "Close Git Diff Viewer" })

vim.api.nvim_create_user_command("GitDiffViewerBranch", function(opts)
  M.open_branch(opts.args ~= "" and opts.args or nil)
end, { nargs = "?", desc = "Open Git Diff Viewer (branch mode)" })

return M
