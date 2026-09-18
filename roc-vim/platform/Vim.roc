## Talking to Vim.
##
## A plugin is a program that Vim starts as a job and talks to over a channel.
## It usually says what it wants to hear about ([subscribe!], [add_command!]),
## then loops on [receive!] and acts on what comes back.
##
## ```
## app [main!] { vim: platform "platform/main.roc" }
##
## import vim.Vim
##
## main! : () => Try({}, [Exit(I32)])
## main! = || {
##     Vim.subscribe!(["BufWritePost"])
##     loop!({})
## }
##
## loop! : {} => Try({}, [Exit(I32)])
## loop! = |state|
##     match Vim.receive!() {
##         Closed => Ok({})
##         Notify({ name: "BufWritePost" }) => {
##             Vim.echo!("saved!")
##             loop!(state)
##         }
##         _ => loop!(state)
##     }
## ```
import Host
import Value

Vim := [].{

    ## Something Vim sent the plugin.
    Event : [
        ## An event the plugin subscribed to, a command it defined, or anything
        ## else sent with `roc#notify()`. When `reply_to` is not 0, Vim is
        ## blocked waiting for [reply!] with that number.
        Notify({ name : Str, data : Value, reply_to : I64 }),
        ## A message that did not follow the `roc#notify()` shape.
        Message({ id : I64, body : Value }),
        ## [receive_timeout!] ran out of time before anything arrived.
        Timeout,
        ## Vim closed the channel. Vim is exiting (or the plugin was stopped),
        ## so the plugin should return from `main!`.
        Closed,
    ]

    # =========================================================================
    # Running commands
    # =========================================================================

    ## Run an Ex command, the way `:` does. Does not wait for Vim to run it.
    ## ```
    ## Vim.ex!("split ${Vim.quote(path)}")
    ## ```
    ex! : Str => {}
    ex! = |command| Host.ex!(command)

    ## Feed keys to Vim as if they were typed in normal mode.
    normal! : Str => {}
    normal! = |keys| Host.normal!(keys)

    ## Show a message on the last line.
    echo! : Str => {}
    echo! = |message| Host.ex!("echo ${quote(message)}")

    ## Show a message and keep it in `:messages`.
    echom! : Str => {}
    echom! = |message| Host.ex!("echomsg ${quote(message)}")

    ## Show a message as an error, in the error highlight.
    error! : Str => {}
    error! = |message|
        Host.ex!("echohl ErrorMsg | echomsg ${quote(message)} | echohl None")

    ## Redraw the screen. Worth doing after changing something while Vim is
    ## waiting for input.
    redraw! : () => {}
    redraw! = || Host.send!("[\"redraw\",\"\"]")

    ## Write a line to the plugin's log, which `:RocLog` shows. Handy while
    ## working on a plugin, since a plugin has no terminal of its own.
    log! : Str => {}
    log! = |message| Host.log!(message)

    # =========================================================================
    # Asking Vim things
    # =========================================================================

    ## Evaluate a Vim expression and wait for the result.
    ## ```
    ## line_count = Vim.eval!("line('$')")?
    ## ```
    eval! : Str => Try(Value, [VimErr(Str), ..])
    eval! = |expression| decode_answer(Host.eval!(expression))

    ## Evaluate a Vim expression that produces a string.
    eval_str! : Str => Try(Str, [VimErr(Str), ..])
    eval_str! = |expression| as_str(eval!(expression)?)

    ## Evaluate a Vim expression that produces a number.
    eval_int! : Str => Try(I64, [VimErr(Str), ..])
    eval_int! = |expression| as_int(eval!(expression)?)

    ## Call a Vim function and wait for its return value.
    ## ```
    ## _ = Vim.call!("setline", [Value.Int(1), Value.Text("hello")])?
    ## ```
    call! : Str, List(Value) => Try(Value, [VimErr(Str), ..])
    call! = |function_name, arguments|
        decode_answer(Host.call!(function_name, Value.to_str(Value.Array(arguments))))

    ## Answer a request Vim is blocked on. The number comes from the `reply_to`
    ## of a [Notify] event; sending the answer unblocks `roc#request()`.
    reply! : I64, Value => {}
    reply! = |request_id, value| Host.reply!(request_id, Value.to_str(value))

    ## Send an already-encoded JSON message on the channel. Everything else here
    ## is built on this; reach for it when you need a channel command this
    ## module does not wrap.
    send! : Str => {}
    send! = |message| Host.send!(message)

    # =========================================================================
    # Waiting for Vim
    # =========================================================================

    ## Wait for the next event, for as long as it takes.
    receive! : () => Event
    receive! = || decode_event(Host.receive!(-1))

    ## Wait for the next event, giving up after this many milliseconds and
    ## returning [Timeout]. Use it to do periodic work between events.
    receive_timeout! : I64 => Event
    receive_timeout! = |millis| decode_event(Host.receive!(millis))

    # =========================================================================
    # Registering with Vim
    # =========================================================================

    ## Ask to hear about Vim events, by `autocmd` name.
    ##
    ## An entry is an event name, optionally followed by the pattern to match:
    ## `"BufWritePost"` fires for every file, `"BufWritePost *.md"` only for
    ## Markdown ones. The [Notify] that arrives is named after the event.
    subscribe! : List(Str) => {}
    subscribe! = |events| {
        var $items = []
        for event in events {
            $items = $items.append(Value.Text(event))
        }
        _ = call!("roc#subscribe", [Value.Text(id!()), Value.Array($items)])
        {}
    }

    ## Define an Ex command that sends this plugin a [Notify] named
    ## `"command:<name>"`. The event's `data` carries the command's arguments in
    ## `args`, plus the usual context.
    ##
    ## The name must start with an uppercase letter, as Vim requires of
    ## user-defined commands.
    add_command! : Str => {}
    add_command! = |name| {
        _ = call!("roc#add_command", [Value.Text(id!()), Value.Text(name)])
        {}
    }

    ## Define a key mapping that sends this plugin a [Notify] named
    ## `"mapping:<lhs>"`. The mode is Vim's: `"n"`, `"i"`, `"v"`, and so on.
    ## ```
    ## Vim.add_mapping!("n", "<Leader>rr")
    ## ```
    add_mapping! : Str, Str => {}
    add_mapping! = |mode, lhs| {
        _ = call!("roc#add_mapping", [Value.Text(id!()), Value.Text(mode), Value.Text(lhs)])
        {}
    }

    ## The number Vim gave this plugin when it started it. Mostly useful for
    ## writing your own `roc#notify()` calls in Vimscript.
    id! : () => Str
    id! = || Host.plugin_id!()

    # =========================================================================
    # Buffers, windows, the cursor
    # =========================================================================

    ## The text of one line of the current buffer, counting from 1.
    line! : I64 => Try(Str, [VimErr(Str), ..])
    line! = |number| as_str(call!("getline", [Value.Int(number)])?)

    ## The line the cursor is on.
    current_line! : () => Try(Str, [VimErr(Str), ..])
    current_line! = || as_str(call!("getline", [Value.Text(".")])?)

    ## Every line of the current buffer.
    lines! : () => Try(List(Str), [VimErr(Str), ..])
    lines! = || {
        answer = call!("getline", [Value.Int(1), Value.Text("$")])?
        items = to_vim_err(Value.as_list(answer))?
        var $texts = []
        for item in items {
            $texts = $texts.append(Value.str_or(item, ""))
        }
        Ok($texts)
    }

    ## Replace one line of the current buffer.
    set_line! : I64, Str => {}
    set_line! = |number, text| {
        _ = call!("setline", [Value.Int(number), Value.Text(text)])
        {}
    }

    ## Replace the whole current buffer.
    set_lines! : List(Str) => {}
    set_lines! = |texts| {
        var $items = []
        for text in texts {
            $items = $items.append(Value.Text(text))
        }
        _ = call!("roc#set_lines", [Value.Array($items)])
        {}
    }

    ## Insert lines after the given line number. Line 0 puts them at the top.
    append_lines! : I64, List(Str) => {}
    append_lines! = |after, texts| {
        var $items = []
        for text in texts {
            $items = $items.append(Value.Text(text))
        }
        _ = call!("append", [Value.Int(after), Value.Array($items)])
        {}
    }

    ## Where the cursor is: `row` counts from 1, `col` counts bytes from 1.
    cursor! : () => Try({ row : I64, col : I64 }, [VimErr(Str), ..])
    cursor! = || {
        row = eval_int!("line('.')")?
        col = eval_int!("col('.')")?
        Ok({ row, col })
    }

    ## Move the cursor.
    set_cursor! : I64, I64 => {}
    set_cursor! = |row, col| {
        _ = call!("cursor", [Value.Int(row), Value.Int(col)])
        {}
    }

    ## The name of the current buffer, as Vim shows it in the status line.
    buffer_name! : () => Try(Str, [VimErr(Str), ..])
    buffer_name! = || eval_str!("expand('%')")

    ## The current buffer's filetype, or "" if it has none.
    filetype! : () => Try(Str, [VimErr(Str), ..])
    filetype! = || eval_str!("&filetype")

    ## Read a Vim variable, such as `"g:colors_name"` or `"&textwidth"`.
    var! : Str => Try(Value, [VimErr(Str), ..])
    var! = |name| eval!(name)

    ## Set a Vim variable, such as `"g:my_plugin_ran"`.
    set_var! : Str, Value => {}
    set_var! = |name, value| {
        _ = call!("roc#set_var", [Value.Text(name), value])
        {}
    }

    # =========================================================================
    # Odds and ends
    # =========================================================================

    ## Quote a string as a Vim string literal, so it can be put inside an Ex
    ## command without a quote or a backslash in it changing the meaning.
    ## ```
    ## Vim.ex!("edit ${Vim.quote(filename)}")
    ## ```
    quote : Str -> Str
    quote = |text| {
        var $out = "\""
        for byte in text.to_utf8() {
            $out = Str.concat($out, escape_byte(byte))
        }
        Str.concat($out, "\"")
    }

    ## The `data` of a [Notify], without having to match on the event.
    ## Returns [Value.Null] for events that carry nothing.
    data_of : Event -> Value
    data_of = |event|
        match event {
            Notify(details) => details.data
            Message(details) => details.body
            _ => Value.Null
        }

    ## The name of a [Notify], or "" for anything else.
    name_of : Event -> Str
    name_of = |event|
        match event {
            Notify(details) => details.name
            _ => ""
        }
}

# =============================================================================
# Private helpers
# =============================================================================

escape_byte : U8 -> Str
escape_byte = |byte|
    if byte == '"' {
        "\\\""
    } else if byte == '\\' {
        "\\\\"
    } else if byte == '\n' {
        "\\n"
    } else if byte == '\r' {
        "\\r"
    } else if byte == '\t' {
        "\\t"
    } else if byte < 0x20 {
        "\\x${hex(byte // 16)}${hex(byte % 16)}"
    } else {
        match Str.from_utf8([byte]) {
            Ok(text) => text
            # A byte from the middle of a multi-byte character: pass it through
            # as a hex escape, which Vim accepts inside a double-quoted string.
            Err(_) => "\\x${hex(byte // 16)}${hex(byte % 16)}"
        }
    }

hex : U8 -> Str
hex = |n| {
    digit = if n < 10 ('0' + n) else ('a' + (n - 10))
    match Str.from_utf8([digit]) {
        Ok(text) => text
        Err(_) => "0"
    }
}

## The host answers `eval!` and `call!` with `{"ok": <value>}` or
## `{"err": "<reason>"}`.
decode_answer : Str -> Try(Value, [VimErr(Str), ..])
decode_answer = |text| {
    envelope = to_vim_err(Value.parse(text))?
    match Value.get(envelope, "ok") {
        Ok(value) => Ok(value)
        Err(_) =>
            match Value.get(envelope, "err") {
                Ok(reason) => Err(VimErr(Value.str_or(reason, "unknown error")))
                Err(_) => Err(VimErr("could not understand the answer from Vim: ${text}"))
            }
    }
}

decode_event : Str -> Vim.Event
decode_event = |text|
    match Value.parse(text) {
        Err(_) => Closed
        Ok(envelope) => {
            kind = Value.str_or(Value.field_or_null(envelope, "kind"), "")
            if kind == "timeout" {
                Timeout
            } else if kind == "closed" {
                Closed
            } else {
                id = Value.int_or(Value.field_or_null(envelope, "id"), 0)
                body = Value.field_or_null(envelope, "body")
                match Value.get(body, "event") {
                    Ok(name_value) =>
                        Notify({
                            name: Value.str_or(name_value, ""),
                            data: Value.field_or_null(body, "data"),
                            reply_to: if Value.int_or(Value.field_or_null(body, "reply"), 0) == 0 0 else id,
                        })
                    Err(_) => Message({ id, body })
                }
            }
        }
    }

as_str : Value -> Try(Str, [VimErr(Str), ..])
as_str = |value| to_vim_err(Value.as_str(value))

as_int : Value -> Try(I64, [VimErr(Str), ..])
as_int = |value| to_vim_err(Value.as_int(value))

to_vim_err : Try(a, [ValueErr(Str), ..]) -> Try(a, [VimErr(Str), ..])
to_vim_err = |result|
    match result {
        Ok(value) => Ok(value)
        Err(ValueErr(message)) => Err(VimErr(message))
        Err(_) => Err(VimErr("could not read the value Vim sent"))
    }
