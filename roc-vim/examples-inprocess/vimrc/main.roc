## A working vimrc, rewritten as a Roc plugin.
##
## Everything a vimrc does that is really *configuration* — options, variables,
## mappings, colours — is data here: a list you can read top to bottom. And
## everything it does that is really *a program* — build a GitHub URL, run the
## code block under the cursor, keep a linter count in the status line — is a
## Roc function with types on it, instead of a Vimscript function that fails
## silently when a variable is empty.
##
## What still has to live in a `vimrc` file (see `vimrc.vim` next to this one):
## the plugin manager, `mapleader`, and `set exrc`/`set secure`. Those have to
## run before Vim loads any plugin, and this is a plugin.
##
## This one is a directory rather than a single file: the part of it worth
## testing on its own (which fenced block does the cursor mean?) lives in
## Notebook.roc, which has no platform in it and so can be run with
## `roc test`. Vim treats the directory as one plugin either way.
##
##     :RocGithubUrl       yank a github.com link to the line under the cursor
##     :RocRunBlock        run the ``` block at or above the cursor, insert output
##     :RocVsCode          open the current file and line in VS Code
##     :RocYazi            open yazi beside the current file
##     :RocCalendar        this week's calendar in a terminal split
##     :RocHighlightNotes  re-apply the markdown note highlights
app [Model, plugin] { vim: platform "../../platform-inprocess/main.roc" }

import vim.Vim
import vim.Value
import Notebook

# =============================================================================
# Where things live
#
# The original kept these as Vim variables (`let notes = "..."`). As Roc values
# a typo is a compile error rather than an empty string at runtime.
# =============================================================================

notes_dir : Str
notes_dir = "~/BitTorrent Sync/Laptops/notes"

iio_dir : Str
iio_dir = "~/iio"

mindful_dir : Str
mindful_dir = "~/mindful"

# =============================================================================
# The plugin
# =============================================================================

## What the plugin remembers between events.
Model : {
    ## How many fenced code blocks `:RocRunBlock` has run this session. It
    ## numbers the output it writes, so a notebook read later says which run
    ## produced what.
    blocks_run : I64,
}

plugin = { init!, handle! }

init! : () => Try(Model, _)
init! = || {
    apply_options!()
    apply_variables!()
    apply_colours!()
    apply_mappings!()

    # BufWinEnter, not BufRead: the note highlights belong to a *window*, so
    # they have to be re-applied whenever a window shows a different buffer.
    # That is the bug behind the original's "running on upsert-cron-tasks.js".
    Vim.subscribe!(["BufRead", "BufNewFile", "BufWinEnter", "FileType", "User ALELintPost"])

    for name in commands {
        Vim.add_command!(name)
    }
    Ok({ blocks_run: 0 })
}

handle! : Model, Vim.Event => Try(Model, _)
handle! = |model, event|
    if event.name == "command:RocGithubUrl" {
        github_url!()?
        Ok(model)
    } else if event.name == "command:RocRunBlock" {
        run = model.blocks_run + 1
        run_block!(run)?
        Ok({ blocks_run: run })
    } else if event.name == "command:RocVsCode" {
        open_in_vscode!()?
        Ok(model)
    } else if event.name == "command:RocYazi" {
        open_in_yazi!()?
        Ok(model)
    } else if event.name == "command:RocCalendar" {
        show_calendar!()?
        Ok(model)
    } else if event.name == "command:RocHighlightNotes" {
        highlight_notes!()?
        Ok(model)
    } else if event.name == "BufRead" or event.name == "BufNewFile" {
        on_file_opened!()?
        Ok(model)
    } else if event.name == "BufWinEnter" {
        highlight_notes!()?
        Ok(model)
    } else if event.name == "FileType" {
        on_filetype!()?
        Ok(model)
    } else if event.name == "User" {
        # The only User event this plugin subscribes to is ALELintPost.
        refresh_ale_status!()?
        Ok(model)
    } else {
        Ok(model)
    }

## Every `:Command` this plugin defines. Each one arrives back in `handle!` as
## a `"command:<name>"` event.
commands : List(Str)
commands = [
    "RocGithubUrl",
    "RocRunBlock",
    "RocVsCode",
    "RocYazi",
    "RocCalendar",
    "RocHighlightNotes",
]

# =============================================================================
# Options
# =============================================================================

options : List(Str)
options = [
    "expandtab",
    "number",
    "shiftwidth=2",
    "softtabstop=2",
    "termguicolors",
    "clipboard=unnamed",
    "foldcolumn=2",
    "signcolumn=yes",
    # No files left behind beside the one being edited.
    "nobackup",
    "nowritebackup",
    "noswapfile",
    "mouse=a",
    # Show a tab character rather than leaving it to be guessed at.
    "list",
    "listchars=tab:>-",
    # `gf` on a path out of `git diff` should open a/foo.js as foo.js.
    "includeexpr=substitute(v:fname,'^[ab]/','','g')",
]

apply_options! : () => {}
apply_options! = || {
    for option in options {
        Vim.set!(option)
    }
    # The linter counts are computed on ALELintPost and parked in a variable,
    # so redrawing the status line costs a variable read rather than a call
    # into this plugin on every cursor move.
    Vim.set!("statusline=%f\\ %m%r%h%w")
    Vim.set!("statusline+=%{get(g:,'roc_ale_status','')}")
    Vim.set!("statusline+=%=%l/%L\\ col\\ %c")
}

# =============================================================================
# Variables other plugins read
# =============================================================================

## Where notational-fzf-vim searches.
search_paths : List(Str)
search_paths = [
    notes_dir,
    "./",
    "${iio_dir}/server",
    "${iio_dir}/client",
    "${iio_dir}/worker",
    "${iio_dir}/*.js",
    "${iio_dir}/*.json",
    "${iio_dir}/tools/cli",
]

## Directories NERDTree should not show: the ones macOS puts in `$HOME`.
nerdtree_ignore : List(Str)
nerdtree_ignore = [
    "Applications",
    "bin",
    "Desktop",
    "Documents",
    "Downloads",
    "Library",
    "Movies",
    "Music",
    "Pictures",
    "Public",
]

apply_variables! : () => {}
apply_variables! = || {
    Vim.set_var!("g:markdown_folding", Value.Int(1))

    Vim.set_var!("g:nv_expect_keys", texts(["ctrl-g", "ctrl-f"]))
    Vim.set_var!("g:nv_search_paths", texts(search_paths))
    Vim.set_var!("g:nv_show_preview", Value.Int(0))
    Vim.set_var!("g:nv_use_short_pathnames", Value.Int(0))

    Vim.set_var!("g:ale_linters", Value.Object([]))
    Vim.set_var!("g:ale_lint_on_text_changed", Value.Text("never"))
    Vim.set_var!("g:ale_fix_on_save", Value.Int(1))
    Vim.set_var!("g:ale_linters_explicit", Value.Int(1))
    Vim.set_var!("g:ale_pattern_options", ale_pattern_options)

    Vim.set_var!("g:NERDTreeMapActivateNode", Value.Text("<space>"))
    Vim.set_var!("g:NERDTreeUseTCD", Value.Int(1))
    Vim.set_var!("g:NERDTreeIgnore", texts(nerdtree_ignore))

    Vim.set_var!("g:test#javascript#runner", Value.Text("mocha"))

    Vim.ex!("silent! source ~/.config/nvim/nv_quicklist.vim")
}

# =============================================================================
# ALE: which linter and which fixer, per file type
#
# The original was one `g:ale_pattern_options` dictionary held together by
# backslash continuations. Here it is a list of records, so a missing comma is
# a compile error and the regex is built rather than written out eight times.
# =============================================================================

## `suffix` is the file extension; an empty `linters` or `fixers` leaves that
## key out of the dictionary entirely, which is how ALE reads "no opinion".
AleRule : {
    suffix : Str,
    linters : List(Str),
    fixers : List(Str),
    fix_on_save : Bool,
}

ale_rules : List(AleRule)
ale_rules = [
    { suffix: "rs", linters: ["cargo"], fixers: ["rustfmt"], fix_on_save: True },
    { suffix: "css", linters: [], fixers: ["prettier"], fix_on_save: True },
    { suffix: "py", linters: [], fixers: ["black"], fix_on_save: True },
    { suffix: "mojo", linters: [], fixers: ["black"], fix_on_save: True },
    { suffix: "js", linters: ["eslint", "tsserver"], fixers: ["eslint"], fix_on_save: True },
    { suffix: "ts", linters: ["eslint", "tsserver"], fixers: ["eslint"], fix_on_save: True },
    { suffix: "mjs", linters: ["eslint", "tsserver"], fixers: ["eslint"], fix_on_save: True },
    { suffix: "tsx", linters: ["eslint", "tsserver"], fixers: ["eslint"], fix_on_save: True },
    { suffix: "elm", linters: [], fixers: ["elm-format"], fix_on_save: True },
    { suffix: "sql", linters: [], fixers: ["pgformatter"], fix_on_save: True },
    # Formatting HTML with eslint on every write was more trouble than it was
    # worth, so this one only runs when asked.
    { suffix: "html", linters: [], fixers: ["eslint"], fix_on_save: False },
]

ale_pattern_options : Value
ale_pattern_options = {
    var $rules = []
    for rule in ale_rules {
        var $options = []
        if List.len(rule.linters) > 0 {
            $options = $options.append(("ale_linters", texts(rule.linters)))
        } else {
            {}
        }
        if List.len(rule.fixers) > 0 {
            $options = $options.append(("ale_fixers", texts(rule.fixers)))
        } else {
            {}
        }
        if rule.fix_on_save {
            $options = $options.append(("ale_fix_on_save", Value.Int(1)))
        } else {
            {}
        }
        $rules = $rules.append((".*\\.${rule.suffix}$", Value.Object($options)))
    }
    Value.Object($rules)
}

# =============================================================================
# Colours
# =============================================================================

apply_colours! : () => {}
apply_colours! = || {
    # gruvbox reads its contrast setting as it loads, so this has to be set
    # before `:colorscheme`, not after it as the original vimrc did.
    Vim.set_var!("g:gruvbox_contrast_dark", Value.Text("hard"))
    Vim.set!("background=dark")
    Vim.ex!("silent! colorscheme gruvbox")
    # Comments brighter than code, not dimmer.
    Vim.ex!("highlight Comment ctermfg=226 guifg=#ffff00 cterm=bold gui=bold")
}

# =============================================================================
# Mappings
#
# `<Leader>` is a space; `mapleader` is set in vimrc.vim, because plugins
# loaded before this one read it too.
# =============================================================================

Mapping : { command : Str, lhs : Str, rhs : Str }

mappings : List(Mapping)
mappings = [
    # --- searching and moving around -------------------------------------
    { command: "nnoremap", lhs: "<Leader>.", rhs: ":NV<CR>" },
    # `:CW` is `:NV` on the word under the cursor. It comes from a patched
    # copy of notational-fzf-vim; `cw` in this directory is the backup.
    { command: "nnoremap", lhs: "<Leader>8", rhs: ":CW<CR>" },
    { command: "nnoremap", lhs: "<Leader>u", rhs: ":ls<CR>:b<Space>" },
    { command: "nnoremap", lhs: "gn", rhs: "<C-w><C-f><C-w>L" },

    # --- config files -----------------------------------------------------
    { command: "nnoremap", lhs: "<Leader>,", rhs: ":tabedit ~/.config/nvim/init.vim<CR>" },
    { command: "nnoremap", lhs: "<Leader><Leader>,", rhs: ":tabedit ~/.zshrc<CR>" },

    # --- windows and terminals -------------------------------------------
    { command: "nnoremap", lhs: "<Leader>n", rhs: ":tabnew<CR>" },
    { command: "nnoremap", lhs: "<Leader><Leader>n", rhs: ":vnew<CR>" },
    { command: "nnoremap", lhs: "<Leader>t", rhs: ":terminal<CR>Go" },
    # Open every listed buffer in a window: fzf, mark many, then this.
    { command: "nnoremap", lhs: "<leader><c-t>", rhs: ":sball<CR>" },

    # --- git --------------------------------------------------------------
    { command: "nnoremap", lhs: "<Leader>g", rhs: ":tab Git<CR>" },
    # Deliberately no <CR>: it leaves the pickaxe waiting for a pattern.
    { command: "nnoremap", lhs: "<Leader><Leader>g", rhs: ":tab Git log -G" },
    { command: "nnoremap", lhs: "<Leader>gl", rhs: ":tabnew<CR>:terminal<CR>a branches-by-recency.sh<CR>" },
    { command: "nnoremap", lhs: "<Leader>d", rhs: ":Git commit --amend --allow-empty<CR>" },
    { command: "nnoremap", lhs: "<Leader><Leader>d", rhs: ":Git commit --allow-empty<CR>" },
    { command: "nnoremap", lhs: "<leader>r", rhs: ":tab Git rebase -i master<CR>" },
    { command: "nnoremap", lhs: "<leader>l", rhs: ":tab Git reflog<CR>" },
    { command: "nnoremap", lhs: "<leader><leader>l", rhs: ":tab Git log --stat master..head<CR>" },
    { command: "nnoremap", lhs: "<leader><leader><leader>l", rhs: ":tab Git log --stat main..head<CR>" },
    # What this branch changed, commit by commit...
    { command: "nnoremap", lhs: "<leader>f", rhs: ":tab Git log master..head -p --pretty=full<CR>" },
    # ...and as one diff, in a scratch file so it can be navigated.
    { command: "nnoremap", lhs: "<leader><leader>f", rhs: ":r!git diff `git branch -l main master --format \\%\\(refname:short\\)`<CR>gg :w! .tmp_diff.diff<CR><C-w> o<CR>" },

    # --- ALE --------------------------------------------------------------
    # [ and ] move between problems; the unimpaired defaults move it along.
    { command: "nnoremap", lhs: "[", rhs: ":ALEPrevious<CR>" },
    { command: "nnoremap", lhs: "]", rhs: ":ALENext<CR>" },
    { command: "nnoremap", lhs: "<leader>q", rhs: ":ALEToggleBuffer<CR>" },
    # Same thing under a second key: for writing dumb code undisturbed.
    { command: "nnoremap", lhs: "<leader>a", rhs: ":ALEToggleBuffer<CR>" },
    { command: "nnoremap", lhs: "<Leader>]", rhs: ":lnext<CR>" },
    { command: "nnoremap", lhs: "<Leader>[", rhs: ":lprevious<CR>" },

    # --- the file tree ----------------------------------------------------
    { command: "nnoremap", lhs: "<leader>w", rhs: ":NERDTreeFind<CR>" },
    { command: "nnoremap", lhs: "<leader><leader>w", rhs: ":NERDTree<CR>" },

    # --- folding ----------------------------------------------------------
    { command: "nnoremap", lhs: "<Leader>z", rhs: "zfgg" },
    { command: "nnoremap", lhs: "<leader>i", rhs: ":set foldmethod=indent<CR>" },
    # So someone reading over your shoulder can click to unfold.
    { command: "nnoremap", lhs: "<2-LeftMouse>", rhs: "za" },

    # --- tabular data, rendered documents ---------------------------------
    { command: "nnoremap", lhs: "<Leader>v", rhs: "ggyG<C-o>:tabnew<CR>:terminal<CR>apbpaste \\| vd<CR>" },
    { command: "nnoremap", lhs: "<Leader>p", rhs: "ggyG<C-o>:tabnew<CR>:terminal<CR>apbpaste \\| psql sql_repl_server --csv \\| vd<CR>" },
    { command: "nnoremap", lhs: "<leader>e", rhs: ":!pandoc % --output rendered.pdf<CR>:!open rendered.pdf<CR>" },

    # --- the poor man's notebook: one line of shell, output below it ------
    { command: "nnoremap", lhs: "<leader>b", rhs: ":put =strftime('<Output from running ^^^ on %c >')<CR>:call setreg('a', 'read! ')<CR>k0\"Ay$j:@a<CR><CR>:normal! o</Output end><ESC>" },

    # --- notes and scratch ------------------------------------------------
    { command: "nnoremap", lhs: "<Leader>s", rhs: ":cd ${mindful_dir}<CR>:e ${mindful_dir}/<CR>" },
    { command: "nnoremap", lhs: "<Leader><Leader>r", rhs: ":%s/[^a-zA-Z0-9_$]/ /g<CR>" },

    # --- a local model, and a coding agent talking to it ------------------
    { command: "nnoremap", lhs: "<Leader>o", rhs: ":vsplit<CR>:terminal<CR>aollama serve<CR><C-\\><C-n><C-w>l:terminal<CR>aOLLAMA_API_BASE=http://127.0.0.1:11434 aider --model ollama_chat/deepseek-r1:8b<CR>" },

    # --- search for what is selected --------------------------------------
    { command: "vnoremap", lhs: "//", rhs: "y/\\V<C-R>=escape(@\",'/\\')<CR><CR>" },

    # --- readline keys in a terminal --------------------------------------
    # <c-n> is left alone: it is how you get out of terminal-insert mode.
    { command: "tmap", lhs: "<c-b>", rhs: "<LEFT>" },
    { command: "tmap", lhs: "<c-f>", rhs: "<RIGHT>" },
    { command: "tmap", lhs: "<c-p>", rhs: "<UP>" },

    # --- the things this plugin implements itself -------------------------
    { command: "nnoremap", lhs: "<Leader>h", rhs: ":RocGithubUrl<CR>" },
    { command: "nnoremap", lhs: "<Leader>c", rhs: ":RocVsCode<CR>" },
    { command: "nnoremap", lhs: "<Leader>y", rhs: ":RocYazi<CR>" },
    # The original mapped <leader>m twice — `:make` first, then RunLines. The
    # second won, so `:make` never had a key; this keeps that behaviour.
    { command: "nnoremap", lhs: "<leader>m", rhs: ":RocRunBlock<CR>" },
]

apply_mappings! : () => {}
apply_mappings! = || {
    for mapping in mappings {
        Vim.ex!("${mapping.command} ${mapping.lhs} ${mapping.rhs}")
    }
}

# =============================================================================
# A link to the line under the cursor
# =============================================================================

github_url! : () => Try({}, _)
github_url! = || {
    remote = Str.trim(Vim.system!("git config --get remote.origin.url")?)
    if remote == "" {
        Vim.error!("no git remote here — is Vim's working directory inside the repo?")
        Ok({})
    } else {
        ref = Str.trim(Vim.system!("git rev-parse HEAD")?)
        file = Vim.eval_str!("expand('%')")?
        row = Vim.eval_int!("line('.')")?
        url = "${web_url(remote)}/blob/${ref}/${file}?plain=1#L${I64.to_str(row)}"
        register = clipboard_register!()?
        _ = Vim.call!("setreg", [Value.Text(register), Value.Text(url)])
        Vim.echom!("GitHub URL yanked to register ${register}: ${url}")
        Ok({})
    }
}

## `+` on a Vim that has a clipboard, and the unnamed register on one that does
## not — where `setreg("+", ...)` would fail and the link would be lost.
clipboard_register! : () => Try(Str, _)
clipboard_register! = || {
    has_clipboard = Vim.eval_int!("has('clipboard')")?
    if has_clipboard == 1 {
        Ok("+")
    } else {
        Ok("\"")
    }
}

## Turn whatever `git config remote.origin.url` said into something a browser
## can open.
web_url : Str -> Str
web_url = |remote| {
    over_https =
        if Str.starts_with(remote, "git@github.com:") {
            "https://github.com/${Str.drop_prefix(remote, "git@github.com:")}"
        } else {
            remote
        }
    # Only a trailing ".git" is the extension. The original stripped the first
    # ".git" anywhere in the URL, which mangles a repo called "foo.github".
    drop_suffix(over_https, ".git")
}

## `text` without `suffix` on the end, if it was there at all.
##
## `Str.drop_last_bytes` says this in one call, but it crashes the interpreter
## these plugins run under, so this counts bytes itself.
drop_suffix : Str, Str -> Str
drop_suffix = |text, suffix|
    if Str.ends_with(text, suffix) {
        keep = Str.count_utf8_bytes(text) - Str.count_utf8_bytes(suffix)
        var $kept = []
        var $index = 0
        for byte in Str.to_utf8(text) {
            if $index < keep {
                $kept = $kept.append(byte)
            } else {
                {}
            }
            $index = $index + 1
        }
        match Str.from_utf8($kept) {
            Ok(shorter) => shorter
            Err(_) => text
        }
    } else {
        text
    }

# =============================================================================
# The notebook: run the fenced block at the cursor, write the output below it
#
# Which block the cursor means is Notebook.find_block, which is pure and has
# its own tests (`roc test Notebook.roc`). What is left here is the Vim half.
# =============================================================================

run_block! : I64 => Try({}, _)
run_block! = |run| {
    lines = Vim.lines!()?
    here = Vim.eval_int!("line('.')")?
    match Notebook.find_block(lines, here) {
        Err(NoBlock) => {
            Vim.error!("no ``` block at or above the cursor")
            Ok({})
        }
        Ok(block) => {
            output = Vim.system!(Str.join_with(block.code, "\n"))?
            stamp = Vim.eval_str!("strftime('%c')")?
            header = "# <output from the block above, run ${I64.to_str(run)}, ${stamp}>"
            var $insert = ["", "```", header]
            for line in Str.split_on(Str.trim_end(output), "\n") {
                $insert = $insert.append(line)
            }
            # The original vimrc left this fence open, so a second run nested
            # inside the first one's output.
            $insert = $insert.append("```")
            Vim.append_lines!(block.close, $insert)
            Ok({})
        }
    }
}

# =============================================================================
# Handing the current file to another program
# =============================================================================

open_in_vscode! : () => Try({}, _)
open_in_vscode! = || {
    place = current_place!()?
    target = shell_quote("${place.file}:${I64.to_str(place.row)}")
    _ = Vim.system!("code . -g ${target}")?
    Ok({})
}

open_in_yazi! : () => Try({}, _)
open_in_yazi! = || {
    place = current_place!()?
    # `:terminal` runs the program directly rather than through a shell, so the
    # `y` alias from the original is spelled out here.
    path = shell_quote(place.file)
    Vim.ex!("vertical terminal yazi ${path}")
    Ok({})
}

show_calendar! : () => Try({}, _)
show_calendar! = || {
    place = current_place!()?
    if place.file == "" {
        Vim.ex!("split")
        Vim.ex!("terminal ${calendar_command}")
        Ok({})
    } else {
        Vim.echo!("this window has a file in it — :RocCalendar wants an empty one")
        Ok({})
    }
}

## `#` is the alternate file on an Ex command line, so each one is escaped.
calendar_command : Str
calendar_command =
    "gcalcli calw"
    |> Str.concat(" --calendar 'Life\\#green'")
    |> Str.concat(" --calendar 'Team\\#yellow'")
    |> Str.concat(" --calendar 'drew@interviewing.io\\#blue'")
    |> Str.concat(" --calendar \"Today's the Day\\#red\"")

current_place! : () => Try({ file : Str, row : I64 }, _)
current_place! = || {
    file = Vim.eval_str!("expand('%')")?
    row = Vim.eval_int!("line('.')")?
    Ok({ file, row })
}

# =============================================================================
# Markdown notes: what needs attention, and what has grown too long
# =============================================================================

Highlight : { group : Str, pattern : Str }

note_highlights : List(Highlight)
note_highlights = [
    # Something still to do.
    { group: "CursorLineNr", pattern: "- \\[ \\].*" },
    # The problem currently being worked on.
    { group: "CursorLineNr", pattern: "\\[P\\*\\].*" },
    # Past line 45 a note has stopped being one note; dim it as a hint to split.
    { group: "EndOfBuffer", pattern: "\\%>45l.*" },
]

highlight_notes! : () => Try({}, _)
highlight_notes! = || {
    # Matches belong to the window, so they are cleared on the way in whatever
    # the buffer is, and only put back for a Markdown one.
    _ = Vim.call!("clearmatches", [])
    name = Vim.buffer_name!()?
    filetype = Vim.filetype!()?
    if filetype == "markdown" or Str.ends_with(name, ".md") {
        for highlight in note_highlights {
            _ = Vim.call!("matchadd", [Value.Text(highlight.group), Value.Text(highlight.pattern)])
        }
        Ok({})
    } else {
        Ok({})
    }
}

# =============================================================================
# Per-file-type settings
# =============================================================================

on_file_opened! : () => Try({}, _)
on_file_opened! = || {
    name = Vim.buffer_name!()?
    if Str.ends_with(name, ".roc") {
        # Roc has no syntax file yet and Ruby's is close enough to read by.
        # `setlocal`, so it does not follow you into the next buffer.
        Vim.ex!("setlocal syntax=ruby")
        Ok({})
    } else {
        Ok({})
    }
}

on_filetype! : () => Try({}, _)
on_filetype! = || {
    filetype = Vim.filetype!()?
    # One place for both, rather than two augroups of the same name where the
    # second one's `au!` quietly threw away the first.
    if filetype == "typescript" or filetype == "typescriptreact" {
        Vim.ex!("setlocal foldmethod=syntax")
        Ok({})
    } else {
        Ok({})
    }
}

# =============================================================================
# The linter count in the status line
# =============================================================================

refresh_ale_status! : () => Try({}, _)
refresh_ale_status! = || {
    installed = Vim.eval_int!("exists('*ale#statusline#Count')")?
    if installed == 0 {
        Ok({})
    } else {
        counts = Vim.eval!("ale#statusline#Count(bufnr(''))")?
        errors = count_of(counts, "error") + count_of(counts, "style_error")
        warnings = count_of(counts, "warning") + count_of(counts, "style_warning")
        status =
            if errors == 0 and warnings == 0 {
                ""
            } else {
                " E:${I64.to_str(errors)} W:${I64.to_str(warnings)} "
            }
        Vim.set_var!("g:roc_ale_status", Value.Text(status))
        Ok({})
    }
}

count_of : Value, Str -> I64
count_of = |counts, name| Value.int_or(Value.field_or_null(counts, name), 0)

# =============================================================================
# Small helpers
# =============================================================================

## A list of strings, as something Vim can be handed.
texts : List(Str) -> Value
texts = |items| {
    var $values = []
    for item in items {
        $values = $values.append(Value.Text(item))
    }
    Value.Array($values)
}

## Wrap a word so the shell takes it literally, spaces and quotes and all.
shell_quote : Str -> Str
shell_quote = |text| "'${Str.replace_each(text, "'", "'\\''")}'"
