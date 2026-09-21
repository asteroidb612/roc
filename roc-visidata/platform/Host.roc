## The effects a plugin loaded into VisiData's own process can reach for.
##
## Every one of these is a direct call into Python through the function table
## the `visidata_roc` package hands the engine when it loads a plugin: no
## subprocess, no socket.
##
## There are only four, because Python's own eval/exec split is all the
## leverage needed — `VisiData.roc` builds the whole API on top of them.
Host :: [].{

    ## Execute a Python statement in VisiData's globals. Fire and forget.
    exec! : Str => {}

    ## Evaluate a Python expression. Returns `{"ok": <value>}` or
    ## `{"err": "<reason>"}` as JSON text.
    eval! : Str => Str

    ## Show a message: `True` shows it as an error, and logs it where VisiData's
    ## error list will find it.
    message! : Str, Bool => {}

    ## Set the answer this event returns to whoever dispatched it.
    reply! : Str => {}

    ## The handle VisiData loaded this plugin under.
    id! : () => Str
}
