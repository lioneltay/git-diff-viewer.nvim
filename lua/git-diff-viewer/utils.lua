-- utils.lua — Shared helpers

local M = {}

-- Show a Neovim notification. Must be called from the main thread.
function M.notify(msg, level)
  vim.notify("[git-diff-viewer] " .. msg, level or vim.log.levels.INFO)
end

function M.error(msg)
  M.notify(msg, vim.log.levels.ERROR)
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

-- Define highlight groups that link to standard Neovim groups.
-- Uses `default = true` so user overrides win.
function M.setup_highlights()
  local links = {
    GitDiffViewerSectionHeader  = "Label",
    GitDiffViewerSectionCount   = "Identifier",
    GitDiffViewerFileName       = "Normal",
    GitDiffViewerFileNameActive = "Type",
    GitDiffViewerFolderName     = "Directory",
    GitDiffViewerFolderIcon     = "NonText",
    GitDiffViewerStatusM        = "diffChanged",
    GitDiffViewerStatusA        = "diffAdded",
    GitDiffViewerStatusD        = "diffRemoved",
    GitDiffViewerStatusR        = "Type",
    GitDiffViewerStatusConflict = "DiagnosticWarn",
    GitDiffViewerInsertions     = "diffAdded",
    GitDiffViewerDeletions      = "diffRemoved",
    GitDiffViewerDim            = "Comment",
  }
  for name, target in pairs(links) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
end

-- Return the highlight group for a given status icon character.
function M.get_status_hl(icon)
  local map = {
    M = "GitDiffViewerStatusM",
    A = "GitDiffViewerStatusA",
    D = "GitDiffViewerStatusD",
    R = "GitDiffViewerStatusR",
    ["?"] = "GitDiffViewerStatusA",
    ["!"] = "GitDiffViewerStatusConflict",
  }
  return map[icon] or "GitDiffViewerStatusM"
end

-- Fuzzy match: check if all characters in query appear in order in str.
-- Case-insensitive. Returns true/false.
function M.fuzzy_match(str, query)
  if query == "" then return true end
  str = str:lower()
  query = query:lower()
  local si = 1
  for qi = 1, #query do
    local ch = query:sub(qi, qi)
    local found = str:find(ch, si, true)
    if not found then return false end
    si = found + 1
  end
  return true
end

-- Fuzzy filter and sort: returns items sorted by match quality using Vim's built-in scorer.
-- items: list of strings to filter
-- query: search string
-- Returns a new list of matching strings, best matches first.
function M.fuzzy_filter(items, query)
  if query == "" then return items end
  return vim.fn.matchfuzzy(items, query)
end

return M
