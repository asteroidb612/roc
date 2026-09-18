## The in-process version of the hello plugin.
##
## Vim owns the loop, so a plugin is a model plus a handler: `init!` builds the
## first model, `handle!` gets the model and whatever just happened and returns
## the next one.
app [Model, plugin] { vim: platform "../platform-inprocess/main.roc" }

import vim.Vim

## How many times a file has been written this session.
Model : I64

plugin = { init!, handle! }

init! : () => Try(Model, _)
init! = || {
    Vim.subscribe!(["BufWritePost"])
    # Registered last, so that :RocHello existing means the rest is ready too.
    Vim.add_command!("RocHello")
    Ok(0)
}

handle! : Model, Vim.Event => Try(Model, _)
handle! = |writes, event|
    if event.name == "command:RocHello" {
        file = Vim.buffer_name!()?
        Vim.echom!("hello from Roc, inside Vim! you are editing: ${file}")
        Ok(writes)
    } else if event.name == "BufWritePost" {
        total = writes + 1
        Vim.echom!("roc-vim has seen ${I64.to_str(total)} write(s)")
        Ok(total)
    } else {
        Ok(writes)
    }
