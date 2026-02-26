-- git.lua — Async git command wrappers
--
-- All commands use vim.system() with on_exit callback.
-- IMPORTANT: on_exit fires on the libuv thread, not the Neovim main thread.
-- Always wrap Neovim API calls inside vim.schedule() in the callback.
--
-- GIT_OPTIONAL_LOCKS=0 reduces lock contention with gitsigns, lazygit, etc.

local M = {}

local GIT_ENV = { GIT_OPTIONAL_LOCKS = "0" }

-- Run a git command asynchronously.
-- opts: { cwd = string, stdin = string }
-- callback(ok, stdout, stderr) — called on libuv thread, use vim.schedule() inside
local function run(args, opts, callback)
  opts = opts or {}
  vim.system(args, {
    cwd = opts.cwd,
    env = GIT_ENV,
    stdin = opts.stdin,
    text = true,
  }, function(result)
    callback(result.code == 0, result.stdout or "", result.stderr or "")
  end)
end

-- Get the git root directory.
-- callback(ok: boolean, root: string)
function M.get_root(cwd, callback)
  run({ "git", "rev-parse", "--show-toplevel" }, { cwd = cwd }, function(ok, stdout)
    callback(ok, vim.trim(stdout))
  end)
end

-- Check whether the repo has any commits (HEAD exists).
-- callback(has_commits: boolean)
function M.has_commits(cwd, callback)
  run({ "git", "rev-parse", "HEAD" }, { cwd = cwd }, function(ok)
    callback(ok)
  end)
end

-- Get NUL-terminated porcelain v1 file status list.
-- callback(ok: boolean, raw: string)
function M.status(cwd, callback)
  run({ "git", "status", "--porcelain=v1", "-z", "-uall" }, { cwd = cwd }, function(ok, stdout)
    callback(ok, stdout)
  end)
end

-- Get numstat for unstaged changes (used for +/- counts and binary detection).
-- Binary files appear as "-\t-\t<path>" in the output.
-- callback(ok: boolean, raw: string)
function M.diff_numstat(cwd, callback)
  run({ "git", "diff", "--numstat", "-z" }, { cwd = cwd }, function(ok, stdout)
    callback(ok, stdout)
  end)
end

-- Get numstat for staged changes.
-- callback(ok: boolean, raw: string)
function M.diff_cached_numstat(cwd, callback)
  run({ "git", "diff", "--cached", "--numstat", "-z" }, { cwd = cwd }, function(ok, stdout)
    callback(ok, stdout)
  end)
end

-- Read the HEAD version of a file.
-- callback(ok: boolean, content: string)
function M.show_head(cwd, path, callback)
  run({ "git", "show", "HEAD:" .. path }, { cwd = cwd }, function(ok, stdout)
    callback(ok, stdout)
  end)
end

-- Read the staged (index) version of a file.
-- callback(ok: boolean, content: string)
function M.show_staged(cwd, path, callback)
  run({ "git", "show", ":0:" .. path }, { cwd = cwd }, function(ok, stdout)
    callback(ok, stdout)
  end)
end

-- Stage files.
-- paths: list of path strings
-- callback(ok: boolean, stderr: string)
function M.stage(cwd, paths, callback)
  local args = { "git", "add", "--" }
  for _, p in ipairs(paths) do
    table.insert(args, p)
  end
  run(args, { cwd = cwd }, function(ok, _, stderr)
    callback(ok, stderr)
  end)
end

-- Unstage files (remove from index, keep working tree).
-- callback(ok: boolean, stderr: string)
function M.unstage(cwd, paths, callback)
  local args = { "git", "restore", "--staged", "--" }
  for _, p in ipairs(paths) do
    table.insert(args, p)
  end
  run(args, { cwd = cwd }, function(ok, _, stderr)
    callback(ok, stderr)
  end)
end

-- Discard unstaged changes to tracked files (restore from index).
-- callback(ok: boolean, stderr: string)
function M.discard(cwd, paths, callback)
  local args = { "git", "restore", "--" }
  for _, p in ipairs(paths) do
    table.insert(args, p)
  end
  run(args, { cwd = cwd }, function(ok, _, stderr)
    callback(ok, stderr)
  end)
end

-- Atomically discard staged changes by restoring from HEAD.
-- `git checkout HEAD -- <paths>` unstages AND restores in one step.
-- callback(ok: boolean, stderr: string)
function M.checkout_head(cwd, paths, callback)
  local args = { "git", "checkout", "HEAD", "--" }
  for _, p in ipairs(paths) do
    table.insert(args, p)
  end
  run(args, { cwd = cwd }, function(ok, _, stderr)
    callback(ok, stderr)
  end)
end

-- Remove files from index only (for empty repos where git restore --staged fails).
-- `git rm --cached -- <paths>` removes from staging without touching working tree.
-- callback(ok: boolean, stderr: string)
function M.rm_cached(cwd, paths, callback)
  local args = { "git", "rm", "--cached", "--" }
  for _, p in ipairs(paths) do
    table.insert(args, p)
  end
  run(args, { cwd = cwd }, function(ok, _, stderr)
    callback(ok, stderr)
  end)
end

-- Stage all changes (equivalent to `git add -A`).
-- callback(ok: boolean, stderr: string)
function M.stage_all(cwd, callback)
  run({ "git", "add", "-A" }, { cwd = cwd }, function(ok, _, stderr)
    callback(ok, stderr)
  end)
end

-- Unstage all changes (restore entire index to HEAD).
-- callback(ok: boolean, stderr: string)
function M.unstage_all(cwd, callback)
  run({ "git", "restore", "--staged", "." }, { cwd = cwd }, function(ok, _, stderr)
    callback(ok, stderr)
  end)
end

return M
