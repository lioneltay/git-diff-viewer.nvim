local M = {}

--- Create a temporary git repo with a specific state.
--- Returns the repo dir path. Call M.cleanup(dir) when done.
function M.create(opts)
  opts = opts or {}
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")

  local function git(args)
    local cmd = { "git", "-C", dir }
    for _, a in ipairs(args) do
      table.insert(cmd, a)
    end
    local obj = vim.system(cmd):wait()
    assert(obj.code == 0, "git failed: " .. table.concat(args, " ") .. "\n" .. (obj.stderr or ""))
  end

  git({ "init" })
  git({ "config", "user.email", "test@test.com" })
  git({ "config", "user.name", "Test User" })
  git({ "config", "core.hooksPath", "/dev/null" })

  if opts.initial_commit ~= false then
    vim.fn.writefile({ "initial" }, dir .. "/README.md")
    git({ "add", "." })
    git({ "commit", "-m", "initial commit" })
  end

  return dir
end

--- Write a file relative to dir
function M.write_file(dir, rel_path, lines)
  local full = dir .. "/" .. rel_path
  local parent = vim.fn.fnamemodify(full, ":h")
  vim.fn.mkdir(parent, "p")
  vim.fn.writefile(lines, full)
end

--- Run git command in dir, return SystemCompleted object
function M.git(dir, args)
  local cmd = { "git", "-C", dir }
  for _, a in ipairs(args) do
    table.insert(cmd, a)
  end
  return vim.system(cmd):wait()
end

--- Clean up a test repo
function M.cleanup(dir)
  if dir and vim.fn.isdirectory(dir) == 1 then
    vim.fn.delete(dir, "rf")
  end
end

return M
