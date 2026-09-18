## The smallest useful plugin: a command and an event.
##
## `:RocHello` greets you, and every write gets counted. The count lives in this
## program, not in Vim, because the plugin is a process that keeps running for
## as long as Vim does.
app [main!] { vim: platform "../platform/main.roc" }

import vim.Vim

main! : () => Try({}, _)
main! = || {
    Vim.subscribe!(["BufWritePost"])
    Vim.add_command!("RocHello")
    Vim.log!("hello plugin started")
    loop!(0)
}

loop! : I64 => Try({}, _)
loop! = |writes|
    match Vim.receive!() {
        # Vim is exiting, so this plugin is done.
        Closed => Ok({})

        Notify(event) =>
            if event.name == "command:RocHello" {
                file = Vim.buffer_name!()?
                Vim.echom!("hello from Roc! you are editing: ${file}")
                loop!(writes)
            } else if event.name == "BufWritePost" {
                total = writes + 1
                Vim.echom!("roc-vim has seen ${I64.to_str(total)} write(s)")
                loop!(total)
            } else {
                loop!(writes)
            }

        _ => loop!(writes)
    }
