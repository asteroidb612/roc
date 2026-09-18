## The effects a plugin loaded into Vim's own process can reach for.
##
## Every one of these is a direct call into Vim through the function table
## `if_roc.c` hands the plugin when it loads: no channel, no waiting.
Host :: [].{

    ## Run an Ex command, the way `:` does.
    ex! : Str => {}

    ## Evaluate a Vim expression. Returns `{"ok": <value>}` or
    ## `{"err": "<reason>"}` as JSON text.
    eval! : Str => Str

    ## Show a message; `True` shows it as an error.
    message! : Str, Bool => {}

    ## Set the answer this event returns to whoever called `roc_event()`.
    reply! : Str => {}

    ## The handle Vim loaded this plugin under.
    id! : () => Str
}
