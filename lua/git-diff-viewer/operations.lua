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

-- Set by init.lua after load_and_render is defined
M.refresh = nil

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function get_section(key)
  for _, s in ipairs(state.sections) do
    if s.key == key then return s end
  end
end

-- Fire-and-forget: apply optimistic change, run git, then refresh on completion.
local function fire_git(action_fn, git_fn)
  action_fn()
  panel.render()

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

-- ─── Stage ────────────────────────────────────────────────────────────────────

function M.stage_item(line)
  if line.type == "file" then
    local item = line.item
    local paths = { item.path }

    if item.section == "changes" or item.status == "untracked" then
      fire_git(function()
        remove_from_section(item.path, "changes")
        add_to_section("staged", vim.tbl_extend("force", item, { section = "staged", status = "staged" }))
      end, function(cb)
        git.stage(state.git_root, paths, function(ok, stderr) cb(ok, stderr) end)
      end)

    elseif item.section == "conflicts" then
      fire_git(function()
        remove_from_section(item.path, "conflicts")
        add_to_section("staged", vim.tbl_extend("force", item, { section = "staged", status = "staged" }))
      end, function(cb)
        git.stage(state.git_root, paths, function(ok, stderr) cb(ok, stderr) end)
      end)
    end

  elseif line.type == "folder" then
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

    fire_git(function()
      for _, p in ipairs(paths) do
        remove_from_section(p, nil)
      end
    end, function(cb)
      git.stage(state.git_root, paths, function(ok, stderr) cb(ok, stderr) end)
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
        git.stage(state.git_root, paths, function(ok, stderr) cb(ok, stderr) end)
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

    fire_git(function()
      remove_from_section(item.path, "staged")
      local new_status = item.status == "both" and "both" or "unstaged"
      add_to_section("changes", vim.tbl_extend("force", item, { section = "changes", status = new_status }))
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

    fire_git(function()
      for _, p in ipairs(paths) do
        remove_from_section(p, "staged")
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

      fire_git(function()
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

    if item.section == "staged" then
      local paths = { item.path }
      fire_git(function()
        remove_from_section(item.path, "staged")
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
      fire_git(function()
        remove_from_section(item.path, "changes")
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

    fire_git(function()
      for _, p in ipairs(paths) do
        remove_from_section(p, "changes")
      end
    end, function(cb)
      git.discard(state.git_root, paths, function(ok, stderr) cb(ok, stderr) end)
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
    git.stage_all(state.git_root, function(ok, stderr) cb(ok, stderr) end)
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
    git.unstage_all(state.git_root, function(ok, stderr) cb(ok, stderr) end)
  end)
end

return M
