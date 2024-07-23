-- Install packer.nvim if not already installed
local install_path = vim.fn.stdpath('data')..'/site/pack/packer/start/packer.nvim'
if vim.fn.empty(vim.fn.glob(install_path)) > 0 then
  vim.fn.system({'git', 'clone', 'https://github.com/wbthomason/packer.nvim', install_path})
  vim.cmd [[packadd packer.nvim]]
end

-- Plugin setup
require('packer').startup(function(use)
  use 'wbthomason/packer.nvim'
  use 'neovim/nvim-lspconfig'
  use 'nvim-treesitter/nvim-treesitter'
  use 'tpope/vim-surround'
  use 'kyazdani42/nvim-tree.lua'
  use {
    'nvim-telescope/telescope.nvim',
    requires = { {'nvim-lua/plenary.nvim'} }
  }
  use 'github/copilot.vim'
end)

-- LSP setup
local lspconfig = require('lspconfig')
lspconfig.rust_analyzer.setup{}

-- Treesitter setup
require('nvim-treesitter.configs').setup {
  ensure_installed = { "rust", "lua" },
  highlight = {
    enable = true,
  },
}

-- nvim-tree setup
require('nvim-tree').setup{}

-- Telescope setup
require('telescope').setup{}

-- Keybindings
local map = vim.api.nvim_set_keymap
local opts = { noremap = true, silent = true }

map('n', '<C-n>', ':NvimTreeToggle<CR>', opts)
map('n', '<leader>ff', ':Telescope find_files<CR>', opts)
map('n', '<leader>fg', ':Telescope live_grep<CR>', opts)

-- Set some basic options
vim.o.number = true
vim.o.relativenumber = true
vim.o.expandtab = true
vim.o.shiftwidth = 2
vim.o.tabstop = 2
vim.o.smartindent = true
vim.o.termguicolors = true
