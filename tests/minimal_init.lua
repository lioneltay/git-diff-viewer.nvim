-- Minimal init for test environment
vim.opt.rtp:prepend(".")
vim.opt.rtp:prepend("deps/plenary.nvim")
vim.cmd("runtime plugin/plenary.vim")
vim.o.swapfile = false
vim.o.backup = false
