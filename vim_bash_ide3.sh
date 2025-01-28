#!/bin/bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y vim git curl nodejs npm universal-ctags shellcheck shfmt


# Fetch the latest Gitleaks release
GITLEAKS_LATEST=$(curl -s https://api.github.com/repos/gitleaks/gitleaks/releases/latest | grep "tag_name" | cut -d '"' -f 4)
wget https://github.com/gitleaks/gitleaks/releases/download/${GITLEAKS_LATEST}/gitleaks_${GITLEAKS_LATEST}_linux_x64.tar.gz
tar -xzf gitleaks_${GITLEAKS_LATEST}_linux_x64.tar.gz
sudo mv gitleaks /usr/local/bin/
rm gitleaks_${GITLEAKS_LATEST}_linux_x64.tar.gz  # Clean up



curl -fLo ~/.vim/autoload/plug.vim --create-dirs \
    https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

cat > ~/.vimrc << 'EOL'
" Basic setup
set nocompatible
syntax enable
filetype plugin indent on
set number
set tabstop=4
set shiftwidth=4
set expandtab

" Change leader key to space
let mapleader = " "

" Plugin section
call plug#begin('~/.vim/plugged')

" Language Server Protocol
Plug 'neoclide/coc.nvim', {'branch': 'release'}

" Syntax highlighting
Plug 'vim-scripts/bash.vim'

" Function/variable list
Plug 'preservim/tagbar'

" File tree explorer
Plug 'preservim/nerdtree'

" Asynchronous lint engine
Plug 'dense-analysis/ale'

" Status line
Plug 'vim-airline/vim-airline'

call plug#end()

" Coc.nvim configuration
let g:coc_global_extensions = ['coc-sh']

" Tab completion
inoremap <silent><expr> <TAB>
      \ coc#pum#visible() ? coc#pum#next(1) :
      \ CheckBackspace() ? "\<Tab>" :
      \ coc#refresh()
inoremap <expr><S-TAB> coc#pum#visible() ? coc#pum#prev(1) : "\<C-h>"

function! CheckBackspace() abort
  let col = col('.') - 1
  return !col || getline('.')[col - 1]  =~# '\s'
endfunction

" Confirm completion
inoremap <expr> <cr> coc#pum#visible() ? coc#pum#confirm() : "\<CR>"

" Enhanced Tagbar configuration
let g:tagbar_type_sh = {
    \ 'ctagstype': 'sh',
    \ 'kinds': [
        \ 'f:functions:0:0',
        \ 'v:variables:0:0',
        \ 'c:constants:0:0'
    \ ],
    \ 'sort': 0
\ }

" ALE configuration
let g:ale_linters = {'sh': ['shellcheck']}
let g:ale_fixers = {'sh': ['shfmt']}
let g:ale_fix_on_save = 1
let g:ale_completion_enabled = 1
let g:ale_sh_shfmt_options = '-i 4 -ci'  " 4-space indentation

" Security patterns
let g:sensitive_data_patterns = [
    \ 'password\s*=\s*["'']',
    \ 'api_key\s*=\s*["'']',
    \ 'secret\s*=\s*["'']',
    \ 'token\s*=\s*["'']',
    \ 'private_key\s*=\s*["'']',
    \ 'BEGIN\s+(RSA|OPENSSH)\s+PRIVATE\s+KEY',
    \]

" Function to detect sensitive data
function! DetectSensitiveData()
    let l:matches = []
    for pattern in g:sensitive_data_patterns
        let l:matches += search(pattern, 'nw')
    endfor
    
    if len(l:matches) > 0
        echo "Warning: Potential sensitive data detected!"
        for match in l:matches
            echo "Line " . match . ": " . getline(match)
        endfor
    else
        echo "No sensitive data detected."
    endif
endfunction

" Gitleaks integration
function! RunGitleaks()
    let l:output = system('gitleaks detect --no-color --redact --no-git --verbose  --source ' . shellescape(expand('%')))
    new
    setlocal buftype=nofile bufhidden=wipe nobuflisted noswapfile
    put =l:output
    setlocal nomodifiable
endfunction

" Key mappings
nnoremap <silent> <F8> :TagbarClose<CR>:silent !ctags -R . &<CR>:TagbarOpen<CR>
nnoremap <silent> <F3> :NERDTreeToggle<CR>
nnoremap <silent> <F9> :ALEFix<CR>
nnoremap <leader>f :ALEFix<CR>
nnoremap <leader>sec :call DetectSensitiveData()<CR>:ALELint<CR>
nnoremap <leader>gl :call RunGitleaks()<CR>

" Auto-close NERDTree when it's the last window
autocmd BufEnter * if tabpagenr('$') == 1 && winnr('$') == 1 && exists('b:NERDTree') && b:NERDTree.isTabTree() | quit | endif

" Auto-generate tags on save
autocmd BufWritePost *.sh silent! !ctags -R --exclude=.git --exclude=node_modules --exclude=venv --exclude=dist --exclude=build . &

" Highlight sensitive data
highlight SensitiveData ctermbg=red guibg=red
for pattern in g:sensitive_data_patterns
    execute 'match SensitiveData /' . pattern . '/'
endfor
EOL

cat > ~/.ctags << 'EOL'
--langdef=sh
--langmap=sh:.sh.bash.in
--regex-sh=/^[ \t]*(function[ \t]+)?([a-zA-Z0-9_]+)[ \t]*\(\)/\2/f,function/
--regex-sh=/^[ \t]*([A-Z_][A-Z0-9_]+)=/\1/c,constant/
--regex-sh=/^[ \t]*(declare|local|readonly)[ \t]+(-[a-zA-Z]+[ \t]+)*([a-zA-Z0-9_]+)=/\3/v,variable/
--regex-sh=/^[ \t]*([a-zA-Z0-9_]+)=[^\(]\{0,1\}$/\1/v,variable/
EOL
vim +'PlugInstall --sync' +qa
vim +'CocInstall coc-sh' +qa

sudo npm install -g bash-language-server
ctags -R --exclude=.git --exclude=node_modules --exclude=venv .

echo "Setup complete! Now you can:"
echo "1. Open a bash script: vim script.sh"
echo "2. Press F3 for file explorer (right)"
echo "3. Press F8 for function/variable list (left)"
echo "4. Press F9 to format code"
echo "5. Use <leader>sec to detect sensitive data"
echo "6. Use <leader>gl to run gitleaks"
echo "7. Code will auto-format on save"
echo ""
echo "Note: Tags are automatically updated on file save"
echo "Manual tag regeneration: ctags -R ."
