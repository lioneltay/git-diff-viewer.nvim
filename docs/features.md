# git-diff-viewer.nvim — Feature Documentation

## Overview

A Neovim plugin that provides a dedicated tab-based interface for viewing git diffs, staging/unstaging files, and reviewing branch changes. Inspired by VS Code's Source Control panel and diffview.nvim.

## Two Modes

### 1. Status Mode (`:GitDiffViewer`)

Shows the current working tree state — unstaged changes, staged changes, and merge conflicts. Supports staging, unstaging, and discarding changes with optimistic UI updates.

**Trigger:** `:GitDiffViewer` or `<leader>gv` (user keymap)

**Data sources:**
- `git status --porcelain=v1 -z` → file list with XY status codes
- `git diff --numstat -z` → unstaged +/- line counts
- `git diff --cached --numstat -z` → staged +/- line counts

**File sections:**
- **Merge Conflicts** — Files with conflict status codes (UU, AA, DD, AU, UA, DU, UD)
- **Changes** — Unstaged modifications, untracked files, and the unstaged half of "both" (MM) files
- **Staged Changes** — Staged modifications and the staged half of "both" (MM) files

### 2. Branch Mode (`:GitDiffViewerBranch [branch] [base]`)

Shows all changes a branch introduced relative to where it diverged from a base branch. Read-only — no staging/unstaging.

**Trigger:** `:GitDiffViewerBranch` (current HEAD vs main), or `:GitDiffViewerBranch feature/auth main`

**Data sources:**
- `git merge-base <base> <branch>` → common ancestor commit hash
- `git diff --name-status -z <merge-base>..<branch>` → file list with A/M/D/R status
- `git diff --numstat -z <merge-base>..<branch>` → +/- line counts

**File sections:**
- **Changed Files** — Single flat section showing all A/M/D/R files

---

## UI Layout

The viewer opens in a **dedicated Neovim tab** with a fixed-width panel on the left and a diff area on the right.

```
┌──────────────┬─────────────────────────────────────────┐
│              │                                         │
│  File Panel  │         Diff Area (1 or 2 panes)       │
│  (40 cols)   │                                         │
│              │                                         │
│  - Sections  │  Left pane      │  Right pane           │
│  - Folders   │  (base version) │  (new version)        │
│  - Files     │                 │                       │
│              │                                         │
└──────────────┴─────────────────────────────────────────┘
```

**Single-instance:** Only one viewer tab can be open at a time. Opening a different mode closes the existing one first.

---

## File Panel Features

### Tree Rendering
- Files grouped into collapsible **sections** (Merge Conflicts, Changes, Staged Changes)
- Files organized into collapsible **folder trees** based on their directory structure
- Each file shows: status icon, file icon (via mini.icons), filename, +/- counts
- Renamed files show: `old_name → new_name`
- Binary files annotated with `[binary]`, submodules with `[submodule]`
- Currently-open diff file highlighted with `GitDiffViewerFileNameActive`

### Header
- **Status mode:** Shows truncated git root path + "Help: g?"
- **Branch mode:** Shows `branch ← base` + `merge-base: abc1234`

### Section Collapse
- `<CR>` on a section header toggles collapse/expand
- Collapse state persists across re-renders within the same session

### Folder Collapse
- `<CR>` on a folder toggles collapse/expand
- Folders default to expanded
- Collapse state persists across re-renders within the same session

---

## Diff Viewing

### Status Mode Diff Layouts

| File state | Panes | Left | Right |
|---|---|---|---|
| Modified (unstaged `_M`) | Side-by-side | HEAD (read-only) | Working file (editable) |
| Modified (staged `M_`) | Side-by-side | HEAD (read-only) | Staged `:0:` (read-only) |
| MM in Changes | Side-by-side | Staged `:0:` (read-only) | Working file (editable) |
| MM in Staged | Side-by-side | HEAD (read-only) | Staged `:0:` (read-only) |
| New/untracked (`??`) | Single pane | — | Working file (editable) |
| Staged new (`A_`) | Single pane | — | Staged `:0:` (read-only) |
| Deleted (unstaged `_D`) | Single pane | HEAD (read-only) | — |
| Deleted (staged `D_`) | Single pane | HEAD (read-only) | — |
| Renamed | Side-by-side | HEAD:old_path (read-only) | Working file (editable) |
| Binary | Single pane | Message: "Binary file — cannot display diff" | — |
| Submodule | Single pane | Message: "Submodule — diff not supported" | — |
| Merge conflict | Single pane | — | Working file with markers (editable) |
| Empty repo (no commits) | Side-by-side | "(no base commit)" | Working file (editable) |

### Branch Mode Diff Layouts

| File state | Panes | Left | Right |
|---|---|---|---|
| Modified (M) | Side-by-side | `git show merge-base:path` (read-only) | `git show branch:path` (read-only) |
| Added (A) | Single pane | — | `git show branch:path` (read-only) |
| Deleted (D) | Single pane | `git show merge-base:path` (read-only) | — |
| Renamed (R) | Side-by-side | `git show merge-base:orig_path` (read-only) | `git show branch:path` (read-only) |
| Binary | Single pane | Message: "Binary file — cannot display diff" | — |

### Side-by-side Diff Features
- Neovim built-in diff mode (`diff=true`, `scrollbind`, `cursorbind`)
- Fold method set to `diff` with `foldlevel=999` (all folds open)
- Auto-jumps to first change hunk on open (`]c`)
- Synced scrolling between left and right panes

### Buffer Caching
- Git show buffers (HEAD, staged, ref content) are cached by key (e.g. `"HEAD:src/app.ts"`)
- Cache keys include the ref, so different refs don't collide
- Buffers use `bufhidden=hide` so they survive window close
- Cache is cleared on refresh (old buffers wiped, displayed buffers preserved)
- Orphaned buffers (from cache clears) are detected by name and reused

---

## Git Operations (Status Mode Only)

All operations use **optimistic UI** — the panel updates immediately, then the git command runs asynchronously. On failure, the UI rolls back to the pre-operation state.

### Stage (`s`)
- **File in Changes/Conflicts:** `git add -- <path>` → moves to Staged
- **Folder:** Stages all files under the folder path
- **Section header (Changes/Conflicts):** Stages all files in that section

### Unstage (`u`)
- **File in Staged:** `git restore --staged -- <path>` → moves to Changes
- **Folder:** Unstages all files under the folder path
- **Section header (Staged):** Unstages all files

### Discard (`x`)
- **Untracked file:** Prompts for confirmation, then deletes from disk via `os.remove()`
- **Unstaged file:** `git restore -- <path>` → restores working tree from index
- **Staged file:** `git restore --staged -- <path>` then `git restore -- <path>` → unstage + restore
- **Folder:** Discards all tracked unstaged files under the folder path (skips untracked)

### Stage All (`S`)
- `git add -A` → stages everything (changes, untracked, conflicts)

### Unstage All (`U`)
- `git restore --staged .` → unstages everything

### Branch Mode Guards
All 5 mutation functions (`stage_item`, `unstage_item`, `discard_item`, `stage_all`, `unstage_all`) silently return in branch mode.

---

## File Cycling

- `<Tab>` / `<S-Tab>` — Cycle to the next/previous file in panel display order
- Works from both the panel and the diff panes
- Wraps around at the beginning/end of the file list
- Opens the appropriate diff (status or branch) based on current mode

---

## Finder (Fuzzy File Picker)

**Trigger:** `<leader>ff` from panel or diff panes

A floating two-window picker:
- **Top:** Editable input for filtering (starts in insert mode)
- **Bottom:** Read-only tree showing matching files with highlights

**Features:**
- Live filtering as you type (case-insensitive substring match on file paths)
- All folders forced expanded (no collapse in finder)
- Section headers skipped (no section grouping)
- Arrow keys / `<C-j>`/`<C-k>` / `<C-n>`/`<C-p>` to move selection
- `<CR>` to open selected file's diff
- `<Esc>` / `q` / `<C-c>` to close
- `<leader>ff` toggles (closes if already open)
- Mode-aware: shows branch_files in branch mode, status files in status mode

---

## Auto-Refresh

- **BufWritePost:** Refreshes when any file within the git root is saved (debounced 200ms)
- **FocusGained:** Refreshes when Neovim regains focus (debounced 200ms)
- **Manual:** `R` key in the panel

Refresh re-fetches all git data and re-renders the panel. In branch mode, it re-fetches the name-status and numstat.

---

## Keymaps

### Panel Keymaps (configurable via `opts.keymaps`)

| Key | Action | Default |
|---|---|---|
| `<CR>` | Open diff / toggle folder / toggle section | — |
| `s` | Stage file/folder/section | `stage` |
| `u` | Unstage file/folder/section | `unstage` |
| `x` | Discard changes | `discard` |
| `S` | Stage all | `stage_all` |
| `U` | Unstage all | `unstage_all` |
| `R` | Refresh | `refresh` |
| `q` | Close viewer | `close` |
| `gf` | Open file in previous tab | `open_file` |
| `<C-l>` | Focus diff pane (or tmux navigate right) | `focus_diff` |
| `<Tab>` | Next file | `next_file` |
| `<S-Tab>` | Previous file | `prev_file` |
| `<leader>ff` | Open finder | — (hardcoded) |
| `g?` | Show help popup | — (hardcoded) |

### Diff Pane Keymaps (configurable via `opts.diff_keymaps`)

| Key | Action | Default |
|---|---|---|
| `q` | Close viewer | `close` |
| `gf` | Open file in previous tab | `open_file` |
| `<C-h>` | Focus panel | `focus_panel` |
| `<leader>ff` | Open finder | — (hardcoded) |
| `<Tab>` | Next file | — (uses `keymaps.next_file`) |
| `<S-Tab>` | Previous file | — (uses `keymaps.prev_file`) |

### Finder Keymaps (hardcoded)

| Key | Mode | Action |
|---|---|---|
| `<CR>` | i/n | Open selected file |
| `<C-c>` | i | Close |
| `<Esc>` | n | Close |
| `q` | n | Close |
| `<Down>` / `<C-j>` / `<C-n>` | i | Move selection down |
| `<Up>` / `<C-k>` / `<C-p>` | i | Move selection up |
| `<Down>` / `j` | n | Move selection down |
| `<Up>` / `k` | n | Move selection up |
| `<leader>ff` | n | Close (toggle) |

---

## Configuration

```lua
require("git-diff-viewer").setup({
  panel_width = 40,
  keymaps = {
    stage = "s",
    unstage = "u",
    discard = "x",
    stage_all = "S",
    unstage_all = "U",
    refresh = "R",
    close = "q",
    open_file = "gf",
    focus_diff = "<C-l>",
    next_file = "<Tab>",
    prev_file = "<S-Tab>",
    filter = "/",         -- NOTE: not currently wired up
  },
  diff_keymaps = {
    close = "q",
    open_file = "gf",
    focus_panel = "<C-h>",
  },
})
```

---

## Highlight Groups

All linked with `default = true` so user overrides win.

| Group | Default Link | Usage |
|---|---|---|
| `GitDiffViewerSectionHeader` | `Label` | Section header labels |
| `GitDiffViewerSectionCount` | `Identifier` | File count in section headers |
| `GitDiffViewerFileName` | `Normal` | Inactive file names |
| `GitDiffViewerFileNameActive` | `Type` | Currently-viewed file name |
| `GitDiffViewerFolderName` | `Directory` | Folder names |
| `GitDiffViewerFolderIcon` | `NonText` | Chevron icons (▾/▸) |
| `GitDiffViewerStatusM` | `diffChanged` | Modified status icon |
| `GitDiffViewerStatusA` | `diffAdded` | Added status icon |
| `GitDiffViewerStatusD` | `diffRemoved` | Deleted status icon |
| `GitDiffViewerStatusR` | `Type` | Renamed status icon |
| `GitDiffViewerStatusConflict` | `DiagnosticWarn` | Conflict status icon |
| `GitDiffViewerInsertions` | `diffAdded` | +N insertion counts |
| `GitDiffViewerDeletions` | `diffRemoved` | -N deletion counts |
| `GitDiffViewerDim` | `Comment` | Dimmed text (header paths, [binary], etc.) |

---

## Commands

| Command | Args | Description |
|---|---|---|
| `:GitDiffViewer` | none | Open status mode viewer |
| `:GitDiffViewerClose` | none | Close the viewer |
| `:GitDiffViewerBranch` | `[branch] [base]` | Open branch diff mode. Branch defaults to HEAD, base defaults to main |

---

## Known Issues & Gaps (Comprehensive Review)

### Critical Bugs

1. **Concurrent optimistic operations corrupt state on rollback.** `optimistic()` captures `old_files = vim.deepcopy(state.files)` at call time. If user stages file A then immediately stages file B before A's git command completes, B captures A's optimistic state as its baseline. If A fails and rolls back, B's optimistic change is silently lost. Both rollbacks reference wrong snapshots. *File: init.lua, optimistic()*

2. **Staged renames use wrong path for HEAD content.** In `diff.open()`, when a renamed file is in the staged section, the code uses `"HEAD:" .. path` (the new name) for the left pane. But HEAD has the file at the old name (`item.orig_path`). The `git show` fails and shows an error message instead of the old file content. The default branch correctly uses `item.orig_path or path`, but staged items are caught earlier and never reach it. *File: ui/diff.lua, section == "staged" branch*

### High Severity Bugs

3. **Stale `current_diff` reference after staging.** When staging a file, `remove_item` removes it from `state.files.changes` and `panel.render()` rebuilds `panel_lines`, but `state.current_diff` still references the old item object with `section = "changes"`. The panel active highlight is lost, and pressing Enter on the now-staged item uses wrong section logic for diff display. *File: init.lua, stage_item()*

4. **Non-atomic unstage+discard with incomplete rollback.** Discarding a staged file runs `git.unstage` then `git.discard` sequentially. If unstage succeeds but discard fails, the rollback restores `old_files` (showing the file as staged), but git has already unstaged it. The UI and git state diverge. *File: init.lua, discard_item() staged path*

5. **Autocmd accumulation on repeated open/close.** Every `open()` and `open_branch()` call creates new WinNew, TabClosed autocmds. The self-removal check (`if not state.tab then return true end`) fails when a new viewer is opened because `state.tab` points to the new tab, so old autocmds never self-remove. Each open/close cycle adds more stale autocmds. Additionally, switching from `open()` to `open_branch()` (or vice versa) leaves orphaned autocmds from the previous mode. *File: init.lua, open() and open_branch()*

6. **Folder unstage doesn't move items to changes section.** The folder unstage optimistic action calls `remove_item(p, "staged")` for each file, removing them from staged. But unlike the single-file unstage, it never adds items back to `state.files.changes`. Files vanish from the UI entirely until the real git refresh arrives. *File: init.lua, unstage_item() folder path*

7. **Folder stage doesn't move items to staged section.** Same as above but reversed. Folder staging calls `remove_item(p, nil)` (removes from ALL sections) but never inserts into `state.files.staged`. *File: init.lua, stage_item() folder path*

### Medium Severity Bugs

8. **BufWritePost/FocusGained autocmds also accumulate.** Same leak pattern as the WinNew/TabClosed autocmds. Each open/close cycle adds orphaned refresh autocmds. *File: init.lua, open()*

9. **`open_branch()` missing auto-refresh triggers.** Only `open()` creates BufWritePost/FocusGained autocmds. Branch mode has no auto-refresh on file save or focus gain — only manual `R`. *File: init.lua, open_branch()*

10. **Read-only single panes have no keymaps.** `show_single(buf, true)` skips `setup_diff_keymaps`. This means `q`, `gf`, `<Tab>`/`<S-Tab>`, `<leader>ff`, and `<C-h>` don't work when viewing staged new files, deleted files, binary/submodule messages, or branch-mode added/deleted files. *File: ui/diff.lua, show_single()*

11. **Diff keymaps pollute real file buffers.** When displaying unstaged modified files, `setup_diff_keymaps` is called on the actual working file buffer. These keymaps (like `q` to close the viewer) persist after the viewer is closed, causing unexpected behavior when the file is later opened in a normal buffer. *File: ui/diff.lua, setup_diff_keymaps()*

12. **`gf` (open_file) uses `tabprevious` which may navigate to wrong tab.** If the user has rearranged tabs or opened new tabs since opening the viewer, `tabprevious` goes to the wrong tab instead of the original editing tab. *File: ui/panel.lua and ui/diff.lua*

13. **Stale async callbacks overwrite new viewer state.** If `load_and_render()` is in flight when the viewer is closed and reopened, the old callbacks may fire after the new viewer's callbacks, overwriting `state.files` with stale data. There is no generation counter or cancellation token. Works by accident (buffer validity check prevents panel.render from running) rather than by design. *File: init.lua, load_and_render()*

14. **`open_diff_wins` can create windows in wrong tab.** The function never verifies that the current tabpage matches `state.tab`. If the user switches tabs between an async git show call and the `vim.schedule` callback, diff windows are created in the wrong tab. *File: ui/layout.lua, open_diff_wins()*

15. **Panel buffer name collision.** `panel.create_buf()` always names the buffer `"GitDiffViewer"`. If the old panel buffer survives (e.g., displayed in another window), reopening fails with E95. `state.reset()` does not explicitly delete the panel buffer. *File: ui/panel.lua, create_buf()*

16. **Wrong optimistic status for newly added files on unstage.** When unstaging a staged new file (`A_`), the optimistic UI creates an item with `status = "unstaged"` in the changes section. In reality, `git restore --staged` makes it an untracked file (`??`). The UI briefly shows the wrong status icon and diff logic for the item is wrong until refresh. *File: init.lua, unstage_item()*

17. **Empty repo: `git restore --staged` fails.** In a repo with no commits, unstage operations produce `fatal: could not resolve HEAD`. The error message is not user-friendly. *File: init.lua, unstage operations*

18. **`refresh()` clears buf_cache but doesn't re-cache displayed buffers.** After clearing the cache map, displayed buffers survive but lose their cache entry. The orphaned buffer detection in `get_or_create_scratch` finds them, but their content may be stale. *File: init.lua, refresh()*

19. **No guard against opening diff when viewer is already closed.** Async git show callbacks in `diff.open()` and `diff.open_branch()` don't check if the viewer tab still exists before creating windows. *File: ui/diff.lua*

### Low Severity Bugs

20. **Double `state.reset()` on close.** `layout.close()` triggers the TabClosed autocmd which calls `state.reset()`, then `M.close()` calls it again. The second reset is harmless but wasteful. *File: init.lua, close()*

21. **`move_item()` function is defined but never called.** Dead code. *File: init.lua*

22. **Double keymap setup for conflict/untracked.** `setup_diff_keymaps(working_buf)` is called explicitly, then `show_single(working_buf, false)` calls it again. Harmless but wasteful. *File: ui/diff.lua*

23. **`refresh_timer` not cleaned up on close.** The debounce timer may still be pending after close. Guards prevent actual damage, but the timer object persists. *File: init.lua*

24. **Finder tree_buf validity race.** The `vim.schedule` wrapping in the TextChanged autocmd creates a gap between the validity check and the buffer modification in `render_tree`. *File: ui/finder.lua*

25. **`equalalways` not protected by pcall.** If a window operation throws between saving and restoring `vim.o.equalalways`, the global setting is permanently changed. *File: ui/layout.lua*

26. **`path_to_ft` falls back to raw extension.** Unknown extensions like `.xyz` return `"xyz"` as filetype, which could trigger unexpected ftplugin loading. *File: utils.lua*

27. **`discard_item` on folder doesn't prompt for confirmation.** Individual untracked files get a confirmation prompt, but folder-level discard silently discards all tracked files. *File: init.lua*

### Feature Gaps

1. **`filter` keymap (`/`) is configured but never wired up.** Exists in `config.defaults.keymaps` but no code uses `km.filter`. The finder uses `<leader>ff` instead.

2. **No help popup update for branch mode.** The `g?` popup shows stage/unstage/discard keymaps that don't work in branch mode.

3. **No `<Esc>` to close from panel.** Only `q` closes. Many similar plugins support `<Esc>`.

4. **No timeout or feedback for hung git operations.** If `vim.system()` hangs (e.g., git waiting for credentials), the plugin is stuck with no user feedback.

5. **No compact folder rendering.** Single-child folder chains render as nested levels (`a/` → `b/` → `c/`) instead of compacted into one line (`a/b/c/`). VS Code and many tree plugins compact these.

6. **No file watching for external changes.** The viewer only refreshes on `BufWritePost`, `FocusGained`, or manual `R`. Files edited externally (by AI tools, other editors) don't trigger a refresh until the user refocuses Neovim. The `state.watchers` field exists in state.lua but is never used. Could use `vim.uv.new_fs_event()` to watch `.git/index` and the working directory.

---

## Dependencies

- **Required:** Neovim 0.10+ (for `vim.system()`)
- **Optional:** `mini.icons` for file icons in the panel

---

## File Structure

```
lua/git-diff-viewer/
├── init.lua        — Entry point, setup, open/close, refresh, git operations, commands
├── config.lua      — Default config + user overrides
├── state.lua       — Singleton mutable state
├── git.lua         — Async git command wrappers
├── parse.lua       — Git output parsers
├── utils.lua       — Shared helpers (icons, highlights, path utils)
└── ui/
    ├── layout.lua  — Tab/window management
    ├── panel.lua   — File panel rendering + keymaps
    ├── diff.lua    — Diff buffer loading + display
    └── finder.lua  — Floating file picker
```
