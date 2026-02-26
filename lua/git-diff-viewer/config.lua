-- config.lua — Default configuration and user-provided overrides

local M = {}

M.defaults = {
  -- Width of the file panel (in columns)
  panel_width = 40,

  -- Keymaps for the file panel buffer
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
  },

  -- Keymaps for the diff pane buffers
  diff_keymaps = {
    close = "q",
    open_file = "gf",
    focus_panel = "<C-h>",
  },
}

-- Merged config (defaults + user opts); set by setup()
M.options = {}

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

return M
