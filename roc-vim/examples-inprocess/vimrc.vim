" What is left of a vimrc once the rest of it is a Roc plugin.
"
" Everything here has to run before Vim loads any plugin, which is why it
" cannot move into vimrc.roc:
"
"   - the plugin manager, which puts the plugins on 'runtimepath'
"   - mapleader, which every plugin's <Leader> mappings are resolved against
"     as they are defined
"   - 'exrc' and 'secure', which decide whether a project's own vimrc is
"     trusted; too late to ask once one has been sourced
"
" Everything else — options, variables, mappings, colours, and the functions
" that used to live down at the bottom — is in vimrc.roc.

set nocompatible

" Space, before anything defines a <Leader> mapping.
let mapleader = " "

call plug#begin('~/.config/nvim/plugged')
Plug 'junegunn/fzf', { 'dir': '~/.fzf', 'do': './install --all' }
Plug 'Alok/notational-fzf-vim'
Plug 'elmcast/elm-vim'
Plug 'w0rp/ale'
Plug 'tpope/vim-fugitive'
Plug 'tpope/vim-unimpaired'
Plug 'idanarye/vim-merginal'
Plug 'hashivim/vim-terraform'
Plug 'posva/vim-vue'
Plug 'joshdick/onedark.vim'
Plug 'morhetz/gruvbox'
Plug 'pedrohdz/vim-yaml-folds'
Plug 'tmhedberg/SimpylFold'
Plug 'preservim/nerdtree'
Plug 'elzr/vim-json'
Plug 'pangloss/vim-javascript'
Plug 'jparise/vim-graphql'
Plug 'vim-test/vim-test'
Plug 'prabirshrestha/vim-lsp'
Plug 'mattn/vim-lsp-settings'
call plug#end()

" roc-vim itself, and the compiler it loads plugins with. With
" g:roc_embed_library set, vimrc.roc is compiled inside Vim at startup and
" recompiled whenever it is saved — there is nothing to build by hand.
set runtimepath^=~/src/roc-vim/vim
let g:roc_plugin_dir = '~/.vim/roc'
let g:roc_embed_library = '~/src/roc-vim/embed/libroc_vim_embed.so'

" Project-local vimrc files, without letting one run arbitrary commands.
set exrc
set secure
