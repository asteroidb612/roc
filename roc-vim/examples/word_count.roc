## Reading the buffer: keep a word count up to date.
##
## The count lands in `g:roc_words`, so a status line can show it:
##
##     set statusline+=\ %{get(g:,'roc_words',0)}w
##
## `:RocWords` says the count out loud.
app [main!] { vim: platform "../platform/main.roc" }

import vim.Vim
import vim.Value

main! : () => Try({}, _)
main! = || {
    # CursorHold fires when you stop typing for 'updatetime' milliseconds.
    Vim.subscribe!(["BufWritePost", "BufEnter", "CursorHold"])
    Vim.add_command!("RocWords")
    loop!()
}

loop! : () => Try({}, _)
loop! = ||
    match Vim.receive!() {
        Closed => Ok({})

        Notify(event) => {
            words = count_words!()?
            Vim.set_var!("g:roc_words", Value.Int(words))
            if event.name == "command:RocWords" {
                Vim.echo!("${I64.to_str(words)} words in this buffer")
            } else {
                {}
            }
            loop!()
        }

        _ => loop!()
    }

count_words! : () => Try(I64, _)
count_words! = || {
    lines = Vim.lines!()?
    var $total = 0
    for line in lines {
        for word in Str.split_on(line, " ") {
            $total = $total + if Str.is_empty(Str.trim(word)) 0 else 1
        }
    }
    Ok($total)
}
