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
- **Compact folders:** Single-child folder chains are collapsed into one line (e.g., `src/components/shared/` instead of nested `src/` → `components/` → `shared/`)
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
- Buffers use `bufhidden=hide` so they survive window close for jumplist navigation
- Cache is cleared on refresh, but displayed buffer entries are preserved
- Orphaned buffers (from cache clears) are detected by name and reused

### Window Reuse
- Diff windows are reused when the pane count matches (avoids creating/destroying windows)
- Layout transitions (2→1, 1→2) are handled smoothly
- Enables native Neovim jumplist navigation (Ctrl-O/Ctrl-I) between previously viewed diffs

---

## Git Operations (Status Mode Only)

All operations use a **fire-and-forget** pattern — the git command runs asynchronously, and a debounced refresh updates the panel when the command completes. This avoids the stale-snapshot bugs of optimistic rollback.

### Stage (`s`)
- **File in Changes/Conflicts:** `git add -- <path>` → moves to Staged
- **Folder:** Stages all files under the folder path
- **Section header (Changes/Conflicts):** Stages all files in that section

### Unstage (`u`)
- **File in Staged:** `git restore --staged -- <path>` → moves to Changes
- **Empty repo:** Uses `git rm --cached -- <path>` (no HEAD to restore from)
- **Folder:** Unstages all files under the folder path
- **Section header (Staged):** Unstages all files

### Discard (`x`)
- **Untracked file:** Prompts for confirmation, then deletes from disk via `os.remove()`
- **Unstaged file:** `git restore -- <path>` → restores working tree from index
- **Staged file:** `git checkout HEAD -- <path>` → atomic unstage + restore in one step
- **Folder:** Prompts for confirmation, then discards all tracked files under the folder path

### Stage All (`S`)
- `git add -A` → stages everything (changes, untracked, conflicts)

### Unstage All (`U`)
- `git restore --staged .` → unstages everything

---

## File Cycling

- `<Tab>` / `<S-Tab>` — Cycle to the next/previous file in panel display order
- Works from both the panel and the diff panes
- Wraps around at the beginning/end of the file list
- Opens the appropriate diff (status or branch) based on current mode

---

## Viewed Diffs Picker

**Trigger:** `<leader>fb` from panel or diff panes

A floating window showing recently viewed diffs (most recent first). Selecting an entry re-opens that diff.

**Features:**
- Tracks diffs as they are opened (most recent first)
- Shows status icon, file path, and section label (`[staged]`, `[conflict]`)
- Stale entries (resolved files) are automatically pruned on refresh
- `<CR>` to open selected diff
- `<Esc>` / `q` / `<leader>fb` to close

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
- **File watching:** Watches `.git/index` and `.git/HEAD` via `vim.uv.new_fs_event()` to detect external changes (staging from CLI, commits from other tools, branch switches)
- **Manual:** `R` key in the panel

Refresh re-fetches all git data and re-renders the panel. A generation counter discards stale async callbacks from earlier refresh cycles.

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
| `<leader>fb` | Open viewed diffs picker | — (hardcoded) |
| `g?` | Show help popup | — (hardcoded) |

### Diff Pane Keymaps (configurable via `opts.diff_keymaps`)

| Key | Action | Default |
|---|---|---|
| `q` | Close viewer | `close` |
| `gf` | Open file in previous tab | `open_file` |
| `<C-h>` | Focus panel | `focus_panel` |
| `<leader>ff` | Open finder | — (hardcoded) |
| `<leader>fb` | Open viewed diffs picker | — (hardcoded) |
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

## Resolved Issues

All 27 previously documented bugs have been fixed. Key fixes:

- **Async safety:** Generation counter rejects stale callbacks; `state.is_active()` guards all async paths
- **Autocmd lifecycle:** Single `"GitDiffViewer"` augroup with batch-clear on close
- **Operations:** Fire-and-forget pattern replaces fragile optimistic rollback; atomic `git checkout HEAD --` for staged discard
- **Diff keymaps:** Always applied (including read-only panes); tracked and cleaned up on viewer close
- **Data model:** Unified `state.sections` replaces conditional `state.files`/`state.branch_files`
- **Window tracking:** `state.main_win` replaces fragile `wincmd l`; `state.origin_tab` for correct `gf` navigation
- **Empty repo:** Uses `git rm --cached` for unstage when HEAD doesn't exist
- **Folder operations:** Stage/unstage properly moves items between sections; discard prompts for confirmation

### Remaining Feature Gaps

1. **`filter` keymap (`/`) is configured but never wired up.** The finder uses `<leader>ff` instead.
2. **No help popup update for branch mode.** The `g?` popup shows stage/unstage/discard keymaps that don't work in branch mode.
3. **No `<Esc>` to close from panel.** Only `q` closes.
4. **No timeout or feedback for hung git operations.** If `vim.system()` hangs, the plugin is stuck with no user feedback.

---

## Dependencies

- **Required:** Neovim 0.10+ (for `vim.system()`)
- **Optional:** `mini.icons` for file icons in the panel

---

## File Structure

```
lua/git-diff-viewer/
├── init.lua            — Entry point: setup, open/close, refresh, navigation, autocmds, file watchers
├── config.lua          — Default config + user overrides
├── state.lua           — Singleton mutable state + generation counter + is_active()
├── git.lua             — Async git command wrappers
├── parse.lua           — Git output parsers
├── utils.lua           — Shared helpers (icons, highlights, path utils)
├── operations.lua      — Stage/unstage/discard with fire-and-forget pattern
└── ui/
    ├── layout.lua      — Tab/window management with window reuse
    ├── panel.lua       — File panel rendering (tree → compact → render) + keymaps
    ├── diff.lua        — Diff buffer loading + display + keymap lifecycle
    ├── finder.lua      — Floating fuzzy file picker
    └── viewed.lua      — Viewed diffs history picker
```
