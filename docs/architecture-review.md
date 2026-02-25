# git-diff-viewer.nvim — Architecture Review

## Module Dependency Graph

```
                        ┌─────────────────────────────────┐
                        │          init.lua                │
                        │  (orchestrator / god module)     │
                        └──┬──┬──┬──┬──┬──┬──┬──┬────────┘
                           │  │  │  │  │  │  │  │
            ┌──────────────┘  │  │  │  │  │  │  └──────────────────┐
            │     ┌───────────┘  │  │  │  │  └───────────┐         │
            │     │     ┌────────┘  │  │  └────────┐     │         │
            v     v     v           v  v           v     v         v
        ┌──────┐┌─────┐┌───┐   ┌─────┐┌─────┐ ┌──────┐┌─────┐┌────┐
        │config││state││git│   │parse││utils│ │layout││panel││diff│
        └──────┘└─────┘└───┘   └─────┘└─────┘ └──────┘└─────┘└────┘
                                                          │
                                                       ┌──────┐
                                                       │finder│
                                                       └──────┘

  Deferred require() calls (in keymap callbacks, breaking cycles):

    panel ··> init         (via require("git-diff-viewer") in keymaps)
    panel ··> diff         (via require("git-diff-viewer.ui.diff") in <CR> keymap)
    panel ··> finder       (via require("git-diff-viewer.ui.finder") in <leader>ff)
    diff  ··> init         (via require("git-diff-viewer") in keymap callbacks)
    diff  ··> finder       (via require("git-diff-viewer.ui.finder") in <leader>ff)

  Direct top-level require() calls:

    init   → config, state, git, parse, utils, layout, panel, diff
    layout → state, config
    panel  → state, config, utils
    diff   → state, git, utils, layout, config
    finder → state, panel, diff
```

---

## 1. Module Cohesion Assessment

| Module | Lines | Responsibility | Cohesion | Notes |
|--------|-------|---------------|----------|-------|
| config.lua | ~30 | Default config + user merge | HIGH | Clean, minimal, single responsibility |
| state.lua | ~75 | Singleton mutable state | HIGH | Well-documented data container. Minor concern: `nvim_create_namespace` side effect in `reset()` |
| git.lua | ~220 | Async git command wrappers | HIGH | Pure I/O. No state mutation. No parsing. `GIT_OPTIONAL_LOCKS=0` is a nice touch |
| parse.lua | ~200 | Git output parsers | HIGH | Pure functions. Zero dependencies. Most testable module |
| utils.lua | ~110 | Helpers (icons, highlights, paths) | MEDIUM | Grab-bag. `setup_highlights` arguably belongs in a UI module |
| init.lua | ~735 | Everything else (see below) | LOW | God module — primary architectural concern |
| ui/layout.lua | ~155 | Tab/window creation and management | HIGH | Focused. Handles `equalalways` correctly |
| ui/panel.lua | ~553 | File panel rendering + keymaps | HIGH | `build_lines` is large (~280 lines) but cohesive — one rendering pass |
| ui/diff.lua | ~551 | Diff buffer loading + display | MEDIUM | Correct coverage of all file states. Repetitive patterns (see Duplication) |
| ui/finder.lua | ~227 | Floating file picker | HIGH | Self-contained. Own lifecycle. Good isolation |

### The init.lua God Module Problem

`init.lua` handles 10+ distinct responsibilities:

1. Plugin setup (`M.setup`)
2. Data loading (`load_and_render`, `load_and_render_branch`)
3. Open lifecycle (`M.open`) — 3 nested async callbacks, autocmd registration, debounced refresh
4. Close lifecycle (`M.close`)
5. Refresh (`M.refresh`) — including buffer cache eviction
6. File cycling (`next_file`, `prev_file`, `all_file_items`, `open_file_item`)
7. Git staging operations (`stage_item`, `unstage_item`, `discard_item`, `stage_all`, `unstage_all`)
8. Optimistic UI framework (`optimistic`, `remove_item`, `move_item`)
9. Branch mode lifecycle (`open_branch`) — a near-copy of `open()`
10. User command registration

**Signal that it's too big:** `open()` and `open_branch()` share ~120 lines of duplicated setup code, but extracting a shared function within this file didn't happen because the file is already too unwieldy.

---

## 2. Data Flow

### Main Render Pipeline (unidirectional — good)

```
  User action (keymap / autocmd)
       │
       v
  init.lua (orchestrator)
       │
       ├── git.lua ──(vim.system async)──> raw stdout
       │                                       │
       │                                  vim.schedule()
       │                                       │
       v                                       v
  parse.lua  <──────────────────── raw strings arrive
       │
       v
  state.lua  <──── structured data written (state.files / state.branch_files)
       │
       v
  panel.render()  ──── reads state, produces buffer content + highlights
```

### Optimistic Update Pipeline (bidirectional — concerning)

```
  User presses 's' (stage)
       │
       v
  init.lua:stage_item()
       │
       ├── 1. Capture old_files = deepcopy(state.files)
       ├── 2. Mutate state.files directly (remove from changes, add to staged)
       ├── 3. panel.render() (immediate UI update)
       ├── 4. git.stage(path) ──(async)──> result
       │                                      │
       │                                 vim.schedule()
       │                                      │
       v                                      v
  On success: load_and_render()          On failure: state.files = old_files
              (replaces optimistic               panel.render() (rollback)
               state with real git data)
```

**Concerns:**
- The `panel ··> init` deferred-require dependency creates a logical cycle. Works in Lua but makes reasoning harder.
- State mutations happen in 3 places: `init.lua` (optimistic updates), `panel.render()` (writes `panel_lines`), `diff.open()` (writes `current_diff`). No single gatekeeper for state writes.

---

## 3. State Management

### Pattern: Global Singleton Table

`state.lua` exports a single Lua table. All modules import it and read/write fields directly. `state.reset()` returns everything to initial values.

### Pros
- Simple. No boilerplate.
- All state visible in one file with documentation.
- `reset()` provides clean teardown.
- Natural fit for Neovim's singleton plugin model.

### Cons
- **No encapsulation.** Any module can write any field at any time. No guards against invalid state transitions (e.g., setting `state.mode = "branch"` without `state.merge_base`).
- **No generation counter.** Stale async callbacks can write into reset state. Currently works by accident: `panel.render()` checks buffer validity and bails. Not safe by design.
- **Single instance only.** One viewer at a time. Intentional, but the architecture makes multi-instance support impossible without a rewrite.

### Race Condition on Reset

```
  1. User opens viewer          → state.mode = "status"
  2. Async git.status() fires   → in flight
  3. User closes viewer         → state.reset() clears everything
  4. git.status() callback      → vim.schedule fires
  5. Callback writes state      → state.files = parsed data (dead state)
  6. panel.render() called      → buf is nil/invalid → early return (saves us)
```

Safe in practice due to the buffer validity guard. Not safe by design.

### Stale `current_diff` After Refresh

When `load_and_render()` replaces `state.files` with freshly parsed data, `state.current_diff` still references an item object from the old `state.files`. The panel active highlight is lost because the old object is no longer in any section. The item is structurally identical but a different object reference. No reconciliation step exists to find the matching item in the new data.

---

## 4. Async Patterns

### Pattern: `vim.system()` + `vim.schedule()` Callbacks

All git calls use `vim.system()` with `on_exit`. Callbacks fire on a libuv thread; all Neovim API access is wrapped in `vim.schedule()`.

### Fan-out/Join Pattern

```lua
local pending = 3
local function try_render()
  pending = pending - 1
  if pending > 0 then return end
  -- all 3 done, parse and render
end
-- fire 3 git commands in parallel, each calls try_render on completion
```

Used in: `load_and_render` (3 calls), `load_and_render_branch` (2 calls), and several `diff.lua` paths (2 calls each).

### Assessment

| Aspect | Status | Notes |
|--------|--------|-------|
| `vim.schedule()` consistency | GOOD | Every callback wraps API calls |
| Parallel fan-out | GOOD | Simple, correct |
| Cancellation | MISSING | Rapid refresh fires duplicate git commands; no way to cancel in-flight ones |
| Optimistic serialization | MISSING | `optimistic()` allows concurrent calls with no queue/mutex. Each captures `deepcopy(state.files)` at call time; concurrent operations' rollbacks reference wrong baselines (see features.md bug #1) |
| Stale callback guard | WEAK | Relies on buffer validity check, not generation counter |
| Error propagation | BAD | `load_and_render` ignores the `ok` parameter: `function(_, raw)` — git failures are silently swallowed |
| Timeout handling | MISSING | Hung git commands (credential prompts) block forever with no feedback |
| Callback nesting | AT LIMIT | `open()` has 3 levels; `open_branch()` has 4 levels |

---

## 5. Error Handling Consistency

| Layer | Pattern | Assessment |
|-------|---------|------------|
| git.lua | Returns `(ok, stdout_or_stderr)` to every callback | GOOD — uniform |
| parse.lua | Guards `if not raw or raw == ""` at top | GOOD — defensive |
| init.lua `load_and_render` | Ignores `ok` param: `function(_, raw)` | BAD — errors silently swallowed |
| init.lua `optimistic` | Shows `utils.error()` on failure, rolls back | GOOD |
| diff.lua | Shows `"(error loading ...)"` in buffer | GOOD — user-visible |
| layout.lua | Uses `pcall` for window operations | GOOD — defensive |
| ui/finder.lua | Checks buffer validity before operations | GOOD |

**Gap:** `load_and_render()` and `load_and_render_branch()` never check if git commands succeeded. If `git status` fails, the panel silently shows an empty file list. No user notification.

---

## 6. Code Duplication

### Significant (should extract)

**A) Git content → buffer lines pattern** — repeated 12 times in diff.lua:
```lua
local lines = vim.split(content, "\n", { plain = true })
if lines[#lines] == "" then table.remove(lines) end
set_buf_content(buf, lines)
```
Should be a single helper: `set_buf_from_git_content(buf, content)`.

**B) `open()` and `open_branch()` shared setup** — ~120 lines duplicated:
- Repo detection sequence: `is_git_repo → get_root → has_commits`
- UI setup: `create_tab`, `create_buf`, `set_panel_buf`, focus
- Autocmd registration: WinNew, TabClosed (verbatim copy)
- Layout and render kickoff

**C) Fan-out/join counter pattern** — repeated 4-5 times across init.lua and diff.lua. Each instance reinvents the same `pending`/`try_render` mechanism.

**D) NUL-split + empty-filter** in parse.lua — repeated 4 times:
```lua
local raw_parts = vim.split(raw, "\0", { plain = true })
local parts = {}
for _, part in ipairs(raw_parts) do
  if part ~= "" then table.insert(parts, part) end
end
```

### Minor

**E) Branch mode section construction** — duplicated in panel.lua and finder.lua:
```lua
if state.mode == "branch" then
  sections = { conflicts = {}, changes = state.branch_files, staged = {} }
else
  sections = state.files
end
```

---

## 7. Coupling Analysis

### Tight Coupling (risky to change)

- **init.lua ↔ state.lua**: init directly manipulates state internals (`state.files.changes`, `state.files.staged`). The optimistic update functions reach deeply into state's internal structure.
- **panel.lua ↔ state.lua**: panel reads nearly every field in state (~12 fields).
- **diff.lua ↔ state.lua**: diff reads and writes `current_diff`, `buf_cache`, `diff_bufs`, `has_commits`, `git_root`.

### Loose Coupling (safe to change)

- **git.lua**: Zero dependencies on other plugin modules. Pure I/O. Could be extracted as a standalone library.
- **parse.lua**: Zero dependencies. Pure functions. Fully testable in isolation.
- **config.lua**: Only consumed, never consumes. Leaf node.
- **finder.lua**: Self-contained. Only consumes state, panel, diff.

### Changeability Matrix

| Module | Changeability | Breaking Risk |
|--------|--------------|---------------|
| config.lua | High — just add new keys | Low |
| git.lua | High — stable callback interface | Low |
| parse.lua | High — pure functions | Low |
| utils.lua | Medium — highlight names are conventions | Low |
| state.lua | **Low** — changing field names/shapes breaks everything | **High** |
| layout.lua | Medium — window management is isolated | Medium |
| panel.lua | Medium — build_lines used by finder | Medium |
| diff.lua | Medium — fairly self-contained | Low |
| finder.lua | High — self-contained | Low |
| init.lua | **Low** — everything depends on it via deferred require | **High** |

---

## 8. Buffer Lifecycle

### Creation Points

| Buffer Type | Created By | `bufhidden` | Stored In | Cleanup |
|-------------|-----------|-------------|-----------|---------|
| Panel | `panel.create_buf()` | `wipe` | `state.panel_buf` | Wiped when window closes |
| Diff scratch (git show) | `diff.get_or_create_scratch()` | `hide` | `state.buf_cache` | `state.reset()` force-deletes; `refresh()` selectively wipes |
| Working file | `vim.fn.bufnr(path, true)` | (default) | Not tracked | Persists (user's actual file) |
| Message | Ad-hoc `nvim_create_buf` | `wipe` | Not tracked | Ephemeral |
| Finder | `nvim_create_buf` | `wipe` | Local vars | Wiped on close |

### Cache Management Issues

1. **Orphaned buffer detection** in `get_or_create_scratch()` checks for buffers by name that exist outside the cache — a defensive measure against E95, suggesting cleanup has historically been imperfect.
2. **`refresh()` clears cache map but not all buffers.** Displayed buffers survive but lose their cache entry. Re-found via orphan detection, but content may be stale.
3. **Double reset on close.** `layout.close()` triggers TabClosed autocmd → `state.reset()`, then `M.close()` calls `state.reset()` again. Harmless but wasteful.

---

## 9. Window Management

### Tab-based Isolation — Good Architectural Choice

The viewer lives in a dedicated tab, providing natural isolation from the user's window layout. The plugin cannot accidentally corrupt other windows/tabs.

### Panel Width Enforcement

Set in three places (defensive but necessary due to `equalalways` and splits):
1. `layout.create_tab()` — initial creation
2. `layout.set_panel_buf()` — buffer assignment
3. `layout.open_diff_wins()` — after diff window operations

`winfixwidth` is also set on the panel window.

### `wincmd l` Fragility in `open_diff_wins`

`open_diff_wins()` uses `wincmd l` to navigate from the panel to the main diff area (layout.lua:126). This assumes the window to the right of the panel is always the diff area. If the layout is different from expected (e.g., user manually splits), `wincmd l` might navigate to the wrong window. The function defensively checks if it's still in the panel window after the `wincmd l`, but a tracked `state.main_win` handle would be more reliable. `create_tab()` already returns `main_win` (layout.lua:65) but neither init.lua caller captures the return value, so the handle is lost.

### The `equalalways` Dance

```lua
local ea = vim.o.equalalways
vim.o.equalalways = false
-- ... window operations ...
vim.o.equalalways = ea
```

Correct pattern but not protected by `pcall` — if a window operation throws, the global setting is permanently changed.

### Floating Window Diff Inheritance

Both `open()` and `open_branch()` register a WinNew autocmd that strips `diff`, `scrollbind`, `cursorbind` from floating windows. This prevents which-key, completion popups, etc. from inheriting diff mode. Good defensive measure, but the autocmd itself leaks (see bug #5 in features.md).

---

## 10. Summary of Architectural Concerns

### Strengths

1. **Clean bottom layers.** git.lua and parse.lua are pure, testable, dependency-free modules.
2. **Correct async handling.** `vim.schedule()` used consistently; fan-out/join is simple and correct.
3. **Thoughtful Neovim integration.** equalalways dance, winfixwidth, diff mode E96 workaround, floating window diff fix, GIT_OPTIONAL_LOCKS=0.
4. **Optimistic UI with rollback.** Staging operations provide immediate feedback with automatic rollback on failure.
5. **Buffer cache.** Avoids re-fetching git show content on every navigation.
6. **Tab-based isolation.** Cannot corrupt user's window layout.

### Top Concerns (by impact)

| # | Concern | Impact | Root Cause |
|---|---------|--------|------------|
| 1 | Optimistic UI has no serialization | Critical | Concurrent operations corrupt each other's rollback snapshots |
| 2 | init.lua god module (735 lines, 10+ responsibilities) | High | No separation between lifecycle management, git operations, and optimistic UI framework |
| 3 | `open()` / `open_branch()` duplication (~120 lines) | High | God module makes extraction awkward |
| 4 | Silent error swallowing in `load_and_render` | High | `ok` parameter ignored in both `load_and_render` and `load_and_render_branch` |
| 5 | No async cancellation | Medium | Rapid refresh fires duplicate git operations; non-deterministic render order |
| 6 | No stale-state guard | Medium | Works by accident (buffer validity) not by design (generation counter) |
| 7 | Autocmd lifecycle management | Medium | No augroup; no batch-clear on close |
| 8 | Diff.lua repetitive patterns (12x content → buffer) | Medium | Missing helper extraction |
| 9 | State mutations from 3+ modules | Medium | No single gatekeeper for state writes |
| 10 | Stale `current_diff` after refresh | Medium | `load_and_render` replaces `state.files` but `current_diff` still references old item object |
| 11 | Data model split (`state.files` vs `state.branch_files`) | Medium | Every consumer needs `if mode == "branch"` conditional; duplicated in panel.lua and finder.lua |
| 12 | `wincmd l` fragility in `open_diff_wins` | Low | `create_tab` returns `main_win` but callers don't capture it; `wincmd l` assumed to reach diff area |
