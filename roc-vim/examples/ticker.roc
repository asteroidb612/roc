## Working between events, and answering Vim's questions.
##
## This plugin wakes up once a second whether or not anything happened, and
## keeps `g:roc_uptime` current. Vimscript can also ask it a question and wait
## for the answer:
##
##     :echo roc#ask('ticker', 'uptime', 0)
app [main!] { vim: platform "../platform/main.roc" }

import vim.Vim
import vim.Value

main! : () => Try({}, _)
main! = || {
    Vim.add_command!("RocUptime")
    loop!(0)
}

loop! : I64 => Try({}, _)
loop! = |seconds|
    # Waiting with a timeout is what lets a plugin do something on its own
    # schedule. Without one, `Vim.receive!()` waits as long as it takes.
    match Vim.receive_timeout!(1000) {
        Closed => Ok({})

        Timeout => {
            Vim.set_var!("g:roc_uptime", Value.Int(seconds + 1))
            loop!(seconds + 1)
        }

        Notify(event) =>
            if event.reply_to != 0 {
                # Vim is blocked in roc#ask() until this answer arrives.
                Vim.reply!(event.reply_to, Value.Int(seconds))
                loop!(seconds)
            } else {
                Vim.echo!("roc-vim has been running for ${I64.to_str(seconds)}s")
                loop!(seconds)
            }

        _ => loop!(seconds)
    }
