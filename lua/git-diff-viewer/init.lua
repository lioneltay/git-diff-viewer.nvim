-- init.lua — Entry point: setup(), open(), close(), refresh(), git operations
--
-- Single-instance: only one viewer tab open at a time.
-- All git work is async (vim.system → on_exit → vim.schedule).

local M = {}

local config = require("git-diff-viewer.config")
local state = require("git-diff-viewer.state")
local git = require("git-diff-viewer.git")
local parse = require("git-diff-viewer.parse")
local utils = require("git-diff-viewer.utils")
local layout = require("git-diff-viewer.ui.layout")
local panel = require("git-diff-viewer.ui.panel")
local diff = require("git-diff-viewer.ui.diff")

-- Augroup for all plugin autocmds — ensures clean teardown on close/reopen
local augroup = vim.api.nvim_create_augroup("GitDiffViewer", { clear = true })

-- ─── Setup ────────────────────────────────────────────────────────────────────

function M.setup(opts)
  config.setup(opts)
  utils.setup_highlights()
end

-- ─── Internal: load git data and render ───────────────────────────────────────

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

    state.files = parse.build_file_list(entries, unstaged_numstat, staged_numstat)
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

-- ─── Open ─────────────────────────────────────────────────────────────────────

function M.open()
  -- Single-instance: focus existing tab if it is still open
  if layout.focus() then return end

  -- Detect git repo from the current working directory
  local cwd = vim.fn.getcwd()

  git.is_git_repo(cwd, function(is_repo)
    vim.schedule(function()
      if not is_repo then
        utils.error("Not inside a git repository")
        return
      end

      git.get_root(cwd, function(ok, root)
        vim.schedule(function()
          if not ok then
            utils.error("Could not determine git root")
            return
          end

          state.reset()
          state.git_root = root

          -- Check whether the repo has any commits
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

              -- Register autocmds (augroup ensures old ones are cleared first)
              setup_autocmds()

              -- Load git data and render panel
              M.load_and_render()
            end)
          end)
        end)
      end)
    end)
  end)
end

-- ─── Close ────────────────────────────────────────────────────────────────────

function M.close()
  teardown_autocmds()
  layout.close()
  state.reset()
end

-- ─── Refresh ──────────────────────────────────────────────────────────────────

function M.refresh()
  if not state.is_active() then return end
  -- Clear buf cache so git show buffers are re-fetched
  state.buf_cache = {}
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

-- ─── Git operations with optimistic UI ───────────────────────────────────────

-- Optimistic UI helper: immediately re-render, then run git command.
-- On failure: show error and re-render from fresh git data.
local function optimistic(action_fn, git_fn)
  -- Capture pre-action state for rollback
  local old_files = vim.deepcopy(state.files)

  -- Apply optimistic change to state
  action_fn()
  panel.render()

  -- Run the actual git command
  git_fn(function(ok, stderr)
    vim.schedule(function()
      if not ok then
        -- Roll back
        state.files = old_files
        panel.render()
        utils.error("Git operation failed: " .. (stderr or ""))
      else
        -- Refresh from git to ensure UI matches reality
        M.load_and_render()
      end
    end)
  end)
end

-- Remove an item from all sections of state.files in place.
local function remove_item(path, section)
  for _, sec in pairs(state.files) do
    for i = #sec, 1, -1 do
      if sec[i].path == path and (section == nil or sec[i].section == section) then
        table.remove(sec, i)
      end
    end
  end
end

-- Move an item from one section to another in state.files.
local function move_item(path, from_section, to_section)
  local item = nil
  local from_list = state.files[from_section]
  for i = #from_list, 1, -1 do
    if from_list[i].path == path then
      item = table.remove(from_list, i)
      break
    end
  end
  if item then
    item.section = to_section
    table.insert(state.files[to_section], item)
  end
end

-- stage_item: called with the panel_line under the cursor
function M.stage_item(line)
  if line.type == "file" then
    local item = line.item

    -- Determine paths to stage
    local paths = { item.path }

    if item.section == "changes" or item.status == "untracked" then
      -- Stage the file (moves from Changes to Staged; untracked → staged new).
      -- After git add, all changes become staged (no more unstaged changes), so
      -- status becomes "staged" regardless of whether it was "unstaged" or "both".
      optimistic(function()
        remove_item(item.path, "changes")
        local new_item = vim.tbl_extend("force", item, { section = "staged", status = "staged" })
        table.insert(state.files.staged, new_item)
      end, function(cb)
        git.stage(state.git_root, paths, function(ok, stderr) cb(ok, stderr) end)
      end)

    elseif item.section == "conflicts" then
      -- Stage conflict (marks as resolved)
      optimistic(function()
        remove_item(item.path, "conflicts")
        local new_item = vim.tbl_extend("force", item, { section = "staged", status = "staged" })
        table.insert(state.files.staged, new_item)
      end, function(cb)
        git.stage(state.git_root, paths, function(ok, stderr) cb(ok, stderr) end)
      end)

    else
      -- No-op for items already staged or in staged section
    end

  elseif line.type == "folder" then
    -- Collect all files in this folder that are stageable
    local paths = {}
    for _, item in ipairs(state.files.changes) do
      if vim.startswith(item.path, line.path .. "/") or item.path == line.path then
        table.insert(paths, item.path)
      end
    end
    for _, item in ipairs(state.files.conflicts) do
      if vim.startswith(item.path, line.path .. "/") or item.path == line.path then
        table.insert(paths, item.path)
      end
    end
    if #paths == 0 then return end

    optimistic(function()
      for _, p in ipairs(paths) do
        remove_item(p, nil)
      end
    end, function(cb)
      git.stage(state.git_root, paths, function(ok, stderr) cb(ok, stderr) end)
    end)

  elseif line.type == "section_header" then
    -- Stage entire section
    if line.section == "changes" or line.section == "conflicts" then
      local paths = {}
      for _, item in ipairs(state.files[line.section]) do
        table.insert(paths, item.path)
      end
      if #paths == 0 then return end

      optimistic(function()
        local new_staged = {}
        for _, item in ipairs(state.files[line.section]) do
          table.insert(new_staged, vim.tbl_extend("force", item, { section = "staged", status = "staged" }))
        end
        for _, item in ipairs(state.files.staged) do
          table.insert(new_staged, item)
        end
        state.files[line.section] = {}
        state.files.staged = new_staged
      end, function(cb)
        git.stage(state.git_root, paths, function(ok, stderr) cb(ok, stderr) end)
      end)
    end
  end
end

function M.unstage_item(line)
  if line.type == "file" then
    local item = line.item
    if item.section ~= "staged" then return end

    local paths = { item.path }

    optimistic(function()
      remove_item(item.path, "staged")
      -- After git restore --staged, the staged changes are removed.
      -- If the file was "both" (MM), it still has unstaged changes → status stays "both".
      -- If it was "staged" only (M_), it now has only unstaged changes → status = "unstaged".
      local new_status = item.status == "both" and "both" or "unstaged"
      local new_item = vim.tbl_extend("force", item, { section = "changes", status = new_status })
      table.insert(state.files.changes, new_item)
    end, function(cb)
      git.unstage(state.git_root, paths, function(ok, stderr) cb(ok, stderr) end)
    end)

  elseif line.type == "folder" then
    local paths = {}
    for _, item in ipairs(state.files.staged) do
      if vim.startswith(item.path, line.path .. "/") or item.path == line.path then
        table.insert(paths, item.path)
      end
    end
    if #paths == 0 then return end

    optimistic(function()
      for _, p in ipairs(paths) do
        remove_item(p, "staged")
      end
    end, function(cb)
      git.unstage(state.git_root, paths, function(ok, stderr) cb(ok, stderr) end)
    end)

  elseif line.type == "section_header" then
    -- Unstage entire section
    if line.section == "staged" then
      local paths = {}
      for _, item in ipairs(state.files.staged) do
        table.insert(paths, item.path)
      end
      if #paths == 0 then return end

      optimistic(function()
        for _, item in ipairs(state.files.staged) do
          local new_status = item.status == "both" and "both" or "unstaged"
          table.insert(state.files.changes, vim.tbl_extend("force", item, { section = "changes", status = new_status }))
        end
        state.files.staged = {}
      end, function(cb)
        git.unstage(state.git_root, paths, function(ok, stderr) cb(ok, stderr) end)
      end)
    end
  end
end

function M.discard_item(line)
  if line.type == "file" then
    local item = line.item
    local xy = item.xy

    if xy == "??" then
      -- Untracked: delete from disk with confirmation
      vim.ui.select({ "Yes", "No" }, {
        prompt = "Delete untracked file '" .. item.path .. "'?",
      }, function(choice)
        if choice ~= "Yes" then return end
        optimistic(function()
          remove_item(item.path, "changes")
        end, function(cb)
          local ok = os.remove(state.git_root .. "/" .. item.path)
          cb(ok ~= nil, ok == nil and "Failed to delete file" or nil)
        end)
      end)
      return
    end

    if item.section == "staged" then
      -- Staged modified: unstage then restore working tree
      local paths = { item.path }
      optimistic(function()
        remove_item(item.path, "staged")
      end, function(cb)
        git.unstage(state.git_root, paths, function(ok, stderr)
          if not ok then cb(ok, stderr); return end
          git.discard(state.git_root, paths, function(ok2, stderr2)
            cb(ok2, stderr2)
          end)
        end)
      end)
      return
    end

    -- Unstaged: restore working tree
    if item.section == "changes" then
      local paths = { item.path }
      optimistic(function()
        remove_item(item.path, "changes")
      end, function(cb)
        git.discard(state.git_root, paths, function(ok, stderr) cb(ok, stderr) end)
      end)
    end

  elseif line.type == "folder" then
    local paths = {}
    for _, item in ipairs(state.files.changes) do
      if vim.startswith(item.path, line.path .. "/") or item.path == line.path then
        if item.xy ~= "??" then -- skip untracked (can't batch-delete)
          table.insert(paths, item.path)
        end
      end
    end
    if #paths == 0 then return end

    optimistic(function()
      for _, p in ipairs(paths) do
        remove_item(p, "changes")
      end
    end, function(cb)
      git.discard(state.git_root, paths, function(ok, stderr) cb(ok, stderr) end)
    end)
  end
end

function M.stage_all()
  optimistic(function()
    -- git add -A stages everything: changes, untracked, AND conflicts (marks resolved).
    local new_staged = {}
    for _, item in ipairs(state.files.changes) do
      table.insert(new_staged, vim.tbl_extend("force", item, { section = "staged", status = "staged" }))
    end
    for _, item in ipairs(state.files.conflicts) do
      table.insert(new_staged, vim.tbl_extend("force", item, { section = "staged", status = "staged" }))
    end
    for _, item in ipairs(state.files.staged) do
      table.insert(new_staged, item)
    end
    state.files.changes = {}
    state.files.conflicts = {}
    state.files.staged = new_staged
  end, function(cb)
    git.stage_all(state.git_root, function(ok, stderr) cb(ok, stderr) end)
  end)
end

function M.unstage_all()
  optimistic(function()
    -- Move all staged items back to changes.
    -- After git restore --staged ., all staged changes are removed (status = "unstaged").
    -- "both" items that were in staged are now "both" still but live in changes section.
    local new_changes = {}
    for _, item in ipairs(state.files.staged) do
      local new_status = item.status == "both" and "both" or "unstaged"
      table.insert(new_changes, vim.tbl_extend("force", item, { section = "changes", status = new_status }))
    end
    for _, item in ipairs(state.files.changes) do
      table.insert(new_changes, item)
    end
    state.files.staged = {}
    state.files.changes = new_changes
  end, function(cb)
    git.unstage_all(state.git_root, function(ok, stderr) cb(ok, stderr) end)
  end)
end

-- ─── Commands ─────────────────────────────────────────────────────────────────

vim.api.nvim_create_user_command("GitDiffViewer", function()
  M.open()
end, { desc = "Open Git Diff Viewer" })

vim.api.nvim_create_user_command("GitDiffViewerClose", function()
  M.close()
end, { desc = "Close Git Diff Viewer" })

return M
