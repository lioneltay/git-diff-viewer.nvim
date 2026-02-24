-- utils.lua — Shared helpers

local M = {}

-- Map common file extensions to Neovim filetypes.
-- This is used for scratch buffers where `filetype detect` is unreliable
-- because the buffer has no real file path on disk.
local EXT_FT_MAP = {
  -- Web
  ts = "typescript",
  tsx = "typescriptreact",
  js = "javascript",
  jsx = "javascriptreact",
  mjs = "javascript",
  cjs = "javascript",
  html = "html",
  css = "css",
  scss = "scss",
  sass = "sass",
  less = "less",
  -- Data
  json = "json",
  jsonc = "jsonc",
  yaml = "yaml",
  yml = "yaml",
  toml = "toml",
  xml = "xml",
  -- Config / scripts
  sh = "sh",
  bash = "bash",
  zsh = "zsh",
  fish = "fish",
  lua = "lua",
  vim = "vim",
  -- Systems
  py = "python",
  rb = "ruby",
  go = "go",
  rs = "rust",
  c = "c",
  cpp = "cpp",
  h = "c",
  hpp = "cpp",
  java = "java",
  kt = "kotlin",
  swift = "swift",
  -- Markup / docs
  md = "markdown",
  mdx = "markdown",
  rst = "rst",
  txt = "text",
  -- Build / CI
  dockerfile = "dockerfile",
  makefile = "make",
  mk = "make",
  -- GraphQL
  graphql = "graphql",
  gql = "graphql",
}

-- Return the Neovim filetype for a given file path.
-- Falls back to empty string (Neovim will leave filetype unset).
function M.path_to_ft(path)
  if not path then return "" end
  local ext = path:match("%.([^./]+)$")
  if not ext then
    -- Handle extensionless files like Dockerfile, Makefile
    local basename = path:match("[^/]+$") or path
    return EXT_FT_MAP[basename:lower()] or ""
  end
  return EXT_FT_MAP[ext:lower()] or ext:lower()
end

-- Show a Neovim notification. Must be called from the main thread.
function M.notify(msg, level)
  vim.notify("[git-diff-viewer] " .. msg, level or vim.log.levels.INFO)
end

function M.error(msg)
  M.notify(msg, vim.log.levels.ERROR)
end

function M.warn(msg)
  M.notify(msg, vim.log.levels.WARN)
end

-- Return the path relative to git_root for display purposes.
-- If path does not start with git_root, returns the path unchanged.
function M.relative_path(path, git_root)
  if git_root and vim.startswith(path, git_root .. "/") then
    return path:sub(#git_root + 2)
  end
  return path
end

-- Split a relative file path into directory parts and filename.
-- e.g. "src/components/Button.tsx" → { dirs = {"src", "components"}, file = "Button.tsx" }
-- e.g. "main.go" → { dirs = {}, file = "main.go" }
function M.split_path(rel_path)
  local parts = {}
  for part in rel_path:gmatch("[^/]+") do
    table.insert(parts, part)
  end
  if #parts == 0 then
    return { dirs = {}, file = rel_path }
  end
  local file = table.remove(parts)
  return { dirs = parts, file = file }
end

-- Build the directory path prefix for a file entry.
-- e.g. dirs = {"src", "components"} → "src/components"
function M.dirs_to_path(dirs)
  return table.concat(dirs, "/")
end

-- Status code to display icon.
function M.status_icon(xy, section)
  local x = xy:sub(1, 1)
  local y = xy:sub(2, 2)

  -- Conflict
  if xy == "UU" or xy == "AA" or xy == "DD" or xy == "AU" or xy == "UA" or xy == "DU" or xy == "UD" then
    return "!"
  end

  -- Untracked
  if xy == "??" then return "?" end

  -- Rename
  if x == "R" or y == "R" then return "R" end

  -- Use the relevant column based on which section we're in
  local code = section == "staged" and x or y

  if code == "M" then return "M" end
  if code == "A" then return "A" end
  if code == "D" then return "D" end

  -- Fallback: use whichever column is non-blank
  local effective = x ~= " " and x ~= "?" and x or y
  return effective ~= " " and effective ~= "?" and effective or "M"
end

-- Format +/- counts for display. Returns "" if both are nil (e.g. binary).
function M.format_counts(added, removed)
  if added == nil and removed == nil then
    return ""
  end
  local parts = {}
  if added and added > 0 then
    table.insert(parts, "+" .. added)
  end
  if removed and removed > 0 then
    table.insert(parts, "-" .. removed)
  end
  return table.concat(parts, " ")
end

return M
