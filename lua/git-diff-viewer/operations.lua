-- operations.lua — Git staging operations with fire-and-forget optimistic UI
--
-- Each operation:
-- 1. Mutates state.sections immediately (optimistic update)
-- 2. Calls panel.render() for instant feedback
-- 3. Fires the git command asynchronously
-- 4. On completion: a debounced refresh syncs state with reality

local M = {}

local state = require("git-diff-viewer.state")
local git = require("git-diff-viewer.git")
local utils = require("git-diff-viewer.utils")
local panel = require("git-diff-viewer.ui.panel")
local diff = require("git-diff-viewer.ui.diff")

-- Set by init.lua after load_and_render is defined
M.refresh = nil

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function get_section(key)
  for _, s in ipairs(state.sections) do
    if s.key == key then return s end
  end
end

-- Check if the currently viewed diff item still exists in any section.
local function current_diff_still_exists()
  if not state.current_diff or not state.current_diff.item then return true end
  local path = state.current_diff.item.path
  for _, sec in ipairs(state.sections) do
    for _, item in ipairs(sec.items) do
      if item.path == path then return true end
    end
  end
  return false
end

-- Fire-and-forget: apply optimistic change, run git, then refresh on completion.
local function fire_git(action_fn, git_fn)
  action_fn()
  panel.render()

  -- Clear stale diff panes if the viewed file was removed by this operation
  if not current_diff_still_exists() then
    state.current_diff = nil
    diff.show_empty()
  end

  git_fn(function(ok, stderr)
    vim.schedule(function()
      if not ok then
        utils.error("Git operation failed: " .. (stderr or ""))
      end
      if state.is_active() and M.refresh then
        M.refresh()
      end
    end)
  end)
end

-- Remove item(s) from section(s) by path.
local function remove_from_section(path, section_key)
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

-- Add an item to a section's items list.
local function add_to_section(section_key, item)
  local sec = get_section(section_key)
  if sec then table.insert(sec.items, item) end
end

-- Collect items matching a folder path from a section.
local function collect_folder_items(section_key, folder_path)
  local sec = get_section(section_key)
  if not sec then return {} end
  local items = {}
  for _, item in ipairs(sec.items) do
    if vim.startswith(item.path, folder_path .. "/") or item.path == folder_path then
      table.insert(items, item)
    end
  end
  return items
end

-- ─── Stage ────────────────────────────────────────────────────────────────────

function M.stage_item(line)
  if line.type == "file" then
    local item = line.item
    local paths = { item.path }

    if item.section == "changes" or item.section == "conflicts"
       or item.status == "untracked" then
      fire_git(function()
        remove_from_section(item.path, item.section)
        add_to_section("staged", vim.tbl_extend("force", item, { section = "staged", status = "staged" }))
      end, function(cb)
        git.stage(state.git_root, paths, cb)
      end)
    end

  elseif line.type == "folder" then
    -- Bug #7 fix: collect items BEFORE removing, then move them to staged
    local changes_items = collect_folder_items("changes", line.path)
    local conflicts_items = collect_folder_items("conflicts", line.path)
    local all_items = {}
    for _, item in ipairs(changes_items) do table.insert(all_items, item) end
    for _, item in ipairs(conflicts_items) do table.insert(all_items, item) end
    if #all_items == 0 then return end

    local paths = {}
    for _, item in ipairs(all_items) do
      table.insert(paths, item.path)
    end

    fire_git(function()
      for _, item in ipairs(all_items) do
        remove_from_section(item.path, nil)
        add_to_section("staged", vim.tbl_extend("force", item, { section = "staged", status = "staged" }))
      end
    end, function(cb)
      git.stage(state.git_root, paths, cb)
    end)

  elseif line.type == "section_header" then
    if line.section == "changes" or line.section == "conflicts" then
      local src_sec = get_section(line.section)
      local staged_sec = get_section("staged")
      if not src_sec or #src_sec.items == 0 then return end

      local paths = {}
      for _, item in ipairs(src_sec.items) do
        table.insert(paths, item.path)
      end

      fire_git(function()
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
        git.stage(state.git_root, paths, cb)
      end)
    end
  end
end

-- ─── Unstage ──────────────────────────────────────────────────────────────────

function M.unstage_item(line)
  if line.type == "file" then
    local item = line.item
    if item.section ~= "staged" then return end

    local paths = { item.path }

    -- Bug #16 fix: A_ files become untracked (??) when unstaged, not "unstaged"
    local new_status
    local new_xy
    if item.status == "both" then
      new_status = "both"
      new_xy = item.xy
    elseif item.xy and item.xy:sub(1, 1) == "A" then
      new_status = "untracked"
      new_xy = "??"
    else
      new_status = "unstaged"
      new_xy = item.xy
    end

    fire_git(function()
      remove_from_section(item.path, "staged")
      add_to_section("changes", vim.tbl_extend("force", item, {
        section = "changes",
        status = new_status,
        xy = new_xy or item.xy,
      }))
    end, function(cb)
      -- Bug #17 fix: empty repo can't use `git restore --staged`, use `git rm --cached`
      if not state.has_commits then
        git.rm_cached(state.git_root, paths, cb)
      else
        git.unstage(state.git_root, paths, cb)
      end
    end)

  elseif line.type == "folder" then
    -- Bug #6 fix: collect items BEFORE removing, then move them to changes
    local staged_items = collect_folder_items("staged", line.path)
    if #staged_items == 0 then return end

    local paths = {}
    for _, item in ipairs(staged_items) do
      table.insert(paths, item.path)
    end

    fire_git(function()
      for _, item in ipairs(staged_items) do
        remove_from_section(item.path, "staged")
        local new_status = item.status == "both" and "both" or "unstaged"
        add_to_section("changes", vim.tbl_extend("force", item, { section = "changes", status = new_status }))
      end
    end, function(cb)
      if not state.has_commits then
        git.rm_cached(state.git_root, paths, cb)
      else
        git.unstage(state.git_root, paths, cb)
      end
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

      fire_git(function()
        if changes_sec then
          for _, item in ipairs(staged_sec.items) do
            local new_status = item.status == "both" and "both" or "unstaged"
            table.insert(changes_sec.items, vim.tbl_extend("force", item, { section = "changes", status = new_status }))
          end
        end
        staged_sec.items = {}
      end, function(cb)
        if not state.has_commits then
          git.rm_cached(state.git_root, paths, cb)
        else
          git.unstage(state.git_root, paths, cb)
        end
      end)
    end
  end
end

-- ─── Discard ──────────────────────────────────────────────────────────────────

function M.discard_item(line)
  if line.type == "file" then
    local item = line.item
    local xy = item.xy

    if xy == "??" then
      vim.ui.select({ "Yes", "No" }, {
        prompt = "Delete untracked file '" .. item.path .. "'?",
      }, function(choice)
        if choice ~= "Yes" then return end
        fire_git(function()
          remove_from_section(item.path, "changes")
        end, function(cb)
          local ok = os.remove(state.git_root .. "/" .. item.path)
          cb(ok ~= nil, ok == nil and "Failed to delete file" or nil)
        end)
      end)
      return
    end

    -- Bug #4 fix: staged discard uses atomic `git checkout HEAD --` instead of
    -- two-step unstage + discard (which can leave inconsistent state if discard fails)
    if item.section == "staged" then
      local paths = { item.path }
      local x = (xy or ""):sub(1, 1)

      if x == "A" or not state.has_commits then
        -- Newly added file — doesn't exist in HEAD, so just unstage it
        fire_git(function()
          remove_from_section(item.path, "staged")
          add_to_section("changes", vim.tbl_extend("force", item, {
            section = "changes", status = "untracked", xy = "??",
          }))
        end, function(cb)
          git.rm_cached(state.git_root, paths, cb)
        end)
      else
        fire_git(function()
          remove_from_section(item.path, "staged")
        end, function(cb)
          git.checkout_head(state.git_root, paths, cb)
        end)
      end
      return
    end

    if item.section == "changes" then
      local paths = { item.path }
      fire_git(function()
        remove_from_section(item.path, "changes")
      end, function(cb)
        git.discard(state.git_root, paths, cb)
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

    -- Bug #27 fix: prompt for confirmation before folder-level discard
    vim.ui.select({ "Yes", "No" }, {
      prompt = "Discard changes in folder '" .. line.path .. "/' (" .. #paths .. " files)?",
    }, function(choice)
      if choice ~= "Yes" then return end
      fire_git(function()
        for _, p in ipairs(paths) do
          remove_from_section(p, "changes")
        end
      end, function(cb)
        git.discard(state.git_root, paths, cb)
      end)
    end)
  end
end

-- ─── Bulk operations ──────────────────────────────────────────────────────────

function M.stage_all()
  local changes_sec = get_section("changes")
  local conflicts_sec = get_section("conflicts")
  local staged_sec = get_section("staged")

  fire_git(function()
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
    git.stage_all(state.git_root, cb)
  end)
end

function M.unstage_all()
  local staged_sec = get_section("staged")
  local changes_sec = get_section("changes")

  fire_git(function()
    if staged_sec and changes_sec then
      for _, item in ipairs(staged_sec.items) do
        local new_status = item.status == "both" and "both" or "unstaged"
        table.insert(changes_sec.items, vim.tbl_extend("force", item, { section = "changes", status = new_status }))
      end
      staged_sec.items = {}
    end
  end, function(cb)
    if not state.has_commits then
      git.rm_cached(state.git_root, { "." }, cb)
    else
      git.unstage_all(state.git_root, cb)
    end
  end)
end

return M
