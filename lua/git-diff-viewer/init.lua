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

    local files = parse.build_file_list(entries, unstaged_numstat, staged_numstat)
    state.sections = {
      { key = "conflicts", label = "Merge Conflicts", items = files.conflicts },
      { key = "changes",   label = "Changes",         items = files.changes },
      { key = "staged",    label = "Staged Changes",  items = files.staged },
    }
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

  local cwd = vim.fn.getcwd()

  -- get_root fails for non-git dirs, so no separate is_git_repo check needed
  git.get_root(cwd, function(ok, root)
    vim.schedule(function()
      if not ok then
        utils.error("Not inside a git repository")
        return
      end

      state.reset()
      state.git_root = root

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

-- Find a section by key in state.sections.
local function get_section(key)
  for _, s in ipairs(state.sections) do
    if s.key == key then return s end
  end
end

-- Optimistic UI helper: immediately re-render, then run git command.
-- On failure: show error and re-render from fresh git data.
local function optimistic(action_fn, git_fn)
  -- Apply optimistic change to state
  action_fn()
  panel.render()

  -- Run the actual git command
  git_fn(function(ok, stderr)
    vim.schedule(function()
      if not ok then
        utils.error("Git operation failed: " .. (stderr or ""))
      end
      -- Refresh from git to ensure UI matches reality
      if state.is_active() then
        M.load_and_render()
      end
    end)
  end)
end

-- Remove an item from a section's items list by path.
-- If section_key is nil, removes from all sections.
local function remove_item(path, section_key)
  for _, sec in ipairs(state.sections) do
    if section_key == nil or sec.key == section_key then
      for i = #sec.items, 1, -1 do
        if sec.items[i].path == path then
          table.remove(sec.items, i)
        end
      end
    end
  end
end

-- stage_item: called with the panel_line under the cursor
function M.stage_item(line)
  if line.type == "file" then
    local item = line.item

    -- Determine paths to stage
    local paths = { item.path }

    if item.section == "changes" or item.status == "untracked" then
      local staged_sec = get_section("staged")
      optimistic(function()
        remove_item(item.path, "changes")
        local new_item = vim.tbl_extend("force", item, { section = "staged", status = "staged" })
        if staged_sec then table.insert(staged_sec.items, new_item) end
      end, function(cb)
        git.stage(state.git_root, paths, function(ok, stderr) cb(ok, stderr) end)
      end)

    elseif item.section == "conflicts" then
      local staged_sec = get_section("staged")
      optimistic(function()
        remove_item(item.path, "conflicts")
        local new_item = vim.tbl_extend("force", item, { section = "staged", status = "staged" })
        if staged_sec then table.insert(staged_sec.items, new_item) end
      end, function(cb)
        git.stage(state.git_root, paths, function(ok, stderr) cb(ok, stderr) end)
      end)
    end

  elseif line.type == "folder" then
    -- Collect all files in this folder that are stageable
    local paths = {}
    local changes_sec = get_section("changes")
    local conflicts_sec = get_section("conflicts")
    if changes_sec then
      for _, item in ipairs(changes_sec.items) do
        if vim.startswith(item.path, line.path .. "/") or item.path == line.path then
          table.insert(paths, item.path)
        end
      end
    end
    if conflicts_sec then
      for _, item in ipairs(conflicts_sec.items) do
        if vim.startswith(item.path, line.path .. "/") or item.path == line.path then
          table.insert(paths, item.path)
        end
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
      local src_sec = get_section(line.section)
      local staged_sec = get_section("staged")
      if not src_sec or #src_sec.items == 0 then return end

      local paths = {}
      for _, item in ipairs(src_sec.items) do
        table.insert(paths, item.path)
      end

      optimistic(function()
        local new_staged = {}
        for _, item in ipairs(src_sec.items) do
          table.insert(new_staged, vim.tbl_extend("force", item, { section = "staged", status = "staged" }))
        end
        if staged_sec then
          for _, item in ipairs(staged_sec.items) do
            table.insert(new_staged, item)
          end
          staged_sec.items = new_staged
        end
        src_sec.items = {}
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
    local changes_sec = get_section("changes")

    optimistic(function()
      remove_item(item.path, "staged")
      local new_status = item.status == "both" and "both" or "unstaged"
      local new_item = vim.tbl_extend("force", item, { section = "changes", status = new_status })
      if changes_sec then table.insert(changes_sec.items, new_item) end
    end, function(cb)
      git.unstage(state.git_root, paths, function(ok, stderr) cb(ok, stderr) end)
    end)

  elseif line.type == "folder" then
    local staged_sec = get_section("staged")
    if not staged_sec then return end
    local paths = {}
    for _, item in ipairs(staged_sec.items) do
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
    if line.section == "staged" then
      local staged_sec = get_section("staged")
      local changes_sec = get_section("changes")
      if not staged_sec or #staged_sec.items == 0 then return end

      local paths = {}
      for _, item in ipairs(staged_sec.items) do
        table.insert(paths, item.path)
      end

      optimistic(function()
        if changes_sec then
          for _, item in ipairs(staged_sec.items) do
            local new_status = item.status == "both" and "both" or "unstaged"
            table.insert(changes_sec.items, vim.tbl_extend("force", item, { section = "changes", status = new_status }))
          end
        end
        staged_sec.items = {}
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

    if item.section == "changes" then
      local paths = { item.path }
      optimistic(function()
        remove_item(item.path, "changes")
      end, function(cb)
        git.discard(state.git_root, paths, function(ok, stderr) cb(ok, stderr) end)
      end)
    end

  elseif line.type == "folder" then
    local changes_sec = get_section("changes")
    if not changes_sec then return end
    local paths = {}
    for _, item in ipairs(changes_sec.items) do
      if vim.startswith(item.path, line.path .. "/") or item.path == line.path then
        if item.xy ~= "??" then
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
  local changes_sec = get_section("changes")
  local conflicts_sec = get_section("conflicts")
  local staged_sec = get_section("staged")

  optimistic(function()
    local new_staged = {}
    if changes_sec then
      for _, item in ipairs(changes_sec.items) do
        table.insert(new_staged, vim.tbl_extend("force", item, { section = "staged", status = "staged" }))
      end
      changes_sec.items = {}
    end
    if conflicts_sec then
      for _, item in ipairs(conflicts_sec.items) do
        table.insert(new_staged, vim.tbl_extend("force", item, { section = "staged", status = "staged" }))
      end
      conflicts_sec.items = {}
    end
    if staged_sec then
      for _, item in ipairs(staged_sec.items) do
        table.insert(new_staged, item)
      end
      staged_sec.items = new_staged
    end
  end, function(cb)
    git.stage_all(state.git_root, function(ok, stderr) cb(ok, stderr) end)
  end)
end

function M.unstage_all()
  local staged_sec = get_section("staged")
  local changes_sec = get_section("changes")

  optimistic(function()
    if staged_sec and changes_sec then
      for _, item in ipairs(staged_sec.items) do
        local new_status = item.status == "both" and "both" or "unstaged"
        table.insert(changes_sec.items, vim.tbl_extend("force", item, { section = "changes", status = new_status }))
      end
      staged_sec.items = {}
    end
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
