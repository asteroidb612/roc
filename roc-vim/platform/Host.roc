## Raw hosted effects. Plugins use the `Vim` module instead of this one;
## everything here speaks in JSON text so that the C host stays small.
Host :: [].{

    ## Run an Ex command in Vim. Fire and forget: Vim runs it when it next
    ## checks the channel.
    ex! : Str => {}

    ## Feed keys to Vim as if typed in normal mode.
    normal! : Str => {}

    ## Send a raw, already-encoded JSON message on the channel.
    send! : Str => {}

    ## Evaluate a Vim expression and wait for the answer.
    ## Returns `{"ok": <value>}` or `{"err": "<reason>"}` as JSON text.
    eval! : Str => Str

    ## Call a Vim function with a JSON array of arguments and wait for the
    ## answer. Returns the same envelope shape as `eval!`.
    call! : Str, Str => Str

    ## Answer a request Vim is blocked on, with already-encoded JSON text.
    reply! : I64, Str => {}

    ## Wait for the next message from Vim. A negative timeout blocks forever.
    ## Returns `{"kind": "message", "id": <n>, "body": <json>}`,
    ## `{"kind": "timeout"}` or `{"kind": "closed"}` as JSON text.
    receive! : I64 => Str

    ## Write a line to stderr, which Vim collects in the plugin's log.
    log! : Str => {}

    ## The id Vim assigned this plugin when it started the job.
    plugin_id! : () => Str
}
