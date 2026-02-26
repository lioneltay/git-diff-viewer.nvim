# Fix: Diff Highlighting Vanishes When Popups Open

## Problem

When the cursor is in a diff pane (not the sidebar panel), opening floating
windows from plugins causes diff highlighting to vanish:

- **`:` key** (noice.nvim cmdline popup): filler lines (`////` hatched regions),
  DiffAdd (green), DiffDelete (red) all disappear
- **`<Space>` key** (which-key popup + snacks.nvim backdrop): same loss of diff
  marks and filler lines

The issue only manifests when the cursor is focused in the diff pane, because
the floating window inherits `diff=true` from the current window.

## Root Cause

Neovim's floating windows inherit window-local options from the parent window.
When a plugin creates a floating window while the cursor is in a diff pane,
the new window gets `diff=true`. This causes Neovim's diff engine to include
the floating window as a third (or fourth, with snacks backdrop) participant
in the diff calculation, corrupting filler lines and highlights across all
diff windows.

Key references:
- [noice.nvim #1169](https://github.com/folke/noice.nvim/issues/1169) — floating cmdline inherits diff mode
- [Neovim #28510](https://github.com/neovim/neovim/issues/28510) — no granular floating window redraw

### Why standard autocmds don't work

- **WinEnter/WinLeave**: noice.nvim suppresses these when creating its cmdline
  popup, so they never fire
- **Deferred restoration** (vim.schedule, vim.defer_fn): by the time these
  fire, the diff engine has already recalculated with the floating window
  included. Calling `diffupdate` or `redraw!` can't fix it while the floating
  window still participates in diff
- **diffthis**: re-entering diff mode after the floating window exists doesn't
  help because the floating window is still a diff participant

## Solution

Three-layer defense in `init.lua` `setup_autocmds()` (lines ~200-282):

### Layer 1: `nvim_open_win` interception (primary)

Monkey-patch `vim.api.nvim_open_win` to strip `diff=true` from any new
floating window at creation time — before the diff engine recalculates.

```lua
local orig_open_win = vim.api.nvim_open_win
vim.api.nvim_open_win = function(buf, enter, config, ...)
  local win = orig_open_win(buf, enter, config, ...)
  if state.is_active() and config and config.relative and config.relative ~= "" then
    if vim.api.nvim_win_is_valid(win) and vim.wo[win].diff then
      vim.wo[win].diff = false
    end
  end
  return win
end
```

This catches **all** plugins: which-key, snacks.nvim backdrop, noice.nvim,
telescope, etc. The hook only activates when the viewer is open
(`state.is_active()`), and only targets floating windows (`config.relative ~= ""`).

### Layer 2: CmdlineEnter suspension (noice.nvim fallback)

Suspend diff on all diff windows before cmdline mode, because noice.nvim may
create its floating cmdline window through a path that bypasses our hook:

```lua
vim.api.nvim_create_autocmd("CmdlineEnter", {
  group = augroup,
  callback = function()
    if not state.is_active() then return end
    for _, w in ipairs(state.diff_wins or {}) do
      if vim.api.nvim_win_is_valid(w) then
        vim.wo[w].diff = false
      end
    end
  end,
})
```

This means during `:` command input, the diff panes show clean text (no diff
marks), which is visually clean and avoids corruption.

### Layer 3: CmdlineLeave + WinEnter restoration

Restore all diff settings after popups close:

```lua
-- CmdlineLeave: restore after cmdline closes
vim.api.nvim_create_autocmd("CmdlineLeave", {
  group = augroup,
  callback = function()
    if not state.is_active() then return end
    vim.schedule(restore_diff_wins)
  end,
})

-- WinEnter: catch any case where diff was lost
vim.api.nvim_create_autocmd("WinEnter", {
  group = augroup,
  callback = function()
    if not state.is_active() then return end
    if vim.api.nvim_get_current_tabpage() ~= state.tab then return end
    for _, w in ipairs(state.diff_wins or {}) do
      if vim.api.nvim_win_is_valid(w) and not vim.wo[w].diff then
        restore_diff_wins()
        return
      end
    end
  end,
})
```

The `restore_diff_wins()` helper re-applies all diff window options (`diff`,
`scrollbind`, `cursorbind`, `foldmethod=diff`, `foldlevel=999`) and runs
`diffupdate`.

### Lifecycle safety

The `nvim_open_win` hook is stored in `state._orig_open_win` and properly
restored in `teardown_autocmds()` when the viewer closes:

```lua
teardown_autocmds = function()
  vim.api.nvim_clear_autocmds({ group = augroup })
  if state._orig_open_win then
    vim.api.nvim_open_win = state._orig_open_win
    state._orig_open_win = nil
  end
end
```

## Behavior

| Trigger | During popup | After popup closes |
|---------|-------------|-------------------|
| `<Space>` (which-key) | Diff **preserved** (filler lines + colors intact) | Diff intact |
| `:` (noice cmdline) | Diff suspended (clean text) | Diff **fully restored** |
| Close/reopen viewer | Hook cleaned up and re-installed | Works correctly |

## Files Modified

- `lua/git-diff-viewer/init.lua` — `setup_autocmds()` and `teardown_autocmds()`
