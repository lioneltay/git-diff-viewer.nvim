-- diff.lua — Load and display diffs in the right pane(s)
--
-- Handles all file state layouts from the plan:
--   Modified (unstaged)   → side-by-side: HEAD (read-only) | working file (editable)
--   Modified (staged)     → side-by-side: HEAD (read-only) | staged :0: (read-only)
--   MM in Changes         → side-by-side: staged :0: (read-only) | working file (editable)
--   MM in Staged          → side-by-side: HEAD (read-only) | staged :0: (read-only)
--   New/untracked         → single pane: working file (editable)
--   Staged new (A_)       → single pane: staged :0: (read-only)
--   Deleted (unstaged)    → single pane: HEAD (read-only)
--   Deleted (staged)      → single pane: HEAD (read-only)
--   Renamed               → side-by-side: HEAD:old (read-only) | working file (editable)
--   Binary                → message pane
--   Merge conflict        → single pane: working file (editable, raw markers)
--   Empty repo            → single pane: working file or read-only fallback

local state = require("git-diff-viewer.state")
local git = require("git-diff-viewer.git")
local utils = require("git-diff-viewer.utils")
local layout = require("git-diff-viewer.ui.layout")
local config = require("git-diff-viewer.config")

local M = {}

-- ─── Scratch buffer helpers ───────────────────────────────────────────────────

-- Get or create a cached scratch buffer for a git show key.
-- cache_key examples: "HEAD:src/app.ts", ":0:src/app.ts"
local function get_or_create_scratch(cache_key, path)
  if state.buf_cache[cache_key] and vim.api.nvim_buf_is_valid(state.buf_cache[cache_key]) then
    return state.buf_cache[cache_key]
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  -- Name gives the buffer a meaningful identity (and preserves extension for icons)
  vim.api.nvim_buf_set_name(buf, "git-diff-viewer://" .. cache_key)
  -- Set filetype from extension — more reliable than `filetype detect` on scratch buffers
  local ft = utils.path_to_ft(path)
  if ft ~= "" then
    vim.api.nvim_set_option_value("filetype", ft, { buf = buf })
  end

  state.buf_cache[cache_key] = buf
  return buf
end

-- Fill a scratch buffer with lines (marks it read-only afterwards).
local function set_buf_content(buf, lines)
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_set_option_value("readonly", false, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_set_option_value("readonly", true, { buf = buf })
end

-- Create a simple message buffer (binary, submodule, etc.)
local function message_buf(msg)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { msg })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  return buf
end

-- ─── Window setup ─────────────────────────────────────────────────────────────

-- Apply diff mode settings to a window (both panes must already be set up).
local function enable_diff_mode(win)
  vim.api.nvim_set_option_value("diff", true, { win = win })
  vim.api.nvim_set_option_value("scrollbind", true, { win = win })
  vim.api.nvim_set_option_value("cursorbind", true, { win = win })
  vim.api.nvim_set_option_value("wrap", false, { win = win })
  vim.api.nvim_set_option_value("foldmethod", "diff", { win = win })
  vim.api.nvim_set_option_value("foldlevel", 999, { win = win }) -- show all
end

-- Set up keymaps in a diff buffer.
local function setup_diff_keymaps(buf)
  local dk = config.options.diff_keymaps

  local function map(key, fn, desc)
    vim.keymap.set("n", key, fn, { buffer = buf, desc = desc, nowait = true })
  end

  map(dk.close, function()
    require("git-diff-viewer").close()
  end, "Close diff viewer")

  map(dk.open_file, function()
    local item = state.current_diff and state.current_diff.item
    if item then
      local full_path = state.git_root .. "/" .. item.path
      vim.cmd("tabprevious")
      vim.cmd("edit " .. vim.fn.fnameescape(full_path))
    end
  end, "Open file in previous tab")

  map(dk.focus_panel, function()
    if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
      vim.api.nvim_set_current_win(state.panel_win)
    end
  end, "Focus file panel")
end

-- Jump to the first change hunk after diff mode is enabled.
-- Must be called after buffers and windows are set up.
local function jump_to_first_hunk(win)
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  vim.api.nvim_set_current_win(win)
  -- ]c is Neovim's built-in "next diff hunk" — works when diff mode is on
  pcall(vim.cmd, "normal! ]c")
end

-- ─── Single-pane display ──────────────────────────────────────────────────────

-- Display a single buffer in one diff window (no diff mode).
local function show_single(buf, readonly)
  local wins = layout.open_diff_wins(1)
  local win = wins[1]

  vim.api.nvim_win_set_buf(win, buf)
  state.diff_bufs = { buf }

  if not readonly then
    setup_diff_keymaps(buf)
  end

  -- For the working file (editable), just focus it
  vim.api.nvim_set_current_win(win)
end

-- ─── Side-by-side display ─────────────────────────────────────────────────────

-- Display two buffers side-by-side with diff mode enabled.
local function show_side_by_side(left_buf, right_buf)
  local wins = layout.open_diff_wins(2)
  local left_win = wins[1]
  local right_win = wins[2]

  vim.api.nvim_win_set_buf(left_win, left_buf)
  vim.api.nvim_win_set_buf(right_win, right_buf)
  state.diff_bufs = { left_buf, right_buf }

  enable_diff_mode(left_win)
  enable_diff_mode(right_win)

  setup_diff_keymaps(left_buf)
  setup_diff_keymaps(right_buf)

  -- Focus right pane (the "new" side — more useful for editing)
  vim.api.nvim_set_current_win(right_win)
  jump_to_first_hunk(right_win)
end

-- ─── Main entry point ─────────────────────────────────────────────────────────

-- Open the diff for a file_item.
-- This function kicks off async git show calls and renders when ready.
function M.open(item)
  state.current_diff = { item = item }

  local cwd = state.git_root
  local path = item.path
  local xy = item.xy
  local section = item.section

  -- Binary file — show message
  if item.binary then
    local buf = message_buf("Binary file — cannot display diff")
    show_single(buf, true)
    return
  end

  -- Submodule — show message
  if item.submodule then
    local buf = message_buf("Submodule — diff not supported")
    show_single(buf, true)
    return
  end

  -- Merge conflict — single editable pane (working file with raw markers)
  if section == "conflicts" then
    local full_path = cwd .. "/" .. path
    -- Load the actual working file buffer (or find it if already open)
    local working_buf = vim.fn.bufnr(full_path, true)
    vim.fn.bufload(working_buf)
    setup_diff_keymaps(working_buf)
    show_single(working_buf, false)
    return
  end

  -- Untracked — single editable pane
  if xy == "??" then
    local full_path = cwd .. "/" .. path
    local working_buf = vim.fn.bufnr(full_path, true)
    vim.fn.bufload(working_buf)
    setup_diff_keymaps(working_buf)
    show_single(working_buf, false)
    return
  end

  local x = xy:sub(1, 1) -- staged char
  local y = xy:sub(2, 2) -- unstaged char

  -- Staged new file (A_) — single pane showing staged content
  if x == "A" and (y == " " or y == "-") then
    local cache_key = ":0:" .. path
    local staged_buf = get_or_create_scratch(cache_key, path)
    git.show_staged(cwd, path, function(ok, content)
      vim.schedule(function()
        if ok then
          local lines = vim.split(content, "\n", { plain = true })
          -- Remove trailing empty line from git output
          if lines[#lines] == "" then table.remove(lines) end
          set_buf_content(staged_buf, lines)
        else
          set_buf_content(staged_buf, { "(error loading staged content)" })
        end
        show_single(staged_buf, true)
      end)
    end)
    return
  end

  -- Deleted unstaged (_D) or staged (D_) — single pane showing HEAD content
  if x == "D" or y == "D" then
    -- For staged deletion, show what was at HEAD (left pane only)
    local cache_key = "HEAD:" .. path
    local head_buf = get_or_create_scratch(cache_key, path)
    if not state.has_commits then
      set_buf_content(head_buf, { "(no base commit)" })
      show_single(head_buf, true)
      return
    end
    git.show_head(cwd, path, function(ok, content)
      vim.schedule(function()
        if ok then
          local lines = vim.split(content, "\n", { plain = true })
          if lines[#lines] == "" then table.remove(lines) end
          set_buf_content(head_buf, lines)
        else
          set_buf_content(head_buf, { "(error loading HEAD content)" })
        end
        show_single(head_buf, true)
      end)
    end)
    return
  end

  -- From here: side-by-side layouts
  -- Determine which content goes on left and right based on section and XY

  -- MM in Changes → left = staged (:0:), right = working file
  -- MM in Staged  → left = HEAD, right = staged (:0:)
  -- Modified staged (M_) → left = HEAD, right = staged (:0:)
  -- Modified unstaged (_M) → left = HEAD, right = working file
  -- Renamed → left = HEAD:old_path, right = working file

  local left_buf, right_buf

  if item.status == "both" and section == "changes" then
    -- MM in Changes: left = staged, right = working file
    local staged_key = ":0:" .. path
    left_buf = get_or_create_scratch(staged_key, path)

    local full_path = cwd .. "/" .. path
    right_buf = vim.fn.bufnr(full_path, true)
    vim.fn.bufload(right_buf)

    if not state.has_commits then
      set_buf_content(left_buf, { "(no base commit)" })
      show_side_by_side(left_buf, right_buf)
      return
    end

    git.show_staged(cwd, path, function(ok, content)
      vim.schedule(function()
        if ok then
          local lines = vim.split(content, "\n", { plain = true })
          if lines[#lines] == "" then table.remove(lines) end
          set_buf_content(left_buf, lines)
        else
          set_buf_content(left_buf, { "(error loading staged content)" })
        end
        show_side_by_side(left_buf, right_buf)
      end)
    end)
    return
  end

  if item.status == "both" and section == "staged" then
    -- MM in Staged: left = HEAD, right = staged
    local head_key = "HEAD:" .. path
    local staged_key = ":0:" .. path
    left_buf = get_or_create_scratch(head_key, path)
    right_buf = get_or_create_scratch(staged_key, path)

    if not state.has_commits then
      set_buf_content(left_buf, { "(no base commit)" })
      show_side_by_side(left_buf, right_buf)
      return
    end

    local pending = 2
    local function done()
      pending = pending - 1
      if pending == 0 then
        show_side_by_side(left_buf, right_buf)
      end
    end

    git.show_head(cwd, path, function(ok, content)
      vim.schedule(function()
        if ok then
          local lines = vim.split(content, "\n", { plain = true })
          if lines[#lines] == "" then table.remove(lines) end
          set_buf_content(left_buf, lines)
        else
          set_buf_content(left_buf, { "(error loading HEAD content)" })
        end
        done()
      end)
    end)

    git.show_staged(cwd, path, function(ok, content)
      vim.schedule(function()
        if ok then
          local lines = vim.split(content, "\n", { plain = true })
          if lines[#lines] == "" then table.remove(lines) end
          set_buf_content(right_buf, lines)
        else
          set_buf_content(right_buf, { "(error loading staged content)" })
        end
        done()
      end)
    end)
    return
  end

  if section == "staged" then
    -- Staged modified: left = HEAD, right = staged :0:
    local head_key = "HEAD:" .. path
    local staged_key = ":0:" .. path
    left_buf = get_or_create_scratch(head_key, path)
    right_buf = get_or_create_scratch(staged_key, path)

    if not state.has_commits then
      set_buf_content(left_buf, { "(no base commit)" })
      show_side_by_side(left_buf, right_buf)
      return
    end

    local pending = 2
    local function done()
      pending = pending - 1
      if pending == 0 then
        show_side_by_side(left_buf, right_buf)
      end
    end

    git.show_head(cwd, path, function(ok, content)
      vim.schedule(function()
        if ok then
          local lines = vim.split(content, "\n", { plain = true })
          if lines[#lines] == "" then table.remove(lines) end
          set_buf_content(left_buf, lines)
        else
          set_buf_content(left_buf, { "(error loading HEAD content)" })
        end
        done()
      end)
    end)
    git.show_staged(cwd, path, function(ok, content)
      vim.schedule(function()
        if ok then
          local lines = vim.split(content, "\n", { plain = true })
          if lines[#lines] == "" then table.remove(lines) end
          set_buf_content(right_buf, lines)
        else
          set_buf_content(right_buf, { "(error loading staged content)" })
        end
        done()
      end)
    end)
    return
  end

  -- Default: unstaged modified or renamed
  -- Left = HEAD (or HEAD:old_path for renames), right = working file
  local old_path = item.orig_path or path
  local head_key = "HEAD:" .. old_path
  left_buf = get_or_create_scratch(head_key, old_path)

  local full_path = cwd .. "/" .. path
  right_buf = vim.fn.bufnr(full_path, true)
  vim.fn.bufload(right_buf)

  if not state.has_commits then
    set_buf_content(left_buf, { "(no base commit)" })
    show_side_by_side(left_buf, right_buf)
    return
  end

  git.show_head(cwd, old_path, function(ok, content)
    vim.schedule(function()
      if ok then
        local lines = vim.split(content, "\n", { plain = true })
        if lines[#lines] == "" then table.remove(lines) end
        set_buf_content(left_buf, lines)
      else
        set_buf_content(left_buf, { "(error loading HEAD content)" })
      end
      show_side_by_side(left_buf, right_buf)
    end)
  end)
end

return M
