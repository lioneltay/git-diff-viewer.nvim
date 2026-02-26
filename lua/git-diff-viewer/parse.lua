-- parse.lua — Parse git command output into structured data
--
-- Handles:
--   - porcelain v1 -z status output → list of file entries
--   - numstat -z output → map of path → { added, removed, binary }
--   - Conflict, binary, submodule, and rename detection

local M = {}

-- Conflict status codes per git documentation.
-- A file is a merge conflict if X or Y is 'U', or the code is 'AA' or 'DD'.
local CONFLICT_CODES = {
  UU = true,
  AA = true,
  DD = true,
  AU = true,
  UA = true,
  DU = true,
  UD = true,
}

local function is_conflict(xy)
  return CONFLICT_CODES[xy] ~= nil
end

-- Parse `git status --porcelain=v1 -z` output.
--
-- Format:
--   Normal:  "XY <path><NUL>"
--   Rename:  "XY <new_path><NUL><old_path><NUL>"
--
-- Returns a list of entries:
--   {
--     xy        = "XY"       -- two-char status code
--     path      = string     -- current (new) path
--     orig_path = string|nil -- original path for renames
--     status    = "conflict"|"unstaged"|"staged"|"both"
--   }
--
-- Where status:
--   "conflict"  — XY is a conflict code
--   "staged"    — X is non-blank, Y is blank or '-'
--   "unstaged"  — X is blank or '?', Y is non-blank
--   "both"      — both X and Y are non-blank (MM, etc.)
--   "untracked" — XY is "??"
function M.parse_status(raw)
  local entries = {}

  if not raw or raw == "" then
    return entries
  end

  -- Split on NUL bytes. Lua patterns use %z for NUL, but vim.split is simpler.
  -- Filter empty strings from trailing NUL.
  local raw_parts = vim.split(raw, "\0", { plain = true })
  local parts = {}
  for _, part in ipairs(raw_parts) do
    if part ~= "" then
      table.insert(parts, part)
    end
  end

  local i = 1
  while i <= #parts do
    local entry = parts[i]

    -- First two chars are XY status code; rest is the path (after a space)
    local xy = entry:sub(1, 2)
    local path = entry:sub(4) -- skip "XY " prefix

    local orig_path = nil

    -- Renames have the format "R_ <new_path>" followed by "<old_path>" as the next NUL token
    if xy:sub(1, 1) == "R" or xy:sub(2, 2) == "R" then
      i = i + 1
      orig_path = parts[i]
    end

    -- Determine logical status category
    local status
    if xy == "??" then
      status = "untracked"
    elseif is_conflict(xy) then
      status = "conflict"
    else
      local x = xy:sub(1, 1) -- staged indicator
      local y = xy:sub(2, 2) -- unstaged indicator
      local has_staged = x ~= " " and x ~= "?"
      local has_unstaged = y ~= " " and y ~= "?" and y ~= "-"
      if has_staged and has_unstaged then
        status = "both"
      elseif has_staged then
        status = "staged"
      else
        status = "unstaged"
      end
    end

    table.insert(entries, {
      xy = xy,
      path = path,
      orig_path = orig_path,
      status = status,
    })

    i = i + 1
  end

  return entries
end

-- Parse `git diff [--cached] --numstat -z` output.
--
-- Format (NUL-separated): "<added>\t<removed>\t<path>\0[<orig_path>\0]..."
-- Binary files: "-\t-\t<path>"
--
-- Returns a map: path → { added = number|nil, removed = number|nil, binary = boolean }
-- The 'added' and 'removed' fields are nil for binary files.
function M.parse_numstat(raw)
  local result = {}

  if not raw or raw == "" then
    return result
  end

  -- Split on NUL bytes
  local raw_parts = vim.split(raw, "\0", { plain = true })
  local parts = {}
  for _, part in ipairs(raw_parts) do
    if part ~= "" then
      table.insert(parts, part)
    end
  end

  local i = 1
  while i <= #parts do
    local line = parts[i]

    -- Each entry: "<added>\t<removed>\t<path>"
    -- Renames with -M flag: "<added>\t<removed>\t" (empty path), next two NUL tokens are old_path and new_path
    local added_s, removed_s, path = line:match("^([^\t]+)\t([^\t]+)\t(.*)$")

    if added_s then
      local is_binary = added_s == "-" and removed_s == "-"
      if path == "" then
        -- Rename: consume next two tokens (old_path, new_path)
        local old_path = parts[i + 1]
        local new_path = parts[i + 2]
        if old_path and new_path then
          result[new_path] = {
            added = is_binary and nil or tonumber(added_s),
            removed = is_binary and nil or tonumber(removed_s),
            binary = is_binary,
          }
          i = i + 2
        end
      else
        result[path] = {
          added = is_binary and nil or tonumber(added_s),
          removed = is_binary and nil or tonumber(removed_s),
          binary = is_binary,
        }
      end
    end

    i = i + 1
  end

  return result
end

-- ─── Branch diff parsers ─────────────────────────────────────────────────────

-- Parse `git diff --name-status -z -M` output.
--
-- Format (NUL-separated):
--   Normal:  "<status>\0<path>\0"
--   Rename:  "R<score>\0<new_path>\0<old_path>\0"
--
-- Returns a list of entries:
--   { status_char = "M"|"A"|"D"|"R", path = string, orig_path = string|nil }
function M.parse_name_status(raw)
  local entries = {}

  if not raw or raw == "" then
    return entries
  end

  local raw_parts = vim.split(raw, "\0", { plain = true })
  local parts = {}
  for _, part in ipairs(raw_parts) do
    if part ~= "" then
      table.insert(parts, part)
    end
  end

  local i = 1
  while i <= #parts do
    local token = parts[i]
    -- Status is one char (M/A/D) or R followed by a score (e.g. R100)
    local status_char = token:sub(1, 1)

    if status_char == "R" then
      -- Rename: next token is new_path, then old_path
      local new_path = parts[i + 1]
      local old_path = parts[i + 2]
      if new_path and old_path then
        table.insert(entries, {
          status_char = "R",
          path = new_path,
          orig_path = old_path,
        })
      end
      i = i + 3
    else
      -- M, A, D: next token is path
      local path = parts[i + 1]
      if path then
        table.insert(entries, {
          status_char = status_char,
          path = path,
          orig_path = nil,
        })
      end
      i = i + 2
    end
  end

  return entries
end

-- Build file list for branch diff mode from name-status entries and numstat.
--
-- Maps status chars to xy codes for utils.status_icon() compatibility:
--   M → " M", A → " A", D → " D", R → "R "
--
-- Returns { changes = [...] }
function M.build_branch_file_list(name_status_entries, numstat)
  local changes = {}

  local xy_map = {
    M = " M",
    A = " A",
    D = " D",
    R = "R ",
  }

  for _, entry in ipairs(name_status_entries) do
    local xy = xy_map[entry.status_char] or " M"
    local ns = numstat[entry.path] or {}

    table.insert(changes, {
      xy = xy,
      path = entry.path,
      orig_path = entry.orig_path,
      status = "branch_diff",
      section = "changes",
      added = ns.added,
      removed = ns.removed,
      binary = ns.binary or false,
      submodule = false,
    })
  end

  return { changes = changes }
end

-- Build file list sections from parsed status entries and numstat maps.
--
-- Returns:
--   {
--     conflicts = list of file_items,
--     changes   = list of file_items,  -- unstaged changes
--     staged    = list of file_items,  -- staged changes
--   }
--
-- file_item:
--   {
--     xy        = string
--     path      = string
--     orig_path = string|nil
--     status    = string           -- "conflict"|"staged"|"unstaged"|"both"|"untracked"
--     section   = string           -- "conflicts"|"changes"|"staged"
--     added     = number|nil
--     removed   = number|nil
--     binary    = boolean
--     submodule = boolean          -- set later after async submodule check
--   }
function M.build_file_list(status_entries, unstaged_numstat, staged_numstat)
  local conflicts = {}
  local changes = {}
  local staged = {}

  for _, entry in ipairs(status_entries) do
    local base = {
      xy = entry.xy,
      path = entry.path,
      orig_path = entry.orig_path,
      status = entry.status,
      binary = false,
      submodule = false,
    }

    if entry.status == "conflict" then
      -- Merge conflict — appears only in conflicts section
      local ns = unstaged_numstat[entry.path] or {}
      base.section = "conflicts"
      base.added = ns.added
      base.removed = ns.removed
      base.binary = ns.binary or false
      table.insert(conflicts, base)

    elseif entry.status == "untracked" then
      -- Untracked files — appear in Changes only
      -- +/- counts come from the file itself (all lines = additions), but we
      -- leave that to the caller since we can't read disk files synchronously here
      base.section = "changes"
      base.added = nil
      base.removed = nil
      table.insert(changes, base)

    elseif entry.status == "both" then
      -- MM (and similar): appears in BOTH sections
      -- Changes section: unstaged diff (working file vs staged/index)
      local uns = unstaged_numstat[entry.path] or {}
      local changes_item = vim.tbl_extend("force", base, {
        section = "changes",
        added = uns.added,
        removed = uns.removed,
        binary = uns.binary or false,
      })
      table.insert(changes, changes_item)

      -- Staged section: staged diff (staged/index vs HEAD)
      local stg = staged_numstat[entry.path] or {}
      local staged_item = vim.tbl_extend("force", base, {
        section = "staged",
        added = stg.added,
        removed = stg.removed,
        binary = stg.binary or false,
      })
      table.insert(staged, staged_item)

    elseif entry.status == "unstaged" then
      local ns = unstaged_numstat[entry.path] or {}
      base.section = "changes"
      base.added = ns.added
      base.removed = ns.removed
      base.binary = ns.binary or false
      table.insert(changes, base)

    elseif entry.status == "staged" then
      local ns = staged_numstat[entry.path] or {}
      base.section = "staged"
      base.added = ns.added
      base.removed = ns.removed
      base.binary = ns.binary or false
      table.insert(staged, base)
    end
  end

  return { conflicts = conflicts, changes = changes, staged = staged }
end


return M
