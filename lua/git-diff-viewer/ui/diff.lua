-- diff.lua — Load and display diffs in the right pane(s)
--
-- Handles all file state layouts from the plan:
--   Modified (unstaged)   → side-by-side: HEAD (read-only) | working file (editable)
--   Modified (staged)     → side-by-side: HEAD (read-only) | staged :0: (read-only)
--   MM in Changes         → side-by-side: staged :0: (read-only) | working file (editable)
--   MM in Staged          → side-by-side: HEAD (read-only) | staged :0: (read-only)
--   New/untracked         → single pane: working file (editable)
--   Staged new (A_/AM)    → single pane: staged :0: (read-only)
--   Deleted (unstaged)    → single pane: HEAD (read-only)
--   Deleted (staged)      → single pane: HEAD (read-only)
--   Renamed               → side-by-side: HEAD:old (read-only) | working file (editable)
--   Binary                → message pane
--   Merge conflict        → single pane: working file (editable, raw markers)
--   Empty repo            → single pane: working file or read-only fallback

local state = require("git-diff-viewer.state")
local git = require("git-diff-viewer.git")
local layout = require("git-diff-viewer.ui.layout")
local config = require("git-diff-viewer.config")

local M = {}

-- Load a real file buffer for diff display.
-- Suppresses BufReadPost for NEW buffers to prevent auto-reload.nvim from
-- watching files loaded by our plugin (avoids E94 from stale checktime timers).
-- Already-loaded buffers are a no-op — they keep their existing watchers.
local function load_for_diff(buf)
  if vim.api.nvim_buf_is_loaded(buf) then return end
  local ei = vim.o.eventignore
  vim.o.eventignore = (ei == "" and "BufReadPost" or (ei .. ",BufReadPost"))
  vim.fn.bufload(buf)
  vim.o.eventignore = ei
  -- Manually detect filetype since BufReadPost was suppressed
  if vim.bo[buf].filetype == "" then
    local ft = vim.filetype.match({ buf = buf })
    if ft then vim.bo[buf].filetype = ft end
  end
end

-- Ensure a real file buffer stays loaded when hidden from diff windows.
-- Prevents race conditions with auto-reload.nvim's debounced checktime
-- (the timer may fire after BufUnload unwatches the file).
-- Saves original bufhidden so it can be restored when the viewer closes.
local function pin_buffer(buf)
  if vim.bo[buf].buftype ~= "" then return end -- only pin real file buffers
  if state.bufhidden_overrides[buf] ~= nil then return end -- already pinned
  state.bufhidden_overrides[buf] = vim.bo[buf].bufhidden
  vim.bo[buf].bufhidden = "hide"
end

-- Restore original bufhidden on all pinned buffers. Called on viewer close.
function M.restore_bufhidden()
  for buf, original in pairs(state.bufhidden_overrides) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(function() vim.bo[buf].bufhidden = original end)
    end
  end
  state.bufhidden_overrides = {}
end

-- ─── Scratch buffer helpers ───────────────────────────────────────────────────

-- Get or create a cached scratch buffer for a git show key.
-- cache_key examples: "HEAD:src/app.ts", ":0:src/app.ts"
local function get_or_create_scratch(cache_key, path)
  if state.buf_cache[cache_key] and vim.api.nvim_buf_is_valid(state.buf_cache[cache_key]) then
    return state.buf_cache[cache_key]
  end

  -- Orphan detection: buffer may exist from a previous cache clear but still be valid.
  -- Find it by name and reuse to preserve jumplist entries.
  local expected_name = "git-diff-viewer://" .. cache_key
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == expected_name then
      state.buf_cache[cache_key] = b
      return b
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  -- "hide" so cached buffers survive when the window is closed (enables jumplist + cache reuse)
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
  -- Name gives the buffer a meaningful identity (and preserves extension for icons)
  vim.api.nvim_buf_set_name(buf, expected_name)
  -- Set filetype from path — vim.filetype.match handles extensions and special filenames
  local ft = vim.filetype.match({ filename = path })
  if ft then
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
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { msg })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  return buf
end

-- ─── Async content loader ───────────────────────────────────────────────────

-- Load git content into a scratch buffer asynchronously.
-- git_fn: function(callback) — the git.show_head / git.show_staged call
-- buf: target scratch buffer
-- error_msg: string to show on failure
-- on_done: optional callback called after content is loaded
local function load_git_content(git_fn, buf, error_msg, on_done)
  git_fn(function(ok, content)
    vim.schedule(function()
      -- Guard: viewer may have closed while async was in flight
      if not state.is_active() then return end

      if ok then
        local lines = vim.split(content, "\n", { plain = true })
        if lines[#lines] == "" then table.remove(lines) end
        set_buf_content(buf, lines)
      else
        set_buf_content(buf, { error_msg })
      end
      if on_done then on_done() end
    end)
  end)
end

-- ─── Window setup ─────────────────────────────────────────────────────────────

-- Apply diff mode settings to a window (both panes must already be set up).
local function enable_diff_mode(win)
  vim.api.nvim_set_option_value("diff", true, { win = win })
  vim.api.nvim_set_option_value("scrollbind", true, { win = win })
  vim.api.nvim_set_option_value("cursorbind", true, { win = win })
  vim.api.nvim_set_option_value("foldmethod", "diff", { win = win })
  vim.api.nvim_set_option_value("foldlevel", 999, { win = win }) -- show all
end

-- Set up keymaps in a diff buffer, tracking for cleanup.
-- Keymaps are guarded: they only fire when the current tab is the diff viewer
-- tab. On other tabs the original key sequence is fed back so normal mappings
-- work. This prevents plugin keymaps leaking into normal editing when a real
-- file buffer is shared across tabs.
local function setup_diff_keymaps(buf)
  local dk = config.options.diff_keymaps

  local function map(key, fn, desc)
    local wrapper
    wrapper = function()
      if state.tab and vim.api.nvim_tabpage_is_valid(state.tab)
        and vim.api.nvim_get_current_tabpage() == state.tab then
        fn()
      else
        -- Not on the diff tab — temporarily remove this mapping and replay
        -- the key so the user's normal mapping fires, then restore ours.
        pcall(vim.keymap.del, "n", key, { buffer = buf })
        vim.api.nvim_feedkeys(
          vim.api.nvim_replace_termcodes(key, true, false, true), "m", false
        )
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(buf) then
            vim.keymap.set("n", key, wrapper, { buffer = buf, desc = desc, nowait = true })
          end
        end)
      end
    end
    vim.keymap.set("n", key, wrapper, { buffer = buf, desc = desc, nowait = true })
  end

  map(dk.close, function()
    require("git-diff-viewer").close()
  end, "Close diff viewer")

  map(dk.open_file, function()
    local item = state.current_diff and state.current_diff.item
    if item then
      local full_path = state.git_root .. "/" .. item.path
      -- Bug #12: use tracked origin tab instead of tabprevious
      if state.origin_tab and vim.api.nvim_tabpage_is_valid(state.origin_tab) then
        vim.api.nvim_set_current_tabpage(state.origin_tab)
      else
        vim.cmd("tabprevious")
      end
      vim.cmd("edit " .. vim.fn.fnameescape(full_path))
    end
  end, "Open file in previous tab")

  map(dk.focus_panel, function()
    if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
      vim.api.nvim_set_current_win(state.panel_win)
    end
  end, "Focus file panel")

  -- Diff hunk navigation — explicit maps so which-key/mini.bracketed don't intercept.
  -- Map both ]c (native) and ]h (gitsigns convention) for muscle memory compatibility.
  local function next_hunk() pcall(vim.cmd, "normal! ]c") end
  local function prev_hunk() pcall(vim.cmd, "normal! [c") end
  map("]c", next_hunk, "Next diff hunk")
  map("[c", prev_hunk, "Previous diff hunk")
  map("]h", next_hunk, "Next diff hunk")
  map("[h", prev_hunk, "Previous diff hunk")

  -- Viewed diffs picker
  map("<leader>fb", function()
    require("git-diff-viewer.ui.viewed").open()
  end, "Browse viewed diffs")

  -- File finder (same as panel keymap)
  map("<leader>ff", function()
    require("git-diff-viewer.ui.finder").open()
  end, "Find changed files")

  -- Track for cleanup (Bug #11: keymaps on real file buffers must be removed on close)
  state.keymap_bufs[buf] = true
end

-- Remove diff keymaps from a single buffer.
local function cleanup_diff_keymaps(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local dk = config.options.diff_keymaps
  pcall(vim.keymap.del, "n", dk.close, { buffer = buf })
  pcall(vim.keymap.del, "n", dk.open_file, { buffer = buf })
  pcall(vim.keymap.del, "n", dk.focus_panel, { buffer = buf })
  pcall(vim.keymap.del, "n", "]c", { buffer = buf })
  pcall(vim.keymap.del, "n", "[c", { buffer = buf })
  pcall(vim.keymap.del, "n", "]h", { buffer = buf })
  pcall(vim.keymap.del, "n", "[h", { buffer = buf })
  pcall(vim.keymap.del, "n", "<leader>fb", { buffer = buf })
  pcall(vim.keymap.del, "n", "<leader>ff", { buffer = buf })
end

-- Remove diff keymaps from all tracked buffers. Called on viewer close.
function M.cleanup_all_keymaps()
  for buf, _ in pairs(state.keymap_bufs) do
    cleanup_diff_keymaps(buf)
  end
  state.keymap_bufs = {}
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

-- Restore focus to the panel window (only if we're on the diff tab).
local function refocus_panel()
  if not state.tab or not vim.api.nvim_tabpage_is_valid(state.tab) then return end
  if vim.api.nvim_get_current_tabpage() ~= state.tab then return end
  if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
    vim.api.nvim_set_current_win(state.panel_win)
  end
end

-- Disable diff mode and clear related options from a window.
local function disable_diff_mode(win)
  vim.api.nvim_set_option_value("diff", false, { win = win })
  vim.api.nvim_set_option_value("scrollbind", false, { win = win })
  vim.api.nvim_set_option_value("cursorbind", false, { win = win })
  vim.api.nvim_set_option_value("foldmethod", "manual", { win = win })
end

-- Clear diff panes when the viewed file no longer exists (e.g., after discard).
function M.show_empty()
  local wins = layout.open_diff_wins(1)
  local win = wins[1]
  local buf = message_buf("No changes")
  vim.api.nvim_win_set_buf(win, buf)
  state.diff_bufs = { buf }
  disable_diff_mode(win)
  vim.api.nvim_set_option_value("winfixbuf", true, { win = win })
  refocus_panel()
end

-- Display a single buffer in one diff window (no diff mode).
-- Always sets up keymaps (Bug #10: readonly panes need q/gf/<C-h> too).
local function show_single(buf)
  local wins = layout.open_diff_wins(1)
  local win = wins[1]

  vim.api.nvim_win_set_buf(win, buf)
  state.diff_bufs = { buf }

  -- Reload real file buffers from disk (picks up external changes)
  if vim.bo[buf].buftype == "" then
    pcall(vim.cmd, "checktime " .. buf)
  end

  -- Clear any lingering diff mode settings from previous side-by-side diff
  disable_diff_mode(win)

  -- Lock window to this buffer — prevents IDE bridge / external plugins
  -- from loading unrelated buffers into our diff pane.
  vim.api.nvim_set_option_value("winfixbuf", true, { win = win })

  setup_diff_keymaps(buf)
  refocus_panel()
end

-- ─── Side-by-side display ─────────────────────────────────────────────────────

-- Display two buffers side-by-side with diff mode enabled.
local function show_side_by_side(left_buf, right_buf)
  local wins = layout.open_diff_wins(2)
  local left_win = wins[1]
  local right_win = wins[2]

  -- Disable diff mode before swapping buffers to prevent transient
  -- diff computation against mismatched buffers (when windows are reused)
  disable_diff_mode(left_win)
  disable_diff_mode(right_win)

  vim.api.nvim_win_set_buf(left_win, left_buf)
  vim.api.nvim_win_set_buf(right_win, right_buf)
  state.diff_bufs = { left_buf, right_buf }

  -- Reload real file buffers from disk (picks up external changes)
  for _, b in ipairs(state.diff_bufs) do
    if vim.bo[b].buftype == "" then
      pcall(vim.cmd, "checktime " .. b)
    end
  end

  enable_diff_mode(left_win)
  enable_diff_mode(right_win)

  -- Lock windows to their buffers — prevents IDE bridge / external plugins
  -- from loading unrelated buffers into our diff panes.
  vim.api.nvim_set_option_value("winfixbuf", true, { win = left_win })
  vim.api.nvim_set_option_value("winfixbuf", true, { win = right_win })

  -- Force Neovim to recompute diff — programmatic buffer+diff-mode changes
  -- don't always trigger Neovim's internal diff recomputation.
  vim.cmd("diffupdate")

  setup_diff_keymaps(left_buf)
  setup_diff_keymaps(right_buf)

  jump_to_first_hunk(right_win)
  refocus_panel()
end

-- ─── Main entry point ─────────────────────────────────────────────────────────

-- Track a viewed diff in the history (most recent first, dedup by path+section).
local function track_viewed(item)
  local vd = state.viewed_diffs
  -- Remove existing entry for this path+section
  for i = #vd, 1, -1 do
    if vd[i].path == item.path and vd[i].section == item.section then
      table.remove(vd, i)
    end
  end
  -- Insert at front (most recent first)
  table.insert(vd, 1, { path = item.path, section = item.section })
end

-- Open the diff for a file_item.
-- This function kicks off async git show calls and renders when ready.
function M.open(item)
  state.current_diff = { item = item }
  track_viewed(item)

  local cwd = state.git_root
  local path = item.path
  local xy = item.xy
  local section = item.section

  -- Binary file — show message
  if item.binary then
    local buf = message_buf("Binary file — cannot display diff")
    show_single(buf)
    return
  end

  -- Submodule — show message
  if item.submodule then
    local buf = message_buf("Submodule — diff not supported")
    show_single(buf)
    return
  end

  -- Branch diff mode — compare working tree against target branch
  if item.status == "branch_diff" then
    local target = state.target_branch
    local full_path = cwd .. "/" .. path

    -- Added: single pane, working tree file
    if xy == " A" then
      local working_buf = vim.fn.bufnr(full_path, true)
      load_for_diff(working_buf)
      pin_buffer(working_buf)
      show_single(working_buf)
      return
    end

    -- Deleted: single pane, show from target branch
    if xy == " D" then
      local cache_key = target .. ":" .. path
      local ref_buf = get_or_create_scratch(cache_key, path)
      load_git_content(
        function(cb) git.show_ref(cwd, target, path, cb) end,
        ref_buf,
        "(error loading " .. target .. " content)",
        function() show_single(ref_buf) end
      )
      return
    end

    -- Modified or Renamed: side-by-side
    local old_path = item.orig_path or path
    local cache_key = target .. ":" .. old_path
    local left_buf = get_or_create_scratch(cache_key, old_path)

    local right_buf = vim.fn.bufnr(full_path, true)
    load_for_diff(right_buf)
    pin_buffer(right_buf)

    load_git_content(
      function(cb) git.show_ref(cwd, target, old_path, cb) end,
      left_buf,
      "(error loading " .. target .. " content)",
      function() show_side_by_side(left_buf, right_buf) end
    )
    return
  end

  -- Merge conflict — single editable pane (working file with raw markers)
  -- Bug #22 fix: removed explicit setup_diff_keymaps here — show_single handles it
  if section == "conflicts" then
    local full_path = cwd .. "/" .. path
    local working_buf = vim.fn.bufnr(full_path, true)
    load_for_diff(working_buf)
    pin_buffer(working_buf)
    show_single(working_buf)
    return
  end

  -- Untracked — single editable pane
  -- Bug #22 fix: removed explicit setup_diff_keymaps here — show_single handles it
  if xy == "??" then
    local full_path = cwd .. "/" .. path
    local working_buf = vim.fn.bufnr(full_path, true)
    load_for_diff(working_buf)
    pin_buffer(working_buf)
    show_single(working_buf)
    return
  end

  local x = xy:sub(1, 1) -- staged char
  local y = xy:sub(2, 2) -- unstaged char

  -- Staged new file in Staged section — single pane showing staged content.
  -- Covers A_ (pure staged) and AM (staged + modified) — no HEAD exists either way.
  if x == "A" and section == "staged" then
    local cache_key = ":0:" .. path
    local staged_buf = get_or_create_scratch(cache_key, path)
    load_git_content(
      function(cb) git.show_staged(cwd, path, cb) end,
      staged_buf,
      "(error loading staged content)",
      function() show_single(staged_buf) end
    )
    return
  end

  -- Deleted unstaged (_D) or staged (D_) — single pane showing HEAD content
  if x == "D" or y == "D" then
    local cache_key = "HEAD:" .. path
    local head_buf = get_or_create_scratch(cache_key, path)
    if not state.has_commits then
      set_buf_content(head_buf, { "(no base commit)" })
      show_single(head_buf)
      return
    end
    load_git_content(
      function(cb) git.show_head(cwd, path, cb) end,
      head_buf,
      "(error loading HEAD content)",
      function() show_single(head_buf) end
    )
    return
  end

  -- From here: side-by-side layouts

  local left_buf, right_buf

  if item.status == "both" and section == "changes" then
    -- MM in Changes: left = staged, right = working file
    local staged_key = ":0:" .. path
    left_buf = get_or_create_scratch(staged_key, path)

    local full_path = cwd .. "/" .. path
    right_buf = vim.fn.bufnr(full_path, true)
    load_for_diff(right_buf)
    pin_buffer(right_buf)

    if not state.has_commits then
      set_buf_content(left_buf, { "(no base commit)" })
      show_side_by_side(left_buf, right_buf)
      return
    end

    load_git_content(
      function(cb) git.show_staged(cwd, path, cb) end,
      left_buf,
      "(error loading staged content)",
      function() show_side_by_side(left_buf, right_buf) end
    )
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

    load_git_content(
      function(cb) git.show_head(cwd, path, cb) end,
      left_buf,
      "(error loading HEAD content)",
      done
    )
    load_git_content(
      function(cb) git.show_staged(cwd, path, cb) end,
      right_buf,
      "(error loading staged content)",
      done
    )
    return
  end

  if section == "staged" then
    -- Staged modified: left = HEAD, right = staged :0:
    -- Bug #2 fix: use orig_path for HEAD key (renamed files have old content at orig_path)
    local old_path = item.orig_path or path
    local head_key = "HEAD:" .. old_path
    local staged_key = ":0:" .. path
    left_buf = get_or_create_scratch(head_key, old_path)
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

    load_git_content(
      function(cb) git.show_head(cwd, old_path, cb) end,
      left_buf,
      "(error loading HEAD content)",
      done
    )
    load_git_content(
      function(cb) git.show_staged(cwd, path, cb) end,
      right_buf,
      "(error loading staged content)",
      done
    )
    return
  end

  -- Default: unstaged modified or renamed
  -- Left = HEAD (or HEAD:old_path for renames), right = working file
  local old_path = item.orig_path or path
  local head_key = "HEAD:" .. old_path
  left_buf = get_or_create_scratch(head_key, old_path)

  local full_path = cwd .. "/" .. path
  right_buf = vim.fn.bufnr(full_path, true)
  load_for_diff(right_buf)
  pin_buffer(right_buf)

  if not state.has_commits then
    set_buf_content(left_buf, { "(no base commit)" })
    show_side_by_side(left_buf, right_buf)
    return
  end

  load_git_content(
    function(cb) git.show_head(cwd, old_path, cb) end,
    left_buf,
    "(error loading HEAD content)",
    function() show_side_by_side(left_buf, right_buf) end
  )
end

-- Refresh diff buffers to pick up external changes.
-- Real file buffers get :checktime (reloads from disk if changed).
-- Git show scratch buffers get their content re-fetched.
-- Called by load_and_render() after sections are rebuilt.
function M.refresh_diff_bufs()
  local bufs = state.diff_bufs or {}
  if #bufs == 0 then return end

  local cwd = state.git_root
  if not cwd then return end

  local pending = 0

  local function on_done()
    pending = pending - 1
    if pending == 0 and state.is_active() then
      vim.cmd("diffupdate")
    end
  end

  for _, buf in ipairs(bufs) do
    if not vim.api.nvim_buf_is_valid(buf) then goto continue end

    local bt = vim.api.nvim_get_option_value("buftype", { buf = buf })
    if bt == "nofile" then
      -- Scratch buffer (git show) — re-fetch content by parsing the buffer name
      local name = vim.api.nvim_buf_get_name(buf)
      local cache_key = name:match("^git%-diff%-viewer://(.+)$")
      if cache_key then
        local git_fn
        local path = cache_key:match("^HEAD:(.+)$")
        if path then
          git_fn = function(cb) git.show_head(cwd, path, cb) end
        else
          path = cache_key:match("^:0:(.+)$")
          if path then
            git_fn = function(cb) git.show_staged(cwd, path, cb) end
          else
            -- Branch ref: "<ref>:<path>" (e.g. "main:src/app.ts")
            local ref, ref_path = cache_key:match("^(.+):(.+)$")
            if ref and ref_path then
              git_fn = function(cb) git.show_ref(cwd, ref, ref_path, cb) end
            end
          end
        end
        if git_fn then
          pending = pending + 1
          load_git_content(git_fn, buf, "(error refreshing)", on_done)
        end
      end
    end
    -- Real file buffers are updated by Neovim's autoread or the IDE bridge.

    ::continue::
  end

  -- If no async loads were needed (e.g. only real file buffers), update now
  if pending == 0 and state.is_active() then
    vim.cmd("diffupdate")
  end
end

return M
