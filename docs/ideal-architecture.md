# git-diff-viewer.nvim — Ideal Architecture Proposal

hello

## Design Goals

1. **Eliminate the god module.** init.lua should be a thin orchestrator, not a 735-line catch-all.
2. **Fix the async safety issues.** Generation counters for stale callback rejection. Cancellation for in-flight operations.
3. **Fix autocmd lifecycle.** Single augroup, batch-clear on close.
4. **Fix the optimistic UI race conditions.** Fire-and-forget with eventual consistency via debounced refresh.
5. **Reduce duplication.** Shared open/close lifecycle, helper extraction.
6. **Unify the data model.** Single `state.sections` list for both status and branch mode — no conditional branching.
7. **Make state changes traceable.** Centralize mutations through a small API rather than raw field writes from everywhere.
8. **Keep what works.** The bottom-layer modules (git.lua, parse.lua, config.lua) are well-designed. The tab-based isolation, buffer cache, and fan-out/join patterns are sound.
9. **Preserve navigation context.** Reuse diff windows so Neovim's native jumplist (Ctrl-O/I) works across file navigations.
10. **Provide diff history.** Track viewed diffs and offer a picker (`<leader>fb`) for quick re-access.
11. **Render compact folders.** Collapse single-child folder chains into one line (VS Code-style).
12. **React to external changes.** File watchers detect edits from AI tools, other editors, and git CLI operations.

---

## Proposed Module Structure

```
lua/git-diff-viewer/
├── init.lua            — setup(), open(), close(), refresh(), navigation, autocmds, user commands
├── config.lua          — Default config + user overrides (unchanged)
├── state.lua           — State container + mutation API + generation counter + is_active()
├── git.lua             — Async git command wrappers (unchanged, plus checkout_head)
├── parse.lua           — Git output parsers (unchanged, with helper extraction)
├── utils.lua           — Shared helpers (unchanged)
├── operations.lua      — Git staging operations + optimistic UI (fire-and-forget)
└── ui/
    ├── layout.lua      — Tab/window management (tracks main_win, replaces wincmd l)
    ├── panel.lua       — File panel rendering + keymaps (iterates state.sections directly)
    ├── diff.lua        — Diff buffer loading + display (helper extraction)
    ├── finder.lua      — Floating file picker (iterates state.sections directly)
    └── viewed.lua      — Viewed diffs picker (<leader>fb, flat recency-sorted list)
```

### What Changed

| Change                                 | Where                                            | Purpose                                                                                                                                 |
| -------------------------------------- | ------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------- |
| New `operations.lua`                   | Extracted from init.lua                          | `stage_item`, `unstage_item`, `discard_item`, `stage_all`, `unstage_all`, optimistic helpers (~200 lines)                               |
| Augroup in init.lua                    | Replaces scattered `nvim_create_autocmd` calls   | Single augroup `"GitDiffViewer"`, `clear = true` on setup and teardown. No separate module needed — the fix is the augroup, not a file. |
| `state.sections`                       | Replaces `state.files` + `state.branch_files`    | Unified list of `{ key, label, items }`. Panel/finder iterate directly — no `if mode == "branch"` checks.                               |
| `state.main_win`                       | Tracked from `layout.create_tab()`               | Replaces fragile `wincmd l` navigation in `open_diff_wins`.                                                                             |
| `state.is_active()`                    | New guard function                               | Replaces ad-hoc `state.tab` checks in async callbacks.                                                                                  |
| Fire-and-forget optimistic             | Replaces rollback-based `optimistic()`           | No rollback. No queue. Each operation gets immediate feedback. Debounced refresh syncs with reality.                                    |
| Window reuse in `open_diff_wins`       | Replaces close/recreate on every navigation      | Preserves per-window jumplist (Ctrl-O/I). `win_set_buf` pushes old buffer onto jumplist automatically.                                  |
| Buffer survival on refresh             | Replaces force-delete of cached buffers          | Only clears cache map. Buffers survive with `bufhidden="hide"` for jumplist navigation.                                                 |
| `state.viewed_diffs` + `ui/viewed.lua` | New                                              | Tracks opened diffs by recency. `<leader>fb` picker for re-opening previously viewed files.                                             |
| Compact folder rendering               | Replaces inline folder emission in `build_lines` | Pre-builds tree, compacts single-child chains, renders depth-first.                                                                     |
| File watchers (`vim.uv.new_fs_event`)  | New                                              | Watches `.git/index`, `.git/HEAD`, git root (recursive). Triggers debounced refresh on external changes.                                |

Navigation functions (`next_file`, `prev_file`, `all_file_items`, `open_file_item`, ~60 lines) stay in init.lua — too small for their own module, and diff.lua already deferred-requires init.lua for close/navigation keymaps.

init.lua shrinks from ~735 lines to ~400 lines: `setup`, `open`, `close`, `refresh`, `load_and_render`, navigation, autocmd setup, user commands.

---

## Key Design Changes

Design changes are organized into two groups:

- **1–14: Architectural fixes** — address existing bugs, structural problems, and code quality issues identified in the architecture review.
- **15–19: New features** — add capabilities that don't exist today.

### Architectural Fixes

### 1. Unified Data Model: `state.sections`

Replace the split `state.files` + `state.branch_files` with a single `state.sections` list. This eliminates the `if mode == "branch"` conditional that's currently duplicated in panel.lua and finder.lua, and makes the data model self-describing.

```lua
-- state.lua

-- Unified file sections — always a list of { key, label, items }
-- Status mode: 3 sections (conflicts, changes, staged)
-- Branch mode: 1 section (changes)
M.sections = {}
```

Populated by `load_and_render`:

```lua
-- init.lua (status mode)
local files = parse.build_file_list(entries, unstaged_numstat, staged_numstat)
state.sections = {
  { key = "conflicts", label = "Merge Conflicts", items = files.conflicts },
  { key = "changes",   label = "Changes",         items = files.changes },
  { key = "staged",    label = "Staged Changes",  items = files.staged },
}
panel.render()

-- init.lua (branch mode)
local result = parse.build_branch_file_list(name_status_entries, numstat)
state.sections = {
  { key = "changes", label = "Changed Files", items = result.files },
}
panel.render()
```

Panel and finder iterate `state.sections` directly:

```lua
-- ui/panel.lua build_lines (simplified)
for _, section in ipairs(state.sections) do
  -- render section header using section.label
  -- render items using section.items
  -- each item already has section.key for identification
end
```

Operations access sections by key:

```lua
-- operations.lua
local function get_section(key)
  for _, s in ipairs(state.sections) do
    if s.key == key then return s end
  end
end

local function remove_from_section(path, section_key)
  local section = get_section(section_key)
  if not section then return end
  for i = #section.items, 1, -1 do
    if section.items[i].path == path then
      table.remove(section.items, i)
    end
  end
end
```

**Why this is better:** The current code has `state.files = { conflicts, changes, staged }` (a dictionary) for status mode and `state.branch_files` (a flat list) for branch mode. Every consumer must check `state.mode` and choose the right data source. The unified model makes both modes structurally identical — the only difference is how many sections exist.

### 2. State Generation Counter

Add a monotonically increasing generation counter to state.lua. Every async operation captures the generation at call time. Callbacks compare against the current generation and bail if stale.

```lua
-- state.lua
M.generation = 0

function M.reset()
  M.generation = M.generation + 1  -- increment, don't reset to 0
  -- ... rest of reset ...
end

function M.next_generation()
  M.generation = M.generation + 1
  return M.generation
end
```

Usage in init.lua:

```lua
function M.load_and_render()
  local gen = state.next_generation()
  local cwd = state.git_root
  -- ... fire async commands ...

  local function try_render()
    pending = pending - 1
    if pending > 0 then return end
    if state.generation ~= gen then return end  -- stale, discard
    -- parse and render
  end
end
```

This eliminates the stale-callback problem by design rather than by accident (the current code relies on buffer validity checks).

### 3. Fire-and-Forget Optimistic UI

Replace the current rollback-based `optimistic()` with a simpler fire-and-forget pattern. Each operation:

1. Mutates `state.sections` immediately (optimistic update)
2. Calls `panel.render()` for instant feedback
3. Fires the git command asynchronously
4. On completion (success or failure): a debounced refresh syncs state with reality

No rollback. No operation queue.

```lua
-- operations.lua
local M = {}

local state = require("git-diff-viewer.state")
local git = require("git-diff-viewer.git")
local utils = require("git-diff-viewer.utils")

-- Debounced refresh fires once after a burst of operations settles.
-- Injected by init.lua in open_viewer() to avoid circular dependency:
--   operations.refresh = debounced_refresh
-- If not wired, operations silently skip refresh (nil guard in fire_git).
M.refresh = nil

-- ─── Helpers ──────────────────────────────────────────────────────

local function get_section(key)
  for _, s in ipairs(state.sections) do
    if s.key == key then return s end
  end
end

local function remove_from_section(path, section_key)
  local section = get_section(section_key)
  if not section then return end
  for i = #section.items, 1, -1 do
    if section.items[i].path == path then
      table.remove(section.items, i)
    end
  end
end

local function add_to_section(item, section_key)
  local section = get_section(section_key)
  if not section then return end
  table.insert(section.items, item)
end

-- Fire a git command and trigger refresh on completion.
-- On failure, show error and refresh (which corrects the optimistic state).
local function fire_git(git_fn)
  git_fn(function(ok, stderr)
    vim.schedule(function()
      if not ok then
        utils.error("Git operation failed: " .. (stderr or ""))
      end
      if M.refresh then M.refresh() end
    end)
  end)
end

-- ─── Stage ────────────────────────────────────────────────────────

function M.stage_item(line)
  -- ... stage logic using remove_from_section/add_to_section ...
  -- ... panel.render() for instant feedback ...
  -- ... fire_git(function(cb) git.stage(state.git_root, paths, cb) end) ...
end

-- ─── Unstage ──────────────────────────────────────────────────────

function M.unstage_item(line)
  -- ... similar pattern ...
end

-- ... discard_item, stage_all, unstage_all ...

return M
```

**Why fire-and-forget is better than the operation queue:**

The operation queue (proposed in the previous version of this document) has a fundamental UX flaw: it delays optimistic feedback for queued operations. If the user presses `s` on file A then file B, file B's optimistic update doesn't appear until A's git command completes. The user sees a lag they didn't expect.

Fire-and-forget gives every operation immediate optimistic feedback. The trade-off: if a git command fails, the user sees the item briefly disappear then reappear on refresh, rather than seeing an instant rollback. In practice, git staging/unstaging almost never fails, and the debounced refresh fires within 200ms of the last operation, so the inconsistency window is tiny.

**Why fire-and-forget is better than the current rollback approach:**

The current rollback approach has Critical Bug #1: concurrent operations corrupt each other's rollback snapshots because each captures `deepcopy(state.files)` independently. Fire-and-forget has no rollback, so there's nothing to corrupt.

### 4. Augroup-Based Autocmd Management

All autocmds use a single augroup. Setup creates them; teardown clears the group.

```lua
-- init.lua
local AUGROUP = "GitDiffViewer"

local function setup_autocmds()
  vim.api.nvim_create_augroup(AUGROUP, { clear = true })

  -- WinNew: strip diff mode from floating windows
  vim.api.nvim_create_autocmd("WinNew", {
    group = AUGROUP,
    callback = function()
      -- Guard: only act when viewer is active and on the viewer tab
      if not state.is_active() then return end
      if vim.api.nvim_get_current_tabpage() ~= state.tab then return end
      local win = vim.api.nvim_get_current_win()
      local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
      if ok and cfg.relative and cfg.relative ~= "" then
        pcall(function()
          vim.wo[win].diff = false
          vim.wo[win].scrollbind = false
          vim.wo[win].cursorbind = false
        end)
      end
    end,
  })

  -- TabClosed: detect viewer tab closed externally
  vim.api.nvim_create_autocmd("TabClosed", {
    group = AUGROUP,
    callback = function()
      if not state.tab then return end
      for _, t in ipairs(vim.api.nvim_list_tabpages()) do
        if t == state.tab then return end
      end
      state.reset()
    end,
  })

  -- Auto-refresh on file save (within git root)
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = AUGROUP,
    callback = function(ev)
      if not state.is_active() then return end
      local file = ev.file or ""
      if file ~= "" and vim.startswith(file, state.git_root) then
        debounced_refresh()
      end
    end,
  })

  -- Auto-refresh on focus gain
  vim.api.nvim_create_autocmd("FocusGained", {
    group = AUGROUP,
    callback = function()
      if not state.is_active() then return end
      debounced_refresh()
    end,
  })
end

local function teardown_autocmds()
  vim.api.nvim_create_augroup(AUGROUP, { clear = true })
end
```

**Why not a separate `autocmds.lua`:** An earlier version of this document proposed extracting autocmds into their own module with callback indirection (`callbacks.on_tab_closed`, `callbacks.on_refresh`, etc.). This adds complexity without reducing it — the callbacks are defined in init.lua and passed to autocmds.lua, which just registers them. The actual fix is the augroup pattern (single group, clear on setup/teardown), not the file structure. Keeping autocmds in init.lua is simpler and the callback bodies can directly reference `debounced_refresh`, `state.reset()`, etc. without indirection.

### 5. Simplified Open Lifecycle

Drop the redundant `is_git_repo` check (get_root already fails for non-git repos). Extract the shared setup into `open_viewer()`.

```lua
-- init.lua

local function open_viewer(mode, on_ready)
  -- Close existing viewer if open
  if state.tab then M.close() end

  local cwd = vim.fn.getcwd()

  git.get_root(cwd, function(ok, root)
    vim.schedule(function()
      if not ok then
        utils.error("Not inside a git repository")
        return
      end

      state.reset()
      state.mode = mode
      state.git_root = root

      -- Create UI — main_win is now tracked in state
      layout.create_tab()
      local buf = panel.create_buf()
      layout.set_panel_buf(buf)

      -- Focus panel
      if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
        vim.api.nvim_set_current_win(state.panel_win)
      end

      -- Setup autocmds (idempotent via augroup clear)
      setup_autocmds()

      -- Wire operations module to use our debounced refresh
      local operations = require("git-diff-viewer.operations")
      operations.refresh = debounced_refresh

      -- Mode-specific setup
      on_ready(root)
    end)
  end)
end

function M.open()
  -- If already in status mode, just focus the existing tab
  if state.mode == "status" and layout.focus() then return end

  open_viewer("status", function(root)
    git.has_commits(root, function(has)
      vim.schedule(function()
        state.has_commits = has
        M.load_and_render()
      end)
    end)
  end)
end

function M.open_branch(branch, base)
  open_viewer("branch", function(root)
    state.branch_name = branch or "HEAD"
    state.base_name = base or "main"
    state.has_commits = true  -- merge-base implies commits exist

    git.merge_base(root, state.base_name, state.branch_name, function(ok, hash)
      vim.schedule(function()
        if not ok then
          utils.error("Could not find merge-base between '" .. state.base_name .. "' and '" .. state.branch_name .. "'")
          M.close()
          return
        end
        state.merge_base = hash
        M.load_and_render_branch()
      end)
    end)
  end)
end
```

**Changes from current code:**

- `is_git_repo` removed — `get_root` already fails for non-git dirs, eliminating one async nesting level (3 → 2 in `open()`, 4 → 3 in `open_branch()`)
- Shared repo detection, state reset, UI creation, and autocmd setup live in `open_viewer()`
- Eliminates ~120 lines of duplicated setup code

### 6. Track `state.main_win`

Store the main (diff area) window handle from `create_tab()` instead of finding it via `wincmd l`.

```lua
-- state.lua additions
M.main_win = nil  -- main diff area window (right of panel)

-- layout.lua changes
function M.create_tab()
  vim.cmd("tabnew")
  state.tab = vim.api.nvim_get_current_tabpage()
  local main_win = vim.api.nvim_get_current_win()
  -- ... create panel ...
  state.panel_win = panel_win
  state.main_win = main_win  -- NEW: track the main window
  -- ...
end

-- layout.lua: open_diff_wins uses state.main_win directly
function M.open_diff_wins(count)
  local ea = vim.o.equalalways
  vim.o.equalalways = false

  -- Close existing diff windows
  for _, w in ipairs(state.diff_wins) do
    if vim.api.nvim_win_is_valid(w) and w ~= state.panel_win then
      pcall(vim.api.nvim_set_option_value, "diff", false, { win = w })
      vim.api.nvim_win_close(w, true)
    end
  end
  state.diff_wins = {}
  state.diff_bufs = {}

  -- Navigate to the main area using the tracked window handle
  local target_win = nil
  if state.main_win and vim.api.nvim_win_is_valid(state.main_win) then
    target_win = state.main_win
  else
    -- Fallback: main_win was closed, create a new split
    vim.api.nvim_set_current_win(state.panel_win)
    vim.cmd("vsplit")
    target_win = vim.api.nvim_get_current_win()
    state.main_win = target_win
  end

  vim.api.nvim_set_current_win(target_win)
  local wins = { target_win }

  if count == 2 then
    vim.cmd("vsplit")
    table.insert(wins, vim.api.nvim_get_current_win())
    vim.api.nvim_set_current_win(wins[1])
  end

  state.diff_wins = wins
  -- Re-enforce panel width and restore equalalways
  if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
    vim.api.nvim_win_set_width(state.panel_win, config.options.panel_width)
  end
  vim.o.equalalways = ea
  return wins
end
```

**Why:** The current code uses `wincmd l` (line 126 of layout.lua) to find the main area. This is fragile — if the window layout is different from expected, `wincmd l` might navigate to the wrong window or stay in the panel. Tracking `state.main_win` is deterministic.

### 7. `state.is_active()` Guard

A centralized guard function replaces ad-hoc `state.tab` checks scattered across callbacks.

```lua
-- state.lua
function M.is_active()
  return M.tab ~= nil
    and vim.api.nvim_tabpage_is_valid(M.tab)
end
```

Used in autocmd callbacks, async completions, and operations:

```lua
-- Before: scattered in every callback
if not state.tab then return true end

-- After: single guard
if not state.is_active() then return end
```

### 8. State Mutation API

Small mutation helpers for commonly-accessed state. Not full encapsulation — just enough to centralize the tricky parts.

```lua
-- state.lua additions

-- Set the current diff, clearing the old one
function M.set_current_diff(item, section_key)
  M.current_diff = item and { item = item, section = section_key } or nil
end

-- After refresh: reconcile current_diff against new section data.
-- The old item object is stale (from the previous state.sections).
-- Find the matching item in the new sections by path+section, or clear if gone.
-- Matching on both path AND section is important for MM files, which appear
-- in both "changes" and "staged" sections — path-only matching would silently
-- switch which version is displayed.
function M.reconcile_current_diff()
  if not M.current_diff then return end
  local path = M.current_diff.item.path
  local section_key = M.current_diff.section

  -- First try: match path + same section (exact match)
  for _, section in ipairs(M.sections) do
    if section.key == section_key then
      for _, item in ipairs(section.items) do
        if item.path == path then
          M.current_diff = { item = item, section = section.key }
          return
        end
      end
    end
  end

  -- Fallback: file moved sections (e.g., staged → changes after unstage)
  for _, section in ipairs(M.sections) do
    for _, item in ipairs(section.items) do
      if item.path == path then
        M.current_diff = { item = item, section = section.key }
        return
      end
    end
  end

  -- Item no longer exists in any section
  M.current_diff = nil
end

-- After refresh: reconcile viewed_diffs against new section data.
-- Same staleness problem as current_diff — item objects reference old sections.
-- Update each entry to point at the current item, or remove if the file is gone.
function M.reconcile_viewed_diffs()
  local new_list = {}
  for _, vd in ipairs(M.viewed_diffs) do
    local found = false
    for _, section in ipairs(M.sections) do
      for _, item in ipairs(section.items) do
        if item.path == vd.path then
          table.insert(new_list, item)
          found = true
          break
        end
      end
      if found then break end
    end
    -- If the file is no longer in any section, drop it from the list
  end
  M.viewed_diffs = new_list
end
```

Both `reconcile_current_diff()` and `reconcile_viewed_diffs()` are called at the end of `try_render()` in both `load_and_render` and `load_and_render_branch`, after writing `state.sections` and before `panel.render()`. This fixes Bug #3 (stale current_diff after staging/refresh) and prevents the viewed diffs picker from showing stale item references.

### 9. Diff Helper Extraction

Extract the repeated content-to-buffer pattern:

```lua
-- ui/diff.lua (new helper)

-- Load git content into a scratch buffer, splitting lines and trimming trailing newline
local function load_git_content(buf, content)
  local lines = vim.split(content, "\n", { plain = true })
  if lines[#lines] == "" then table.remove(lines) end
  set_buf_content(buf, lines)
end
```

This replaces 12 instances of the same 3-line pattern in diff.lua.

### 10. Always Set Up Navigation Keymaps on Diff Panes

The `show_single` function should always call `setup_diff_keymaps` regardless of the `readonly` parameter. The keymaps it sets (q, gf, C-h, Tab, S-Tab, leader-ff) are navigation keymaps, not edit keymaps.

```lua
local function show_single(buf, readonly)
  local wins = layout.open_diff_wins(1)
  local win = wins[1]
  vim.api.nvim_win_set_buf(win, buf)
  state.diff_bufs = { buf }
  if readonly then
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  end
  setup_diff_keymaps(buf)  -- ALWAYS set up navigation keymaps
  refocus_panel()
end
```

**Bug #22 interaction:** The current code calls `setup_diff_keymaps(working_buf)` explicitly before `show_single(working_buf, false)` in conflict and untracked file paths. With this change, `show_single` always calls it too, creating a double call. The fix is to **remove the explicit calls** at the callsites — `show_single` handles it uniformly. This also fixes Bug #22 (double keymap setup).

### 11. Buffer-Local Keymap Cleanup

When setting diff keymaps on a working file buffer (not a scratch buffer), register a BufWinLeave autocmd to clean up keymaps when the buffer leaves the diff window. This prevents `q`, `gf`, etc. from persisting into normal editing.

```lua
local DIFF_KEYMAP_LHS = {}  -- populated from config at setup time

local function setup_diff_keymaps(buf)
  -- ... set keymaps as before ...

  -- Track which keys we set, for cleanup
  -- (includes dk.close, dk.open_file, dk.focus_panel, "<leader>ff", km.next_file, km.prev_file)

  -- If this is a real file buffer (not a scratch), register cleanup
  if vim.api.nvim_get_option_value("buftype", { buf = buf }) == "" then
    vim.api.nvim_create_autocmd("BufWinLeave", {
      group = "GitDiffViewer",  -- uses the plugin augroup, auto-cleared on close
      buffer = buf,
      callback = function()
        -- Only strip keymaps if the buffer is leaving a diff window.
        -- Without this check, closing the same file in a normal split (different tab)
        -- would strip keymaps while the file is still displayed in the diff viewer.
        local leaving_win = tonumber(vim.fn.expand("<afile>")) or vim.api.nvim_get_current_win()
        local is_diff_win = false
        for _, w in ipairs(state.diff_wins or {}) do
          if w == leaving_win then is_diff_win = true; break end
        end
        if not is_diff_win then return end

        for _, lhs in ipairs(DIFF_KEYMAP_LHS) do
          pcall(vim.api.nvim_buf_del_keymap, buf, "n", lhs)
        end
      end,
    })
  end
end
```

Using the plugin augroup (`"GitDiffViewer"`) ensures these autocmds are cleaned up on viewer close even if BufWinLeave doesn't fire. The autocmd does NOT use `once = true` — we want it to fire every time the buffer leaves a diff window (it gets re-registered each time the buffer is displayed in a diff).

### 12. Tab Guard on Async Callbacks

All async callbacks that manipulate windows should verify the viewer tab is still active and current:

```lua
-- ui/diff.lua
local function on_content_ready(...)
  if not state.is_active() then return end
  -- ... proceed with show_single / show_side_by_side ...
end
```

And in `layout.open_diff_wins`, switch to the viewer tab before creating windows:

```lua
function M.open_diff_wins(count)
  if state.tab and vim.api.nvim_get_current_tabpage() ~= state.tab then
    vim.api.nvim_set_current_tabpage(state.tab)
  end
  -- ... rest of function ...
end
```

### 13. Error Propagation in load_and_render

Both `load_and_render` and `load_and_render_branch` currently ignore the `ok` parameter in their git callbacks. Fix both:

```lua
-- init.lua: load_and_render
local errors = {}

git.status(cwd, function(ok, raw)
  vim.schedule(function()
    if not ok then
      table.insert(errors, "git status failed")
    else
      status_raw = raw
    end
    try_render()
  end)
end)

-- In try_render:
local function try_render()
  pending = pending - 1
  if pending > 0 then return end
  if state.generation ~= gen then return end
  if #errors > 0 then
    utils.error(table.concat(errors, "; "))
    return  -- don't render with partial/empty data
  end
  -- parse and render
end
```

Same pattern for `load_and_render_branch`.

### 14. Atomic Discard for Staged Files

Replace the non-atomic unstage-then-discard sequence with `git checkout HEAD -- <path>`, which atomically restores both the index and working tree from HEAD in a single command.

```lua
-- git.lua: new function
function M.checkout_head(cwd, paths, callback)
  local args = { "git", "checkout", "HEAD", "--" }
  for _, p in ipairs(paths) do
    table.insert(args, p)
  end
  run(args, { cwd = cwd }, function(ok, _, stderr)
    callback(ok, stderr)
  end)
end
```

```lua
-- operations.lua: discard_item for staged files
if item.section == "staged" then
  -- Atomically restore index and working tree from HEAD
  remove_from_section(item.path, "staged")
  panel.render()
  fire_git(function(cb)
    git.checkout_head(state.git_root, { item.path }, cb)
  end)
  return
end
```

**Why:** The current two-step approach (`git restore --staged` then `git restore`) has Bug #4: if unstage succeeds but discard fails, the UI and git state diverge. `git checkout HEAD --` is atomic — it either restores both or neither.

**Edge case:** `git checkout HEAD -- <path>` fails for staged new files (A\_) because the file doesn't exist in HEAD. For new files, discard should use `git rm --cached <path>` to unstage, then `os.remove()` to delete from disk (same as untracked file discard). Note: this new-file path is inherently non-atomic (two operations), but it's the only correct approach since the file doesn't exist in HEAD. If `git rm --cached` succeeds but `os.remove()` fails (file locked/permissions), the file remains on disk as untracked — a safe degradation that the next refresh will show correctly.

### New Features

### 15. Diff Window Reuse (Ctrl-O / Ctrl-I)

The current `layout.open_diff_wins()` closes and recreates diff windows on every file navigation. This destroys the per-window jumplist, making native Ctrl-O/I useless.

**Fix:** Reuse existing diff windows when the layout (pane count) matches. When `vim.api.nvim_win_set_buf(win, new_buf)` is called on an existing window, Neovim automatically pushes the old buffer+position onto that window's jumplist. Ctrl-O/I then works natively — including preserving cursor position within each file.

```lua
-- layout.lua: revised open_diff_wins
function M.open_diff_wins(count)
  -- Collect valid existing diff windows
  local valid = {}
  for _, w in ipairs(state.diff_wins) do
    if vim.api.nvim_win_is_valid(w) and w ~= state.panel_win then
      table.insert(valid, w)
    end
  end

  if #valid == count then
    -- Same layout — reuse windows. The caller swaps buffers via
    -- win_set_buf, which pushes old buffer onto the window's jumplist.
    -- Disable diff mode on reused windows so it can be re-enabled
    -- cleanly by the caller (avoids stale diff state).
    for _, w in ipairs(valid) do
      pcall(vim.api.nvim_set_option_value, "diff", false, { win = w })
      pcall(vim.api.nvim_set_option_value, "scrollbind", false, { win = w })
      pcall(vim.api.nvim_set_option_value, "cursorbind", false, { win = w })
    end
    state.diff_wins = valid
    state.diff_bufs = {}
    -- Re-enforce panel width (equalalways may have shifted it)
    if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
      vim.api.nvim_win_set_width(state.panel_win, config.options.panel_width)
    end
    return valid
  end

  -- Layout mismatch — need to adjust
  local ea = vim.o.equalalways
  vim.o.equalalways = false

  if #valid > count then
    -- Too many windows (e.g. 2-pane → 1-pane): close extras, keep first
    for i = count + 1, #valid do
      pcall(vim.api.nvim_set_option_value, "diff", false, { win = valid[i] })
      vim.api.nvim_win_close(valid[i], true)
    end
    local wins = { unpack(valid, 1, count) }
    for _, w in ipairs(wins) do
      pcall(vim.api.nvim_set_option_value, "diff", false, { win = w })
      pcall(vim.api.nvim_set_option_value, "scrollbind", false, { win = w })
      pcall(vim.api.nvim_set_option_value, "cursorbind", false, { win = w })
    end
    state.diff_wins = wins
    state.diff_bufs = {}
    if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
      vim.api.nvim_win_set_width(state.panel_win, config.options.panel_width)
    end
    vim.o.equalalways = ea
    return wins
  end

  -- Too few windows (e.g. 0 → 1, 0 → 2, 1 → 2): create more
  -- Close any stale windows first
  for _, w in ipairs(valid) do
    pcall(vim.api.nvim_set_option_value, "diff", false, { win = w })
  end

  -- Start from the main window (or create one if needed)
  local first_win
  if #valid >= 1 then
    first_win = valid[1]
    -- Clear diff options on the reused window
    pcall(vim.api.nvim_set_option_value, "scrollbind", false, { win = first_win })
    pcall(vim.api.nvim_set_option_value, "cursorbind", false, { win = first_win })
  elseif state.main_win and vim.api.nvim_win_is_valid(state.main_win) then
    first_win = state.main_win
  else
    vim.api.nvim_set_current_win(state.panel_win)
    vim.cmd("vsplit")
    first_win = vim.api.nvim_get_current_win()
    state.main_win = first_win
  end

  vim.api.nvim_set_current_win(first_win)
  local wins = { first_win }

  if count == 2 then
    -- Close any extra windows beyond the first before splitting
    for i = 2, #valid do
      vim.api.nvim_win_close(valid[i], true)
    end
    vim.cmd("vsplit")
    table.insert(wins, vim.api.nvim_get_current_win())
    vim.api.nvim_set_current_win(wins[1])
  end

  state.diff_wins = wins
  state.diff_bufs = {}
  if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
    vim.api.nvim_win_set_width(state.panel_win, config.options.panel_width)
  end
  vim.o.equalalways = ea
  return wins
end
```

**How it works in practice:**

1. User opens file A (modified, side-by-side) — 2 diff windows created, buffers set
2. User opens file B (modified, side-by-side) — same 2 windows reused, `win_set_buf` pushes A's buffers onto the jumplist
3. User presses Ctrl-O in the right diff pane — goes back to file A's right-side content at the exact cursor position
4. User presses Ctrl-I — goes forward to file B again

**Layout transitions** (e.g., modified file → deleted file = 2-pane → 1-pane): the extra window is closed, which loses its jumplist. The surviving window's jumplist is preserved. These transitions are uncommon in practice — most navigation is between files with the same layout.

**Buffers must survive for jumplist to work.** If a buffer is deleted, Neovim skips it in the jumplist. See Design Change #16.

**Mode transitions reset jumplist.** Switching between status and branch mode closes the tab (destroying all windows and their jumplists) and opens a new one. This is acceptable — mode transitions are infrequent, and the `viewed_diffs` list (Design Change #17) provides a separate history that survives mode transitions.

### 16. Stop Deleting Buffers on Refresh

The current `refresh()` force-deletes all non-displayed cached buffers (`nvim_buf_delete force = true`) and clears `state.buf_cache = {}`. This destroys buffer handles that the jumplist references.

**Fix:** Only clear the cache map. Don't delete the buffer objects.

```lua
function M.refresh()
  if not state.git_root then return end
  -- Clear the cache map so next diff.open() re-fetches content via git show.
  -- DON'T delete the buffer objects — they survive with bufhidden="hide"
  -- and get_or_create_scratch finds them by name (orphan detection).
  -- Content is overwritten when the buffer is next displayed in a diff.
  state.buf_cache = {}

  if state.mode == "branch" then
    M.load_and_render_branch()
  else
    M.load_and_render()
  end
end
```

Buffers accumulate over the session but are all cleaned up on close (`state.reset()` still force-deletes everything). For a typical session, this is a few dozen scratch buffers at most — negligible memory.

**Jumplist content freshness:** When the user presses Ctrl-O, Neovim shows the buffer's current content (which may be stale if the file was edited since it was last displayed). This is acceptable — the content was correct when the user last viewed it, and pressing Enter on the file in the panel re-fetches fresh content. For the "always up to date" goal, the file watcher feature (Design Change #19) triggers refreshes that update displayed buffers in real time.

### 17. Viewed Diffs Picker (`<leader>fb`)

A floating picker showing files the user has already opened diffs for, sorted by recency (most recent first). Flat list — no folder tree. Allows re-opening, removing entries, and filtering by name.

**State:**

```lua
-- state.lua
M.viewed_diffs = {}  -- ordered list of file items, most recent first
```

Pushed when a diff is opened (Enter, Tab/S-Tab, finder). If the item is already in the list, move it to the front instead of duplicating.

```lua
-- Called from diff.open / diff.open_branch / open_file_item
local function track_viewed_diff(item)
  -- Remove if already present (will re-insert at front)
  for i = #state.viewed_diffs, 1, -1 do
    if state.viewed_diffs[i].path == item.path then
      table.remove(state.viewed_diffs, i)
    end
  end
  table.insert(state.viewed_diffs, 1, item)
end
```

**Picker UI:** Reuses the same two-window float pattern as `finder.lua` (input window + list window). The list renders each entry as a flat line:

```
  M  src/app.ts                  Changes
  A  src/utils/auth.ts           Staged
  M  README.md                   Changes
```

Each line shows: status icon, file path (with icon if mini.icons available), section/label. The currently-open diff is highlighted.

**Keymaps:**

| Key                        | Mode          | Action                          |
| -------------------------- | ------------- | ------------------------------- |
| `<CR>`                     | insert/normal | Open selected file's diff       |
| `<C-d>`                    | insert/normal | Remove selected entry from list |
| `<Esc>`, `q`               | normal        | Close picker                    |
| `<C-c>`                    | insert        | Close picker                    |
| `<Down>`, `<C-j>`, `<C-n>` | insert        | Move selection down             |
| `<Up>`, `<C-k>`, `<C-p>`   | insert        | Move selection up               |
| `j`, `k`                   | normal        | Move selection up/down          |
| Type text                  | insert        | Filter entries by file path     |

`<C-d>` follows the telescope convention for removing a buffer from a list. It removes the entry from `state.viewed_diffs` and re-renders the list in place. The underlying scratch buffer is not deleted — it stays alive for jumplist navigation and can be re-opened by viewing the file again from the panel.

**Trigger:** `<leader>fb` on both the panel and diff panes (mnemonic: "find buffer" / "find viewed"). This parallels `<leader>ff` ("find file") for the all-files finder.

**Implementation:** A new `ui/viewed.lua` module. The rendering is simpler than finder — no tree building, just a flat filtered list. Most of the window creation, keymap setup, and lifecycle code can be shared with finder via extracted helpers or direct reuse.

**Staleness after refresh:** When `state.sections` is replaced during refresh, all item objects in `state.viewed_diffs` become stale references. The `state.reconcile_viewed_diffs()` function (Design Change #8) handles this — called in `try_render()` alongside `reconcile_current_diff()`. Items for files that no longer exist in any section are dropped from the list.

### 18. Compact Folder Rendering

Merge single-child folder chains into one line, like VS Code's "compact folders". Instead of:

```
▾ src/
  ▾ components/
    ▾ shared/
      M  Button.tsx
```

Render as:

```
▾ src/components/shared/
  M  Button.tsx
```

But when a folder has multiple children, keep it separate:

```
▾ src/
  ▾ components/
    M  App.tsx
  ▾ utils/
    M  helper.ts
```

**Where:** `build_lines` in panel.lua (and finder.lua, which reuses `build_lines`).

**Algorithm:** The current code iterates files and emits folder nodes inline (panel.lua:144-186). For compact folders, pre-build a tree from the section's file list, then compact single-child chains before rendering.

```lua
-- Pre-processing step in build_lines, per section:

-- Step 1: Build tree from file paths
-- tree = { children = { "src" = { children = { "components" = { ... } }, files = {} } } }
local function build_tree(items)
  local root = { children = {}, files = {} }
  for _, item in ipairs(items) do
    local parts = utils.split_path(item.path)
    local node = root
    for _, dir in ipairs(parts.dirs) do
      if not node.children[dir] then
        node.children[dir] = { children = {}, files = {}, name = dir }
      end
      node = node.children[dir]
    end
    table.insert(node.files, item)
  end
  return root
end

-- Step 2: Compact single-child chains
-- If a folder has exactly 1 child folder and 0 files, merge them.
-- IMPORTANT: Collect mutations and apply after iteration to avoid
-- modifying `node.children` during `pairs()` traversal (undefined in Lua).
local function compact_tree(node)
  -- Recurse into all children first (bottom-up compaction)
  for _, child in pairs(node.children) do
    compact_tree(child)
  end

  -- Collect merge operations
  local merges = {}
  for name, child in pairs(node.children) do
    local child_folder_count = 0
    local child_folder_name, child_folder_node
    for cn, cv in pairs(child.children) do
      child_folder_count = child_folder_count + 1
      child_folder_name = cn
      child_folder_node = cv
    end

    if child_folder_count == 1 and #child.files == 0 then
      table.insert(merges, {
        old_name = name,
        new_name = name .. "/" .. child_folder_name,
        node = child_folder_node,
      })
    end
  end

  -- Apply merges after iteration
  for _, m in ipairs(merges) do
    node.children[m.old_name] = nil
    m.node.name = m.new_name
    node.children[m.new_name] = m.node
  end
end

-- Step 3: Render the compacted tree (depth-first, sorted)
local function render_tree(node, depth)
  local sorted_dirs = {}
  for name, _ in pairs(node.children) do
    table.insert(sorted_dirs, name)
  end
  table.sort(sorted_dirs)

  for _, dir_name in ipairs(sorted_dirs) do
    local child = node.children[dir_name]
    local folder_path = -- compute from parent path + dir_name
    local is_expanded = force_expanded or state.folder_expanded[folder_path] ~= false

    -- Emit folder line: indent + chevron + dir_name + "/"
    -- ...

    if is_expanded then
      render_tree(child, depth + 1)  -- recurse into subfolders
      -- Emit file lines for child.files
    end
  end
end
```

**Expand/collapse state:** The `state.folder_expanded` key for a compact folder is the full path (e.g., `"src/components/shared"`). Toggling it collapses/expands the entire merged chain as one unit. This works naturally because the merged folder is a single node in the tree.

**Interaction with filtering (finder):** When a filter is active (`opts.filter`), compacting should still apply. The tree is built from filtered items, so chains that only appear compact because unmatched siblings were filtered out will correctly compact.

### 19. File Watching for External Changes

Keep diffs up to date when files are edited externally (by AI tools, other editors, etc.) using libuv file system watchers via `vim.uv`.

**What to watch:**

| Target             | Catches                                                   | API                                         |
| ------------------ | --------------------------------------------------------- | ------------------------------------------- |
| `.git/index`       | Staging/unstaging from any tool (git CLI, lazygit, AI)    | `vim.uv.new_fs_event()`                     |
| `.git/HEAD`        | Branch switches                                           | `vim.uv.new_fs_event()`                     |
| Git root directory | Working tree file edits (recursive on macOS via FSEvents) | `vim.uv.new_fs_event({ recursive = true })` |

**Implementation:**

```lua
-- init.lua (inside open_viewer, after state setup)

local function setup_watchers()
  teardown_watchers()  -- clean up any existing watchers

  local git_dir = state.git_root .. "/.git"

  -- Watch .git/index — fires on any staging/unstaging
  local index_w = vim.uv.new_fs_event()
  if index_w then
    index_w:start(git_dir .. "/index", {}, function(err)
      if err then return end
      vim.schedule(function()
        if state.is_active() then debounced_refresh() end
      end)
    end)
    table.insert(state.watchers, index_w)
  end

  -- Watch .git/HEAD — fires on branch switch
  local head_w = vim.uv.new_fs_event()
  if head_w then
    head_w:start(git_dir .. "/HEAD", {}, function(err)
      if err then return end
      vim.schedule(function()
        if state.is_active() then debounced_refresh() end
      end)
    end)
    table.insert(state.watchers, head_w)
  end

  -- Watch working directory for external file edits
  -- recursive = true works on macOS (FSEvents) and Windows (ReadDirectoryChangesW)
  -- On Linux, inotify only watches the top-level directory — a fallback timer handles the rest
  local dir_w = vim.uv.new_fs_event()
  if dir_w then
    dir_w:start(state.git_root, { recursive = true }, function(err, filename)
      if err then return end
      -- Skip .git/ internal changes (already covered by index/HEAD watchers)
      if filename and vim.startswith(filename, ".git") then return end
      vim.schedule(function()
        if state.is_active() then debounced_refresh() end
      end)
    end)
    table.insert(state.watchers, dir_w)
  end
end

local function teardown_watchers()
  for _, w in ipairs(state.watchers) do
    pcall(function()
      w:stop()
      if not w:is_closing() then w:close() end
    end)
  end
  state.watchers = {}
end
```

**Debouncing is critical.** File watchers fire frequently — saving a file can trigger multiple events. The existing `debounced_refresh` (200ms delay) handles this. For bursts of changes (e.g., AI writing multiple files), the debounce ensures only one refresh runs after the burst settles.

**Throttle `vim.schedule` calls.** The libuv callback fires on every file event — an npm install or git checkout touching hundreds of files would call `vim.schedule(debounced_refresh)` hundreds of times. Add a flag to skip redundant schedules:

```lua
local refresh_scheduled = false

local function schedule_refresh()
  if refresh_scheduled then return end
  refresh_scheduled = true
  vim.schedule(function()
    refresh_scheduled = false
    if state.is_active() then debounced_refresh() end
  end)
end
```

All three watchers call `schedule_refresh()` instead of `vim.schedule(...)` directly.

**Linux fallback:** `recursive = true` doesn't work with inotify. Options:

1. Accept that on Linux, only `.git/index` and `.git/HEAD` watching works reliably. External file edits are caught on `FocusGained` or manual `R`.
2. Add an optional poll timer as fallback: `vim.uv.new_timer()` every 2-5 seconds calls `debounced_refresh()`. Controlled by a config option to avoid unnecessary git calls.

The `.git/index` watcher alone covers most AI-tool workflows, since many AI tools use `git add` or `git apply` which modify the index.

**Lifecycle:** `setup_watchers()` is called in `open_viewer()` after state is initialized. `teardown_watchers()` is called in `close()` before `state.reset()`. The `state.watchers` field already exists in state.lua.

---

## Proposed Dependency Graph

```
                     ┌──────────────────────────┐
                     │        init.lua           │
                     │   (thin orchestrator)     │
                     └──┬──┬──┬──┬──┬──────────┘
                        │  │  │  │  │
         ┌──────────────┘  │  │  │  └───────────┐
         │     ┌───────────┘  │  └───────┐      │
         v     v              v          v      v
     ┌──────┐┌──────┐    ┌──────┐   ┌─────────┐
     │ git  ││layout│    │panel │   │operations│
     └──────┘└──────┘    └──────┘   └─────────┘
                              │
     ┌──────┐┌─────┐    ┌────┼───────┐
     │config││parse│    │    │       │
     └──────┘└─────┘    v    v       v
                     ┌──────┐┌─────┐┌──────┐
                     │finder││diff ││viewed│
                     └──────┘└─────┘└──────┘

  All modules import: state, config, utils (not shown for clarity)
  init.lua also uses: vim.uv (file watchers)

  Deferred require() calls (cycle-breaking, in keymap callbacks only):
    panel  ··> operations  (s/u/x/S/U keymap callbacks)
    panel  ··> diff        (<CR> keymap callback)
    panel  ··> finder      (<leader>ff keymap callback)
    panel  ··> viewed      (<leader>fb keymap callback)
    diff   ··> init        (q close, Tab/S-Tab navigation keymap callbacks)
    diff   ··> finder      (<leader>ff keymap callback)
    diff   ··> viewed      (<leader>fb keymap callback)
```

### Key Differences from Current

**Architectural:**

1. **init.lua is thinner** (~400 lines vs ~735) — lifecycle management, navigation, autocmds, commands only.
2. **operations.lua owns all git mutations** — stage, unstage, discard, stage_all, unstage_all. Fire-and-forget with debounced refresh.
3. **Unified `state.sections`** — no `state.files` / `state.branch_files` split. Panel and finder iterate one list.
4. **`state.main_win` tracked** — replaces `wincmd l` in `open_diff_wins`.
5. **Single augroup** — all autocmds in one group, cleared on setup and teardown. No accumulation.
6. **Fewer deferred requires** — `panel ··> init` becomes `panel ··> operations` (more specific dependency).
7. **Generation counter** — stale async callbacks rejected by design, not by accident.

**New capabilities:** 8. **Diff windows reused** — `open_diff_wins` reuses existing windows when pane count matches, preserving Neovim's per-window jumplist for Ctrl-O/I navigation. 9. **Buffers survive refresh** — cached scratch buffers are not deleted on refresh, only the cache map is cleared. Buffers survive for jumplist and are reused via orphan detection. 10. **Viewed diffs picker** (`<leader>fb`) — recency-sorted flat list of previously viewed files with search, open, and remove. 11. **Compact folder rendering** — single-child folder chains collapsed into one line (e.g., `src/components/shared/`). 12. **File watchers** — `.git/index`, `.git/HEAD`, and git root watched via `vim.uv.new_fs_event()` for real-time external change detection.

---

## Migration Strategy

This refactor can be done incrementally without breaking the plugin at any step. Phases 1–7 are architectural fixes (bug fixes and structural improvements). Phases 8–11 are new features that build on the refactored architecture. The two groups form a natural checkpoint — Phases 1–7 can ship independently, with Phases 8–11 following as a second pass.

### Phase 1: Augroup + autocmd consolidation

Create the `"GitDiffViewer"` augroup. Move all autocmd creation into a single `setup_autocmds()` function. Add `teardown_autocmds()` to `close()`. Add BufWritePost/FocusGained to `open_branch()` (currently missing). Test open/close cycling doesn't leak autocmds.

### Phase 2: Add generation counter + error propagation

Add `state.generation`, `state.next_generation()`. Wire into `load_and_render` and `load_and_render_branch`. Check `ok` parameter in all git callbacks — show error and bail instead of rendering with empty data. Test rapid close/reopen doesn't show stale data.

### Phase 3: Unified data model

Replace `state.files` + `state.branch_files` with `state.sections`. Update `load_and_render`, `load_and_render_branch`, panel.lua `build_lines`, and finder.lua to use the new structure. Update all operations that reference `state.files.changes` etc. to use the `get_section()` helper. Test both status and branch modes render correctly.

### Phase 4: Track `state.main_win` + add `state.is_active()`

Store `main_win` from `create_tab()`. Replace `wincmd l` in `open_diff_wins` with direct window handle. Add `state.is_active()` guard and use it in autocmd callbacks and async completions. Test diff window creation works correctly, including after the main window is accidentally closed.

### Phase 5: Unify open lifecycle

Extract `open_viewer()` helper. Drop `is_git_repo` check (use `get_root` error handling). Deduplicate `open()` and `open_branch()`. Test both modes still open correctly, including error cases (not a git repo, no merge-base found).

### Phase 6: Extract operations.lua + fire-and-forget

Move staging operations to `operations.lua`. Replace `optimistic()` + rollback with fire-and-forget + debounced refresh. Delete dead `move_item()` and `remove_item()` functions from init.lua (replaced by section helpers in operations.lua). Wire `operations.refresh` to `debounced_refresh`. Test staging/unstaging still works, including rapid multi-file staging.

### Phase 7: Bug fixes and cleanup

**diff.lua fixes:**

- Always call `setup_diff_keymaps` in `show_single` (regardless of readonly) — Bug #10
- Remove explicit `setup_diff_keymaps` calls before `show_single` in conflict/untracked paths — Bug #22
- Add BufWinLeave cleanup for diff keymaps on working file buffers — Bug #11
- Fix staged rename path (use `orig_path` for HEAD key) — Bug #2
- Add tab guard to async diff callbacks — Bug #14, #19
- Extract `load_git_content` helper — 12 instances → 1

**operations fixes:**

- Fix folder stage/unstage to move items to target section (not just remove) — Bug #6, #7
- Use `git checkout HEAD --` for atomic discard of staged files — Bug #4
- Fix optimistic status for `A_` unstage: should become untracked `??` — Bug #16
- Handle empty repo unstage gracefully: check `state.has_commits` before `git restore --staged`, use `git rm --cached` instead — Bug #17
- Add confirmation prompt for folder-level discard of tracked files — Bug #27

**state/lifecycle fixes** (note: reconcile functions depend on Phase 3's `state.sections`)**:**

- Update `state.current_diff` after mutations via `reconcile_current_diff()` — Bug #3
- Update `state.viewed_diffs` after refresh via `reconcile_viewed_diffs()`
- Explicitly delete old panel buffer in `state.reset()` or `panel.create_buf()` to prevent E95 name collision — Bug #15
- Preserve displayed buffer cache entries on refresh: don't clear entries for buffers in `state.diff_bufs` — Bug #18

**layout/UI fixes:**

- Protect `equalalways` restoration with pcall — Bug #25
- Fix `gf` (open_file) to track the originating tab instead of using `tabprevious` — Bug #12

**finder.lua fixes:**

- Guard `tree_buf` validity in TextChanged autocmd closer to the modification point — Bug #24

**utils.lua fixes:**

- Improve `path_to_ft` fallback for unknown extensions (return empty string instead of raw extension) — Bug #26

### Phase 8: Diff window reuse + Ctrl-O/I

Modify `layout.open_diff_wins` to reuse existing windows when the pane count matches (Design Change #15). Only close/create windows on layout transitions (side-by-side ↔ single-pane). Stop deleting buffers on refresh — clear cache map only (Design Change #16). Test: open file A (side-by-side), open file B (side-by-side), press Ctrl-O in the right diff pane → goes back to file A at the exact cursor position. Press Ctrl-I → back to file B.

### Phase 9: Viewed diffs picker

Add `state.viewed_diffs` list and `reconcile_viewed_diffs()` (called in `try_render()`). Add `track_viewed_diff()` call to `diff.open` / `diff.open_branch` / `open_file_item`. Implement the `<leader>fb` picker in new `ui/viewed.lua` — flat filtered list, `<CR>` to open, `<C-d>` to remove, same window pattern as existing finder. Add `<leader>fb` keymap to panel and diff panes. Test: open 3 files, press `<leader>fb`, see all 3 sorted by recency, filter by name, remove one with `<C-d>`, open another with `<CR>`. Also test: open a diff, save the file, verify the viewed list entry updates after refresh (reconciliation).

### Phase 10: File watching

Implement `setup_watchers()` and `teardown_watchers()` using `vim.uv.new_fs_event()`. Watch `.git/index`, `.git/HEAD`, and the git root directory (recursive where supported). Wire to `debounced_refresh`. Call setup in `open_viewer()`, teardown in `close()`. Test: edit a file from another terminal while the viewer is open — panel should update within ~200ms on macOS.

### Phase 11: Compact folder rendering

Refactor `build_lines` in panel.lua to pre-build a tree, compact single-child chains, then render. Update `state.folder_expanded` keys to use the compacted path. Verify finder.lua (which reuses `build_lines`) also renders compact folders. Test: a path like `src/components/shared/Button.tsx` renders as `src/components/shared/` → `Button.tsx` when no siblings exist at intermediate levels.

**Bugs fixed implicitly by earlier phases (no Phase 7 work needed):**

- Bug #1 (concurrent optimistic corruption) — Phase 6: fire-and-forget eliminates rollback
- Bug #5, #8 (autocmd accumulation) — Phase 1: augroup with clear
- Bug #9 (branch mode missing auto-refresh) — Phase 1 + Phase 5: shared `setup_autocmds` covers both modes
- Bug #13 (stale async callbacks) — Phase 2: generation counter
- Bug #20 (double reset on close) — Phase 1: augroup teardown before state.reset()
- Bug #21 (dead move_item) — Phase 6: deleted during operations extraction
- Bug #23 (refresh_timer not cleaned up) — Phase 1: proper close lifecycle

---

## What NOT to Change

Some things that are fine as-is and don't need redesign:

- **git.lua** — Clean, pure I/O. Only addition: `checkout_head()` for atomic discard.
- **parse.lua** — Pure functions. Only change: extract the NUL-split helper.
- **config.lua** — Minimal. No changes needed.
- **utils.lua** — Helpers are fine. `setup_highlights` could move but doesn't need to.
- **ui/finder.lua** — Self-contained. Only change: iterate `state.sections` instead of conditional.
- **Tab-based isolation pattern** — Correct architectural choice.
- **Buffer cache pattern** — Sound approach. Only fix: preserve cache entries for displayed buffers on refresh.
- **Singleton state pattern** — Appropriate for a single-instance Neovim plugin. Adding a thin mutation API is sufficient; full encapsulation would be overengineering.
- **Fan-out/join async pattern** — Simple and correct. The pending counter + try_render approach works well for parallel git commands.

---

## Consolidated State Schema

All state additions from the design changes, assembled in one place. This is what `state.lua` looks like after all phases:

```lua
local M = {}

-- ─── Existing (unchanged) ────────────────────────────────────
M.mode = nil             -- "status" | "branch" | nil
M.git_root = nil         -- string
M.tab = nil              -- tabpage handle
M.panel_win = nil        -- window handle
M.panel_buf = nil        -- buffer handle
M.diff_wins = {}         -- list of diff window handles
M.diff_bufs = {}         -- list of diff buffer handles
M.buf_cache = {}         -- { [cache_key] = buf_handle }
M.current_diff = nil     -- { item, section } | nil
M.has_commits = false    -- whether the repo has any commits
M.branch_name = nil      -- branch mode: target branch
M.base_name = nil        -- branch mode: base branch
M.merge_base = nil       -- branch mode: merge-base hash
M.folder_expanded = {}   -- { [folder_path] = bool }
M.section_collapsed = {} -- { [section_key] = bool }
M.watchers = {}          -- list of uv_fs_event_t handles

-- ─── New: unified data model (Design Change #1) ─────────────
M.sections = {}          -- list of { key, label, items }

-- ─── New: generation counter (Design Change #2) ─────────────
M.generation = 0         -- monotonically increasing, never reset to 0

function M.next_generation()
  M.generation = M.generation + 1
  return M.generation
end

-- ─── New: window tracking (Design Change #6) ────────────────
M.main_win = nil         -- main diff area window (right of panel)

-- ─── New: guard function (Design Change #7) ─────────────────
function M.is_active()
  return M.tab ~= nil and vim.api.nvim_tabpage_is_valid(M.tab)
end

-- ─── New: mutation API (Design Change #8) ────────────────────
function M.set_current_diff(item, section_key) ... end
function M.reconcile_current_diff() ... end   -- path+section matching
function M.reconcile_viewed_diffs() ... end    -- drop items no longer in sections

-- ─── New: viewed diffs (Design Change #17) ───────────────────
M.viewed_diffs = {}      -- ordered list of items, most recent first

-- ─── reset() ─────────────────────────────────────────────────
function M.reset()
  M.generation = M.generation + 1  -- invalidate in-flight callbacks
  -- ... reset all fields, force-delete all buffers, stop watchers ...
end

return M
```

---

## Deferred Items

Feature gaps from features.md that are **not addressed** by this proposal. These are low-priority and can be picked up in a follow-up pass:

1. **`filter` keymap (`/`) is configured but never wired up** (Feature Gap #1) — The `/` key exists in config defaults but no code uses `km.filter`. The `<leader>ff` finder serves the same purpose. Either wire `/` to open the finder, or remove it from config defaults.
2. **No help popup update for branch mode** (Feature Gap #2) — The `g?` popup shows stage/unstage/discard keymaps that don't exist in branch mode. Should show branch-specific keymaps only.
3. **No `<Esc>` to close from panel** (Feature Gap #3) — Only `q` closes. Many similar plugins support `<Esc>`.
4. **No timeout or feedback for hung git operations** (Feature Gap #4) — If `vim.system()` hangs (e.g., git waiting for credentials), the plugin is stuck with no user feedback. Relevant given that file watchers (Design Change #19) may trigger frequent git calls.

---

## Design Decisions Record

Alternatives that were considered and rejected:

| Decision                               | Alternative                               | Why Rejected                                                                                                                                                                                             |
| -------------------------------------- | ----------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------- |
| Fire-and-forget optimistic             | Operation queue                           | Queue delays optimistic feedback for queued ops — worse UX. Queue also adds complexity (run_next, drain detection).                                                                                      |
| Fire-and-forget optimistic             | Rollback (current approach)               | Concurrent rollbacks corrupt each other (Bug #1). Correct rollback requires serialization, which has the queue's UX problem.                                                                             |
| Augroup in init.lua                    | Separate autocmds.lua                     | Callback indirection adds complexity without reducing it. The fix is the augroup, not the file.                                                                                                          |
| Navigation in init.lua                 | Separate navigation.lua                   | ~60 lines. Too small for its own module. diff.lua already deferred-requires init.lua for close keymaps.                                                                                                  |
| `state.sections` list                  | `state.files` dict (current)              | Dict requires `if mode == "branch"` in every consumer. List is self-describing and uniform.                                                                                                              |
| `state.main_win` tracking              | `wincmd l` (current)                      | `wincmd l` is fragile — depends on window layout being exactly panel                                                                                                                                     | main. Direct handle is deterministic. |
| `git checkout HEAD --`                 | unstage then discard (current)            | Two-step is non-atomic. If step 1 succeeds and step 2 fails, UI and git state diverge (Bug #4).                                                                                                          |
| Drop `is_git_repo`                     | Keep it (current)                         | Redundant with `get_root`. Adds an extra async nesting level for no benefit.                                                                                                                             |
| Window reuse (native jumplist)         | Custom diff history                       | Custom history requires new state (`diff_history`, `diff_history_pos`), reimplements what Neovim does natively, and doesn't preserve cursor position within files. Window reuse gives Ctrl-O/I for free. |
| Window reuse (native jumplist)         | Close/recreate windows (current)          | Destroys per-window jumplist. No Ctrl-O/I. Window reuse also avoids the overhead of closing and creating windows on every navigation.                                                                    |
| Viewed diffs picker (unlisted buffers) | Listed buffers in tabline (VS Code style) | Listed diff buffers pollute buffer list, confuse buffer management plugins, and require lifecycle management. Unlisted buffers with a dedicated picker gives discoverability without pollution.          |
| Compact folder tree pre-build          | Inline compaction during render           | Inline compaction would require complex lookahead. Pre-building the tree separates concerns: tree construction → compaction → rendering.                                                                 |
