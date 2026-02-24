local M = {}

function M.setup(opts)
  M.opts = opts or {}
end

-- Open the diff viewer
function M.open()
  -- Create a buffer for the file panel
  local panel_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(panel_buf, 0, -1, false, {
    "  Git Diff Viewer",
    "  ──────────────────",
    "",
    "  Plugin is working!",
    "",
    "  TODO: Show changed files here",
  })
  vim.api.nvim_set_option_value("modifiable", false, { buf = panel_buf })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = panel_buf })

  -- Open in a new tab with a left panel split
  vim.cmd("tabnew")
  local main_win = vim.api.nvim_get_current_win()

  -- Left panel
  vim.cmd("topleft vsplit")
  local panel_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(panel_win, panel_buf)
  vim.api.nvim_win_set_width(panel_win, 40)

  -- Focus the main area
  vim.api.nvim_set_current_win(main_win)

  -- Close with q
  vim.keymap.set("n", "q", function()
    vim.cmd("tabclose")
  end, { buffer = panel_buf, desc = "Close diff viewer" })
end

-- Close the diff viewer
function M.close()
  vim.cmd("tabclose")
end

-- Register commands
vim.api.nvim_create_user_command("GitDiffViewer", function()
  M.open()
end, { desc = "Open Git Diff Viewer" })

vim.api.nvim_create_user_command("GitDiffViewerClose", function()
  M.close()
end, { desc = "Close Git Diff Viewer" })

return M
