" set leader key
let g:mapleader = "<Space>"

"Key-bindings
let mapleader=" "

syntax enable                           " Enables syntax highlighing
set hidden                              " Required to keep multiple buffers open multiple buffers
set noswapfile                          " Open new buffers without creating a swap file for it
set nowrap                              " Display long lines as just one line
set encoding=utf-8                      " The encoding displayed
set pumheight=10                        " Makes popup menu smaller
set fileencoding=utf-8                  " The encoding written to file
set ruler              			            " Show the cursor position all the time
set cmdheight=2                         " More space for displaying messages
set iskeyword+=-                      	" treat dash separated words as a word text object"
set mouse=a                             " Enable your mouse
set splitbelow                          " Horizontal splits will automatically be below
set splitright                          " Vertical splits will automatically be to the right
set t_Co=256                            " Support 256 colors
set conceallevel=0                      " So that I can see `` in markdown files
set tabstop=4                           " Insert 4 spaces for a tab
set softtabstop=4
set shiftwidth=4                        " Change the number of space characters inserted for indentation
set nohlsearch                          " Don't hightlight searched items forever
set smarttab                            " Makes tabbing smarter will realize you have 2 vs 4
set expandtab                           " Converts tabs to spaces
set smartindent                         " Makes indenting se/aart
set autoindent                          " Good auto indent
set laststatus=2                        " Always display the status line
set number                              " Line numbers
set relativenumber                      " Add relative lines
set cursorline                          " Enable highlighting of the current line
set background=dark                     " tell vim what the background color looks like
set showtabline=4                       " Always show tabs
set noshowmode                          " We don't need to see things like -- INSERT -- anymore
set nobackup                            " This is recommended by coc
set nowritebackup                       " This is recommended by coc
set updatetime=300                      " Faster completion
set timeoutlen=500                      " By default timeoutlen is 1000 ms
set formatoptions-=cro                  " Stop newline continution of comments
set clipboard=unnamedplus               " Copy paste between vim and everything else
set scrolloff=8                         " Add space at the bottom
set modifiable
set completeopt=menu,noinsert,noselect,preview
set wildmenu
set wildmode=list:longest,full
set splitright

" Switch windows using ctrl and vim keys
nnoremap <C-H> <C-W>h
nnoremap <C-J> <C-W>j
nnoremap <C-K> <C-W>k
nnoremap <C-L> <C-W>l

" Move between buffers
nnoremap <C-PageUp> :bn<CR>
nnoremap <C-PageDown> :bp<CR>

" Split to the right
nnoremap <silent> <leader>vs :vsplit<CR>

" Split below
nnoremap <silent> <leader>hs :split<CR>

" Close splits
nnoremap <silent> <leader>cs :on<CR>

" Print the path to the current buffer
nnoremap <leader>p :!echo %:p<CR>

" Resize splits
nnoremap <silent> <A-h> :vertical resize -5<CR>
nnoremap <silent> <A-l> :vertical resize +5<CR>

" Move a line up or down with alt j and k
nmap <A-j> mz:m+<CR>`z
nmap <A-k> mz:m-2<CR>`z

" Make Y do what you would expect
nnoremap Y y$

" Keep cursor centered
nnoremap n nzzzv
nnoremap N Nzzzv

" Add relative lines jumps to the jumps List
nnoremap <expr> k (v:count > 5 ? "m'" . v:count : "") . 'k'
nnoremap <expr> j (v:count > 5 ? "m'" . v:count : "") . 'j'
