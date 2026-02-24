# git-diff-viewer.nvim — Plugin Plan

## Vision

A fast, simple Neovim diff viewer focused on **reading diffs in real buffers** with basic git operations. Replicates VS Code's git diff UX with vim-first keyboard navigation.

**Core principle**: View diffs, send context to AI, do basic staging/discarding. Everything else (commits, rebasing, branch management) belongs in lazygit.

---

## Why not diffview.nvim?

| Problem | Our solution |
|---|---|
| Staging is slow (git lock contention, full refresh) | Optimistic UI + async git + partial refresh |
| New files show empty left pane | Single pane for additions/deletions |
| No folder-level discard | Support folder stage/unstage/discard |
| Keybind conflicts with LazyVim | Clean defaults that don't conflict |
| Overloaded with features (merge tool, rebase, file history) | Focused scope — just diffs |

---

## Features

### Phase 1 — Core Viewer

**File Panel (left side)**

Three sections, matching VS Code:

1. **Merge Conflicts** — files whose porcelain status code contains `U` in either position, or `AA`/`DD`. Shown at top. These files do NOT appear in Changes or Staged Changes.
2. **Changes** — files with unstaged modifications (non-blank Y character in porcelain code)
3. **Staged Changes** — files with staged modifications (non-blank X character in porcelain code)

Note: A file with status `MM` (staged AND unstaged changes) appears in **both** sections simultaneously — in Changes showing the diff between working file and staged version, and in Staged Changes showing the diff between staged version and HEAD.

Each file shows:
- Status icon: `M` modified, `A` added, `D` deleted, `R` renamed, `?` untracked, `!` conflict
- For renames: shown as `old_name.ts → new_name.ts` on a single line
- Added/removed line counts: `+12 -3`. For untracked files, counts are derived from the file itself (all lines = additions, no deletions).
- Tree view with collapsible folders — the only view
- Empty state: when no git changes exist, show "No changes" message

Navigation:
- `j`/`k` — move up/down
- `gg`/`G` — jump to top/bottom
- `Enter` on a file — open its diff (cursor auto-jumps to first change hunk)
- `Enter` on a folder — toggle expand/collapse (expanded state tracked in state table, no vim folds)
- `/` — opens a filter prompt at the bottom (buffer-local, does not conflict with vim's `/` search in the panel). Clears on `Escape`. Persists while navigating until cleared.
- Cursor stays at the same line number after staging/unstaging — lands on whatever is now there

**Diff View (right side)**

The diff view opens as a vim split to the right of the file panel. This means `Ctrl-h`/`Ctrl-l` (vim-tmux-navigator) naturally moves focus between them.

| File state | Layout |
|---|---|
| Modified (unstaged) | Side-by-side: left = `git show HEAD:path` (read-only), right = working file (editable) |
| Modified (staged) | Side-by-side: left = `git show HEAD:path` (read-only), right = `git show :0:path` (read-only) |
| MM (staged + unstaged) in Changes | Side-by-side: left = `git show :0:path` (staged, read-only), right = working file (editable) |
| MM (staged + unstaged) in Staged | Side-by-side: left = `git show HEAD:path` (read-only), right = `git show :0:path` (read-only) |
| New/untracked | Single pane: right only, working file (editable) |
| Staged new (A_) | Single pane: right only, `git show :0:path` (read-only) |
| Deleted (unstaged) | Single pane: left only, `git show HEAD:path` (read-only) |
| Deleted (staged) | Single pane: left only, `git show HEAD:path` (read-only) |
| Renamed | Side-by-side: left = `git show HEAD:old_path` (read-only), right = working file (editable) |
| Binary | Message pane: "Binary file — cannot display diff" |
| Merge conflict | Single pane: working file with raw conflict markers (editable — resolve directly) |
| Empty repo (no commits) | Single pane: right only for any file, with note "No base commit" |

All diff buffers:
- Right pane of unstaged modified/new/renamed files is the actual working file — editable, LSP works, AI can read/edit
- Read-only buffers are scratch buffers named `git-diff-viewer://HEAD:src/app.ts` (preserves extension for filetype detection)
- Filetype set via `vim.bo.filetype = ext` (extension parsed from path) — more reliable than `filetype detect` on scratch buffers
- Neovim's built-in diff mode (`vim.wo.diff = true`) on both panes for line and word-level highlighting
- `scrollbind` + `cursorbind` on both panes — synchronized scrolling is free from Neovim's diff mode
- `]c`/`[c` are Neovim's built-in diff mode hunk navigation — they just work when diff mode is on
- Cursor auto-jumps to first change hunk when a diff opens (using `vim.cmd("normal! ]c")` after loading)
- When a staged file's diff is open and you unstage it, the diff updates in place
- Single instance: tab handle stored in state. If viewer is already open when `<leader>gv` is pressed, focus it instead of opening a new one.

**Error handling / edge cases:**
- Not in a git repo: check via `git rev-parse --is-inside-work-tree` on open. Show error notification and abort.
- Empty repo (no commits): `git show HEAD:path` will fail. Detect by checking `git rev-parse HEAD` exit code. Fall back to single-pane view for all files.
- Submodules: will appear as modified entries. `git show HEAD:path` on a submodule ref returns commit SHA, not file content. Detect (submodule entries have mode `160000` in `git ls-files`) and show "Submodule — diff not supported".

---

### Phase 2 — Git Operations

**Operations per file type:**

| File type | `s` stage | `u` unstage | `x` discard |
|---|---|---|---|
| Unstaged modified | stages it | no-op | `git restore -- path` |
| Staged modified (only in Staged) | no-op | unstages it | `git restore --staged -- path` then `git restore -- path` |
| MM — from Changes section | stages it (removes from Changes) | no-op | `git restore -- path` |
| MM — from Staged section | no-op | unstages it (may reappear in Changes) | `git restore --staged -- path` |
| Untracked `??` | stages it | no-op | delete file from disk with confirmation |
| Staged new `A_` | no-op | unstages it (returns to untracked) | `git restore --staged -- path` (file stays on disk) |
| Staged deleted `D_` | no-op | unstages it (file reappears) | no-op (nothing to discard) |
| Unstaged deleted `_D` | stages deletion | no-op | `git restore -- path` (recovers file) |
| Conflict | stages it (marks resolved) | no-op | — |

**Folder-level operations**
- `s`/`u`/`x` on a folder node applies to all files in that folder, respecting per-type rules above
- `S` — stage all files across all sections (`git add -A`) — no confirmation
- `U` — unstage all files (`git restore --staged .`) — no confirmation

**Optimistic UI**
- Immediately re-render the tree with the file in its new section
- Cursor stays at the same line number
- Git command runs async via `vim.system()` with `on_exit` callback
- Callback uses `vim.schedule()` to safely call Neovim API from the libuv thread
- On failure: roll back the UI and show a notification via `vim.notify()`

---

### Phase 3 — Polish

**Performance**
- Show file panel immediately on open (run `git status --porcelain=v1 -z` first)
- Load diff content on demand when `Enter` is pressed — not upfront for all files
- Cache loaded `git show` buffers — reuse the same buffer if reopened
- Watch `.git/index` and `.git/HEAD` with `vim.uv.new_fs_event()` for external changes
- Debounce index/HEAD change events by 100ms

**Visual**
- File panel width configurable (default 40 columns)
- Plugin-specific highlight groups that fall back to Neovim's standard diff groups:
  `GitDiffViewerAdd` → `DiffAdd`, `GitDiffViewerDelete` → `DiffDelete`, etc.
- Status line shows change summary: `~3 +1 -2 !1` (modified/added/deleted/conflicts)

**Extra navigation**
- `R` — manual refresh (re-runs git status)
- `<Tab>`/`<S-Tab>` — cycle to next/previous file, open its diff

**Integration**
- gitsigns.nvim hunk staging works as-is inside editable diff buffers

---

## Git Commands Reference

| Purpose | Command |
|---|---|
| Check if in git repo | `git rev-parse --is-inside-work-tree` |
| Check if repo has commits | `git rev-parse HEAD` (non-zero = no commits) |
| Build file list | `git status --porcelain=v1 -z` |
| Unstaged +/- counts | `git diff --numstat` |
| Staged +/- counts | `git diff --cached --numstat` |
| Load HEAD version | `git show HEAD:<path>` |
| Load staged version | `git show :0:<path>` |
| Detect binary | Use `git diff --numstat` output: binary files show `-\t-\t<path>` instead of numbers |
| Detect submodule | `git ls-files --stage -- <path>` (mode `160000` = submodule) |
| Stage | `git add -- <paths>` |
| Unstage | `git restore --staged -- <paths>` |
| Discard tracked | `git restore -- <paths>` |
| Stage all | `git add -A` |
| Unstage all | `git restore --staged .` |

All git commands: set env `GIT_OPTIONAL_LOCKS=0` to reduce lock contention with other tools.

**Porcelain v1 -z format:**
- Each entry is `XY <path><NUL>` where XY is two-char status (X = staged, Y = unstaged)
- Renames add an extra NUL-separated field: `R_ <new_path><NUL><old_path><NUL>`
- Common codes: `??` untracked, `_M` modified unstaged, `M_` modified staged, `MM` both, `A_` added staged, `_D` deleted unstaged, `D_` deleted staged
- Conflict codes: any code where X or Y is `U`, plus `AA`, `DD`

---

## What We Learned from diffview.nvim

Patterns adopted:
- `git status --porcelain=v1 -z` for file list (NUL-terminated handles spaces in filenames)
- Parallel `git diff --numstat` calls for +/- counts (binary files show `-\t-` which doubles as binary detection)
- `git show HEAD:path` for old content, `git show :0:path` for staged content
- `vim.wo.diff = true`, `scrollbind`, `cursorbind` for synchronized viewing
- `]c`/`[c` are already Neovim's built-in diff navigation — use them as-is

Complexity intentionally skipped:
- 4-pane merge conflict view — show raw markers, resolve manually
- File history / git log browser
- Rebase/cherry-pick/revert flows
- Complex async/coroutine system — `vim.system()` with `on_exit` + `vim.schedule()` is sufficient

---

## Non-Goals

Use lazygit for these:
- Commit UI
- Branch management
- Full 3-way merge conflict resolution tool
- Rebase tooling
- File history / git log
- Blame view
- Stash management
- Remote operations (push/pull)
- Git submodules (shown but not fully supported)

---

## Architecture

```
lua/git-diff-viewer/
  init.lua      -- Entry point: setup(), open(), close(), single-instance check
  config.lua    -- User config with defaults (panel width, keybinds, etc.)
  git.lua       -- Git commands via vim.system() with on_exit + vim.schedule()
  parse.lua     -- Parse porcelain v1 -z output; parse numstat; detect binary/submodule/rename
  state.lua     -- Plugin state: file list, folder expand state, current diff, tab handle
  ui/
    panel.lua   -- Render tree, buffer-local keymaps, cursor management, filter prompt
    diff.lua    -- Load git show buffers, set filetypes, enable diff mode, jump to first hunk
    layout.lua  -- Tab management, split creation, single-instance focus
  utils.lua     -- Path helpers, notifications, extension extraction for filetype
```

**Key design decisions:**
- `vim.system(cmd, opts, on_exit)` for async git — callback fires on libuv thread, use `vim.schedule()` to call Neovim APIs
- `git status --porcelain=v1 -z` as single source of truth for file state
- Binary detection via `git diff --numstat` `-\t-` output — no extra command needed
- Filetype set via `vim.bo.filetype = utils.ext_to_ft(path)` — reliable on scratch buffers
- Neovim's built-in diff mode for highlighting — no custom diff algorithm
- File panel is a scratch buffer, fully re-rendered from state on each change
- State is a plain Lua table — no OOP, easy to debug
- All keymaps are buffer-local to avoid polluting global namespace

---

## Keybind Summary

### File Panel

| Key | Action |
|---|---|
| `j`/`k` | Navigate up/down |
| `gg`/`G` | Jump to top/bottom |
| `/` | Filter files (buffer-local prompt) |
| `Enter` (file) | Open diff, jump to first hunk |
| `Enter` (folder) | Toggle expand/collapse |
| `s` | Stage file/folder |
| `u` | Unstage file/folder |
| `x` | Discard file/folder (confirm for untracked) |
| `S` | Stage all |
| `U` | Unstage all |
| `q` | Close viewer |
| `gf` | Open working file in previous tab |
| `R` | Refresh |
| `Tab`/`S-Tab` | Next/previous file (opens diff) |
| `Ctrl-l` | Move focus to diff pane |

### Diff Pane

| Key | Action |
|---|---|
| `]c`/`[c` | Next/previous hunk (Neovim built-in diff navigation) |
| `q` | Close viewer |
| `gf` | Open working file in previous tab |
| `Ctrl-h` | Move focus to file panel |
| All vim motions | Work normally (search, yank, edit if editable) |

---

## Development Steps

Each step is a working, usable increment.

1. **Scaffold** ✅ — Plugin loads, hotkey opens a tab
2. **Git layer** — `git.lua` async pattern (`vim.system` + `on_exit` + `vim.schedule`); `parse.lua` for porcelain v1 -z; git repo/empty-repo checks
3. **File panel** — Render tree with three sections, status icons, +/- counts, renames as `old → new`, empty state
4. **Diff display** — Load buffers via `git show`, set filetypes, enable diff mode, scrollbind, jump to first hunk
5. **Special cases** — New files, staged new, deleted, binary (via numstat), empty repo fallback, submodule detection
6. **Rename support** — Parse rename entries from porcelain -z output, show old→new in panel and diff
7. **Merge conflicts** — Detect conflict codes, show in top section, single editable pane with markers
8. **Navigation** — `gf`, `Ctrl-h`/`Ctrl-l` focus switching, single instance (focus existing tab), `Tab`/`S-Tab` cycling
9. **Staging — file level** — Stage/unstage/discard per-type rules, optimistic UI with rollback
10. **Staging — bulk** — Folder operations, `S`/`U` stage/unstage all, MM file handling
11. **Auto-refresh** — Watch `.git/index` + `.git/HEAD` for external changes, debounced
12. **Polish** — Theme highlights, status line, config options, filter prompt, buffer caching

---

## Decisions

- **Editable buffers**: Right pane of unstaged modified/new/renamed files is the actual working file
- **MM files**: Appear in both Changes and Staged Changes with different diffs
- **Staged diffs**: `git show :0:path` side-by-side vs HEAD — read-only both sides
- **Merge conflicts**: Separate top section, single editable pane with raw markers, no 3-way view
- **Binary detection**: Via `git diff --numstat` `-\t-` output (free, no extra command)
- **Filetype detection**: `vim.bo.filetype` set from path extension — reliable on scratch buffers
- **Async pattern**: `vim.system()` with `on_exit` callback + `vim.schedule()` for Neovim API calls
- **Cursor after staging**: Stays at same line number, lands on whatever is there
- **Untracked discard**: Deletes file from disk with confirmation
- **Stage all / Unstage all**: No confirmation
- **Auto-jump on open**: Cursor jumps to first change hunk when opening a diff
- **Escape in diff**: Standard vim behaviour — use `Ctrl-h` to return to file panel
- **Submodules**: Detected and shown with "Submodule — diff not supported" message
- **Neovim version**: Latest only — uses `vim.system()`, `vim.uv`, `vim.wo`
- **Dependencies**: None — no plenary, no external libs
