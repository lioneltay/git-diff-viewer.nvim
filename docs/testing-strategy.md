# Testing Strategy for git-diff-viewer.nvim

## Context

The plugin currently has zero tests. We need a testing strategy that provides a tight feedback loop during the refactoring (11 phases, 19 design changes, 27 bug fixes) so the plugin can be built and verified without manual user intervention until the end.

Two complementary approaches:
1. **Automated unit/integration tests** — fast, run from CLI, cover pure functions and async git operations
2. **Interactive tmux+nvim tests** — verify actual UI behavior end-to-end, usable by both the main agent and subagents

Tests are written **alongside** the new architecture implementation, not for the existing code. Pure-function modules (`parse.lua`, `utils.lua`) carry forward unchanged, so their tests validate both the old and new code.

---

## Part 1: Automated Tests (plenary.busted)

### Why plenary.busted

- Standard in the Neovim plugin ecosystem (gitsigns, telescope, nvim-cmp all use it)
- Provides `describe`/`it`/`before_each`/`after_each` (busted DSL)
- Includes `luassert` for assertions, stubs, mocks, spies
- Runs headless via CLI: `nvim --headless -c "PlenaryBustedDirectory ..."`
- Supports async via `vim.wait()` for callback-based code

### File structure

```
tests/
├── minimal_init.lua        — Minimal config to load plenary + plugin
├── helpers/
│   └── git_repo.lua        — Test repo creation/teardown helpers
├── unit/
│   ├── parse_spec.lua      — parse.lua pure function tests
│   ├── utils_spec.lua      — utils.lua pure function tests
│   ├── config_spec.lua     — config.lua setup/merge tests
│   └── state_spec.lua      — state.lua reset/mutation API tests
├── integration/
│   ├── git_spec.lua        — git.lua async commands against real repos
│   ├── operations_spec.lua — staging/unstaging with real git
│   └── lifecycle_spec.lua  — open/close/refresh lifecycle
Makefile                    — `make test` runner
```

### `tests/minimal_init.lua`

```lua
-- Minimal init for test environment
vim.opt.rtp:prepend('.')
vim.opt.rtp:prepend('deps/plenary.nvim')
vim.cmd('runtime plugin/plenary.vim')
vim.o.swapfile = false
vim.o.backup = false
```

### `Makefile`

```makefile
PLENARY_DIR = deps/plenary.nvim

$(PLENARY_DIR):
	mkdir -p deps
	git clone --depth 1 https://github.com/nvim-lua/plenary.nvim $(PLENARY_DIR)

.PHONY: test test-unit test-integration
test: $(PLENARY_DIR)
	nvim --headless -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"

test-unit: $(PLENARY_DIR)
	nvim --headless -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/unit/ {minimal_init = 'tests/minimal_init.lua'}"

test-integration: $(PLENARY_DIR)
	nvim --headless -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/integration/ {minimal_init = 'tests/minimal_init.lua'}"
```

### `tests/helpers/git_repo.lua` — Reusable test repo helper

```lua
local M = {}

--- Create a temporary git repo with a specific state.
--- Returns the repo dir path. Call M.cleanup(dir) when done.
function M.create(opts)
  opts = opts or {}
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')

  local function git(args)
    local cmd = { 'git', '-C', dir }
    for _, a in ipairs(args) do table.insert(cmd, a) end
    local obj = vim.system(cmd):wait()
    assert(obj.code == 0, 'git failed: ' .. table.concat(args, ' ') .. '\n' .. (obj.stderr or ''))
  end

  git({ 'init' })
  git({ 'config', 'user.email', 'test@test.com' })
  git({ 'config', 'user.name', 'Test User' })
  git({ 'config', 'core.hooksPath', '/dev/null' })

  if opts.initial_commit ~= false then
    vim.fn.writefile({ 'initial' }, dir .. '/README.md')
    git({ 'add', '.' })
    git({ 'commit', '-m', 'initial commit' })
  end

  return dir
end

--- Write a file relative to dir
function M.write_file(dir, rel_path, lines)
  local full = dir .. '/' .. rel_path
  local parent = vim.fn.fnamemodify(full, ':h')
  vim.fn.mkdir(parent, 'p')
  vim.fn.writefile(lines, full)
end

--- Run git command in dir, return SystemCompleted object
function M.git(dir, args)
  local cmd = { 'git', '-C', dir }
  for _, a in ipairs(args) do table.insert(cmd, a) end
  return vim.system(cmd):wait()
end

--- Clean up a test repo
function M.cleanup(dir)
  if dir and vim.fn.isdirectory(dir) == 1 then
    vim.fn.delete(dir, 'rf')
  end
end

return M
```

### What to test — by module

**parse.lua (highest priority — pure functions, most test cases)**

| Function | Test cases |
|----------|-----------|
| `parse_status` | Empty input, single modified file, staged + unstaged, MM (both), renames, copies, conflicts (UU/AA/DD/AU/UA/DU/UD), untracked, ignored, NUL-separated paths |
| `parse_numstat` | Normal counts, binary files (`-\t-`), renames, empty input |
| `build_file_list` | Categorization into conflicts/changes/staged, MM split, untracked goes to changes, staged A_ |
| `parse_name_status` | A/M/D/R status codes, renames with similarity, empty input |
| `build_branch_file_list` | Merges name_status + numstat, correct status_char mapping |

**utils.lua**

| Function | Test cases |
|----------|-----------|
| `path_to_ft` | Common extensions (.ts, .lua, .py, .go), special files (Dockerfile, Makefile), unknown extension, no extension |
| `split_path` | Nested path, single file (no dirs), trailing slash, root file |
| `status_icon` | Each XY code → icon, conflicts, renames, section awareness |
| `format_counts` | Normal counts, zero, nil (binary), large numbers |

**state.lua (after Phases 2-3)**

| Function | Test cases |
|----------|-----------|
| `reset` | Generation increments, sections cleared, current_diff nil |
| `is_active` | nil tab → false, valid tab → true, invalid tab → false |
| `set_current_diff` | Sets correctly, nil clears |
| `reconcile_current_diff` | Same section match, cross-section fallback (MM), file removed |
| `reconcile_viewed_diffs` | Stale items updated, missing items dropped |

**git.lua (integration — needs real git repo)**

| Function | Test cases |
|----------|-----------|
| `get_root` | From subdirectory, from root, non-git dir fails |
| `status` | Modified file, staged file, untracked, clean repo |
| `stage` / `unstage` | Single file, multiple files, error handling |
| `show_head` | Existing file, non-existent file |

**operations.lua (integration — after Phase 6)**

| Function | Test cases |
|----------|-----------|
| `stage_item` | Moves from changes → staged in state.sections, fires git |
| `unstage_item` | Moves from staged → changes, A_ becomes ?? |
| `discard_item` | Staged file uses checkout_head, folder prompts |

### Async test pattern

```lua
-- For git.lua tests that use callbacks:
it('gets git root', function()
  local done = false
  local result_ok, result_root

  git_mod.get_root(test_dir, function(ok, root)
    result_ok = ok
    result_root = root
    done = true
  end)

  vim.wait(5000, function() return done end, 50)
  assert.is_true(result_ok)
  assert.equals(test_dir, result_root)
end)
```

---

## Part 2: Interactive tmux+nvim Tests

### Purpose

Verify actual UI behavior that automated tests can't cover:
- Panel renders correctly with sections, folders, file icons
- Diff windows open in the right layout (side-by-side vs single)
- Keymaps work (Enter opens diff, s stages, q closes)
- Visual feedback (highlights, active file indicator)
- Window management (panel width, equalalways)
- Ctrl-O/I jumplist navigation
- Viewed diffs picker UI

### Test git repo setup script

`tests/create_test_repo.sh` — creates a git repo with every file state the plugin handles:

```bash
#!/bin/bash
# Creates a git repo with every file state the plugin handles
set -e

DIR="${1:-/tmp/gdv-test-repo}"
rm -rf "$DIR"
mkdir -p "$DIR"
cd "$DIR"

git init
git config user.email "test@test.com"
git config user.name "Test User"
git config core.hooksPath /dev/null

# ─── Initial committed files ─────────────────────────────
mkdir -p src/components/shared src/utils docs

echo 'export function hello() { return "hello" }' > src/app.ts
echo 'export const add = (a, b) => a + b' > src/utils/math.ts
echo 'export const AUTH_KEY = "secret"' > src/utils/auth.ts
echo 'export function Button() { return <button/> }' > src/components/shared/Button.tsx
echo '# Project' > docs/README.md
echo '{ "name": "test" }' > package.json
echo 'line 1' > to-delete.txt
echo 'line 1' > to-delete-staged.txt
echo 'original name' > to-rename.txt
echo 'will conflict' > conflict-file.txt
printf '\x89PNG\r\n' > image.png  # binary file

git add .
git commit -m "initial commit"

# ─── Create branch for branch-mode testing ────────────────
git checkout -b feature/auth
echo 'export function login() { return true }' > src/auth.ts
echo 'modified on branch' >> src/app.ts
echo 'new util' > src/utils/validator.ts
rm docs/README.md
git mv to-rename.txt renamed-file.txt
git add .
git commit -m "feature: add auth"
git checkout main

# ─── More commits on main (to test merge-base) ───────────
echo 'main-only change' >> package.json
git add . && git commit -m "update package.json on main"

# ─── Working tree changes (for status mode) ──────────────
# Modified unstaged (_M)
echo 'modified content' >> src/app.ts

# Staged modified (M_)
echo 'staged change' >> src/utils/math.ts
git add src/utils/math.ts

# Both modified (MM) — staged then modified again
echo 'staged version' >> src/utils/auth.ts
git add src/utils/auth.ts
echo 'working tree version on top' >> src/utils/auth.ts

# Untracked new file (??)
echo 'new file' > src/new-file.ts

# Staged new file (A_)
echo 'staged new' > src/staged-new.ts
git add src/staged-new.ts

# Deleted unstaged (_D)
rm to-delete.txt

# Deleted staged (D_)
git rm to-delete-staged.txt

# Staged rename (R_)
git mv to-rename.txt renamed-result.txt

# Untracked in deep nested path (for compact folder testing)
mkdir -p src/components/shared/utils/helpers
echo 'deep file' > src/components/shared/utils/helpers/deep.ts

# Binary modified
printf '\x89PNG\r\nmodified' > image.png

echo ""
echo "Test repo created at: $DIR"
echo ""
echo "Status mode should show:"
echo "  Changes: src/app.ts (M), to-delete.txt (D), src/utils/auth.ts (MM),"
echo "           src/new-file.ts (?), image.png (M),"
echo "           src/components/shared/utils/helpers/deep.ts (?)"
echo "  Staged:  src/utils/math.ts (M), src/utils/auth.ts (MM),"
echo "           src/staged-new.ts (A), to-delete-staged.txt (D),"
echo "           renamed-result.txt (R)"
echo ""
echo "Branch mode (:GitDiffViewerBranch feature/auth main) should show:"
echo "  src/auth.ts (A), src/app.ts (M), src/utils/validator.ts (A),"
echo "  docs/README.md (D), renamed-file.txt (R)"
```

### Conflict setup (separate script, run when needed)

`tests/create_conflict.sh` — adds merge conflicts to an existing test repo:

```bash
#!/bin/bash
# Run inside an existing test repo to create merge conflicts
cd "${1:-.}"
git checkout -b conflict-branch
echo 'branch version' > conflict-file.txt
git add . && git commit -m "branch change"
git checkout main
echo 'main version' > conflict-file.txt
git add . && git commit -m "main change"
git merge conflict-branch || true  # creates merge conflict
```

### tmux testing guide

This guide is followed by both the main agent and subagents for interactive testing.

#### Setup

```bash
# 1. Create unique identifiers to avoid conflicts between agents
SESSION="gdv-test-$(date +%s)-$$"
REPO_DIR="/tmp/gdv-test-$$"

# 2. Create the test repo
bash /path/to/git-diff-viewer.nvim/tests/create_test_repo.sh "$REPO_DIR"

# 3. Start nvim in tmux with only the plugin loaded (no user config)
tmux new-session -d -s "$SESSION" -x 200 -y 50 -c "$REPO_DIR"
tmux send-keys -t "$SESSION" "nvim -u NONE -c 'set rtp+=/path/to/git-diff-viewer.nvim' -c 'lua require(\"git-diff-viewer\").setup()'" Enter

# 4. Wait for nvim to start (poll, don't sleep)
for i in $(seq 1 20); do
  tmux capture-pane -t "$SESSION" -p | grep -qE '~|NORMAL' && break
  sleep 0.5
done
```

#### Core commands

```bash
# Send an Ex command
tmux send-keys -t "$SESSION" ':GitDiffViewer' Enter

# Wait for panel to render (poll for section headers)
for i in $(seq 1 20); do
  tmux capture-pane -t "$SESSION" -p | grep -q "Changes" && break
  sleep 0.5
done

# Capture current screen state
OUTPUT=$(tmux capture-pane -t "$SESSION" -p)

# Send normal mode keys
tmux send-keys -t "$SESSION" 'j'          # move down
tmux send-keys -t "$SESSION" Enter        # open diff
tmux send-keys -t "$SESSION" 's'          # stage
tmux send-keys -t "$SESSION" 'q'          # close

# Ctrl sequences
tmux send-keys -t "$SESSION" C-o          # jumplist back
tmux send-keys -t "$SESSION" C-i          # jumplist forward
tmux send-keys -t "$SESSION" C-h          # focus panel
tmux send-keys -t "$SESSION" Escape       # ensure normal mode
```

#### Test scenarios

**T1: Status mode opens correctly**
```bash
tmux send-keys -t "$SESSION" ':GitDiffViewer' Enter
sleep 1
OUTPUT=$(tmux capture-pane -t "$SESSION" -p)
echo "$OUTPUT" | grep -q "Changes" && echo "PASS: Changes section" || echo "FAIL: Changes section"
echo "$OUTPUT" | grep -q "Staged" && echo "PASS: Staged section" || echo "FAIL: Staged section"
echo "$OUTPUT" | grep -q "app.ts" && echo "PASS: Modified file shown" || echo "FAIL: Modified file"
```

**T2: Opening a diff (Enter on file)**
```bash
# Navigate past section header to a file, press Enter
tmux send-keys -t "$SESSION" 'jj' Enter
sleep 0.5
OUTPUT=$(tmux capture-pane -t "$SESSION" -p)
# Verify: diff panes visible (look for file content or diff markers)
```

**T3: Staging a file (s key)**
```bash
tmux send-keys -t "$SESSION" C-h   # focus panel
sleep 0.3
# Navigate to an unstaged file and stage it
tmux send-keys -t "$SESSION" 's'
sleep 0.5
OUTPUT=$(tmux capture-pane -t "$SESSION" -p)
# Verify: file moved from Changes to Staged section
```

**T4: Close and reopen**
```bash
tmux send-keys -t "$SESSION" 'q'
sleep 0.5
tmux send-keys -t "$SESSION" ':GitDiffViewer' Enter
sleep 1
OUTPUT=$(tmux capture-pane -t "$SESSION" -p)
# Verify: panel renders again with sections
echo "$OUTPUT" | grep -q "Changes" && echo "PASS: Reopened" || echo "FAIL: Reopen"
```

**T5: Branch mode**
```bash
tmux send-keys -t "$SESSION" 'q'
sleep 0.3
tmux send-keys -t "$SESSION" ':GitDiffViewerBranch feature/auth main' Enter
sleep 1
OUTPUT=$(tmux capture-pane -t "$SESSION" -p)
echo "$OUTPUT" | grep -q "auth.ts" && echo "PASS: Branch file" || echo "FAIL: Branch file"
```

**T6: Ctrl-O/I jumplist (Phase 8+)**
```bash
tmux send-keys -t "$SESSION" ':GitDiffViewer' Enter
sleep 1
tmux send-keys -t "$SESSION" 'jj' Enter    # open first file
sleep 0.5
tmux send-keys -t "$SESSION" C-h           # back to panel
sleep 0.3
tmux send-keys -t "$SESSION" 'jjj' Enter   # open second file
sleep 0.5
tmux send-keys -t "$SESSION" C-o           # jumplist back
sleep 0.3
OUTPUT=$(tmux capture-pane -t "$SESSION" -p)
# Verify: shows first file's content
```

**T7: Viewed diffs picker (Phase 9+)**
```bash
# After opening some files, trigger <leader>fb
tmux send-keys -t "$SESSION" ' fb'
sleep 0.5
OUTPUT=$(tmux capture-pane -t "$SESSION" -p)
# Verify: floating picker visible with previously viewed files
```

#### Cleanup

```bash
tmux send-keys -t "$SESSION" Escape
tmux send-keys -t "$SESSION" ':qa!' Enter
sleep 0.5
tmux kill-session -t "$SESSION" 2>/dev/null
rm -rf "$REPO_DIR"
```

#### Subagent rules

When delegating testing to a subagent:
1. Each agent **MUST** use its own unique `$SESSION` name and `$REPO_DIR` to avoid conflicts
2. The agent creates the test repo, runs its tests, and cleans up everything
3. The agent reports PASS/FAIL for each scenario with captured output on failure

---

## Part 3: Development Workflow

### When to use which approach

| Scenario | Automated tests | tmux tests |
|----------|----------------|------------|
| Implementing parse.lua changes (Phase 3) | Unit tests for new section format | Not needed |
| Implementing operations.lua (Phase 6) | Integration tests with real git | Quick tmux smoke test |
| Implementing window reuse (Phase 8) | Hard to automate window state | tmux: open files, Ctrl-O/I |
| Implementing viewed diffs picker (Phase 9) | Test state tracking | tmux: visual verification |
| Bug fix (Phase 7) | Add regression test for the specific bug | Optional |
| Compact folders (Phase 11) | Unit test tree building/compaction | tmux: visual verify rendering |

### Per-phase test expectations

| Phase | Automated tests to write | tmux verification |
|-------|-------------------------|-------------------|
| 1. Augroup | Test autocmd cleanup on close/reopen cycle | Open/close 3x, verify no stale autocmds |
| 2. Generation counter | Test stale callback rejection | Rapid close/reopen |
| 3. Unified data model | Test `state.sections` population, `get_section()` | Status + branch mode both render |
| 4. `state.main_win` | Test window tracking across open/close | Diff opens correctly |
| 5. Open lifecycle | Test `open_viewer()` deduplication | Open status, then branch, verify switch |
| 6. Operations | Test stage/unstage/discard against real git | Stage file, verify panel updates |
| 7. Bug fixes | Regression test per bug | Spot-check critical bugs |
| 8. Window reuse | Test window count reuse logic | Ctrl-O/I across file navigations |
| 9. Viewed picker | Test `track_viewed_diff`, reconciliation | Open picker, navigate, remove entries |
| 10. File watching | Test watcher setup/teardown | Edit file externally, verify refresh |
| 11. Compact folders | Test tree build + compact algorithm | Verify rendering of nested paths |

### Per-phase workflow

For each phase:
1. Write/update relevant automated tests
2. Implement the change
3. Run `make test` to verify automated tests pass
4. Run tmux tests for UI-dependent changes
5. Self-review the diff (`git diff`) for mistakes, dead code, missed edge cases
6. Launch an independent reviewer subagent to review the implementation
7. Address reviewer feedback before moving to the next phase

### Independent review protocol

After completing each phase (or logical chunk within a large phase like Phase 7), spawn a subagent to review the changes before proceeding. The reviewer should:

1. **Read the architecture doc** — understand what the phase was supposed to accomplish (the relevant design changes and bug fixes)
2. **Read the changed files** — review the actual implementation diff
3. **Check against the spec** — verify the implementation matches the design changes in `docs/ideal-architecture.md`
4. **Look for issues** — bugs, edge cases, missing error handling, deviations from the plan, regressions
5. **Verify test coverage** — are the new/changed code paths tested? Any missing test cases?
6. **Report findings** — list issues by severity (critical / high / medium / low) with file paths and line numbers

Example prompt for the reviewer:
```
Review the Phase 3 implementation of git-diff-viewer.nvim.

Context: Phase 3 replaces `state.files` + `state.branch_files` with a unified
`state.sections` list. See docs/ideal-architecture.md Design Change #1 and
Migration Strategy Phase 3 for the spec.

Read the changed files and verify:
- state.sections is populated correctly in load_and_render and load_and_render_branch
- panel.lua build_lines iterates state.sections directly
- finder.lua uses state.sections instead of conditional
- All references to state.files / state.branch_files are removed
- Both status and branch modes work correctly with the new model

Report any issues found. Do not edit files.
```

This review step catches problems early — before they compound across later phases. A bug in Phase 3's data model would silently break Phases 6, 7, 8, and 9.

### Subagent testing protocol

When spawning a test subagent during development:

```
1. Give it:
   - Path to tests/tmux-testing.md (or this document's Part 2)
   - Path to tests/create_test_repo.sh
   - Specific test scenarios to run (T1-T7)
   - The current phase being tested

2. It must:
   - Create its own temp repo (unique path)
   - Use a unique tmux session name
   - Run the specified test scenarios
   - Report PASS/FAIL with captured output
   - Clean up everything (tmux session + temp repo)

3. Example prompt:
   "Run tmux tests T1-T4 against the plugin at
   /Users/lioneltay/lioneltay/git-diff-viewer.nvim.
   Follow docs/testing-strategy.md Part 2 for the protocol.
   Use tests/create_test_repo.sh to create a test repo.
   Report results."
```

---

## Part 4: Files to Create

| File | Purpose |
|------|---------|
| `Makefile` | `make test`, `make test-unit`, `make test-integration` |
| `tests/minimal_init.lua` | Minimal nvim config for test runner |
| `tests/helpers/git_repo.lua` | Test repo creation/teardown helpers |
| `tests/unit/parse_spec.lua` | parse.lua tests (~50 test cases) |
| `tests/unit/utils_spec.lua` | utils.lua tests (~30 test cases) |
| `tests/unit/config_spec.lua` | config.lua tests (~5 test cases) |
| `tests/unit/state_spec.lua` | state.lua tests (~15 test cases) |
| `tests/integration/git_spec.lua` | git.lua tests with real repos (~15 test cases) |
| `tests/create_test_repo.sh` | Bash script to create comprehensive test repo |
| `tests/create_conflict.sh` | Bash script to add merge conflicts to a repo |

### Implementation order

1. **First:** `Makefile` + `tests/minimal_init.lua` + `tests/helpers/git_repo.lua` — test infrastructure
2. **Second:** `tests/unit/parse_spec.lua` — highest value, pure functions, most test cases
3. **Third:** `tests/unit/utils_spec.lua` — also pure, quick to write
4. **Fourth:** `tests/create_test_repo.sh` + `tests/create_conflict.sh` — E2E infrastructure
5. **Fifth:** `tests/unit/state_spec.lua` — test mutation API as it's built
6. **Sixth:** `tests/integration/git_spec.lua` — test async git operations
7. **Then:** add tests alongside each phase implementation
