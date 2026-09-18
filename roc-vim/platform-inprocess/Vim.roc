## Talking to Vim from inside Vim.
##
## A plugin built with this platform runs in Vim's process, so everything here
## is a direct call: [ex!] runs the command, [eval!] evaluates and returns.
##
## ```
## app [Model, plugin] { vim: platform "platform/main.roc" }
##
## import vim.Vim
##
## Model : I64
##
## plugin = { init!, handle! }
##
## init! : () => Try(Model, _)
## init! = || {
##     Vim.subscribe!(["BufWritePost"])
##     Vim.add_command!("RocHello")
##     Ok(0)
## }
##
## handle! : Model, Vim.Event => Try(Model, _)
## handle! = |writes, event|
##     if event.name == "BufWritePost" {
##         Vim.echo!("write number ${I64.to_str(writes + 1)}")
##         Ok(writes + 1)
##     } else {
##         Vim.echo!("hello from Roc, inside Vim")
##         Ok(writes)
##     }
## ```
import Host
import Value

Vim := [].{

    ## Something that happened: an event the plugin subscribed to, a command
    ## it defined, a mapping, or a `roc#send()` from Vimscript.
    ##
    ## `data` is whatever Vim sent along: for an autocommand event that is the
    ## buffer, file name, filetype, cursor position and mode; for a command it
    ## also has `args`, `line1` and `line2`.
    Event : {
        name : Str,
        data : Value,
    }

    # =========================================================================
    # Running commands
    # =========================================================================

    ## Run an Ex command, the way `:` does.
    ## ```
    ## Vim.ex!("split ${Vim.quote(path)}")
    ## ```
    ex! : Str => {}
    ex! = |command| Host.ex!(command)

    ## Feed keys to Vim as if they were typed in normal mode.
    normal! : Str => {}
    normal! = |keys| Host.ex!("normal! ${keys}")

    ## Show a message on the last line.
    echo! : Str => {}
    echo! = |message| Host.ex!("echo ${quote(message)}")

    ## Show a message and keep it in `:messages`.
    echom! : Str => {}
    echom! = |message| Host.message!(message, False)

    ## Show a message as an error, in the error highlight.
    error! : Str => {}
    error! = |message| Host.message!(message, True)

    ## Write a line to `:messages`. A plugin in Vim's process has no terminal
    ## of its own, so this is where notes to yourself go.
    log! : Str => {}
    log! = |message| Host.message!("roc-vim: ${message}", False)

    ## Redraw the screen.
    redraw! : () => {}
    redraw! = || Host.ex!("redraw")

    # =========================================================================
    # Asking Vim things
    # =========================================================================

    ## Evaluate a Vim expression and return its value.
    ## ```
    ## last_line = Vim.eval!("line('$')")?
    ## ```
    eval! : Str => Try(Value, [VimErr(Str), ..])
    eval! = |expression| decode_answer(Host.eval!(expression))

    ## Evaluate a Vim expression that produces a string.
    eval_str! : Str => Try(Str, [VimErr(Str), ..])
    eval_str! = |expression| as_str(eval!(expression)?)

    ## Evaluate a Vim expression that produces a number.
    eval_int! : Str => Try(I64, [VimErr(Str), ..])
    eval_int! = |expression| as_int(eval!(expression)?)

    ## Call a Vim function and return what it returns.
    ## ```
    ## _ = Vim.call!("setline", [Value.Int(1), Value.Text("hello")])?
    ## ```
    call! : Str, List(Value) => Try(Value, [VimErr(Str), ..])
    call! = |function_name, arguments| {
        args_json = Value.to_str(Value.Array(arguments))
        eval!("call(${quote(function_name)}, json_decode(${quote(args_json)}))")
    }

    ## Answer whoever raised this event. Vimscript that called
    ## `roc#ask()` (or `roc_event()`) gets this value back.
    reply! : Value => {}
    reply! = |value| Host.reply!(Value.to_str(value))

    # =========================================================================
    # Registering with Vim
    # =========================================================================

    ## Ask to hear about Vim events, by `autocmd` name.
    ##
    ## An entry is an event name, optionally followed by the pattern to match:
    ## `"BufWritePost"` fires for every file, `"BufWritePost *.md"` only for
    ## Markdown ones.
    subscribe! : List(Str) => {}
    subscribe! = |events| {
        var $items = []
        for event in events {
            $items = $items.append(Value.Text(event))
        }
        _ = call!("roc#subscribe", [Value.Text(id!()), Value.Array($items)])
        {}
    }

    ## Define an Ex command that sends this plugin an event named
    ## `"command:<name>"`, carrying the command's arguments in `args`.
    add_command! : Str => {}
    add_command! = |name| {
        _ = call!("roc#add_command", [Value.Text(id!()), Value.Text(name)])
        {}
    }

    ## Define a key mapping that sends this plugin an event named
    ## `"mapping:<lhs>"`.
    add_mapping! : Str, Str => {}
    add_mapping! = |mode, lhs| {
        _ = call!("roc#add_mapping", [Value.Text(id!()), Value.Text(mode), Value.Text(lhs)])
        {}
    }

    ## The handle Vim loaded this plugin under.
    id! : () => Str
    id! = || Host.id!()

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

    ## Quote a string as a Vim string literal, so it can go inside a command or
    ## an expression without a quote or a backslash changing the meaning.
    quote : Str -> Str
    quote = |text| {
        # A single-quoted Vim string takes everything literally; the only
        # escape it has is '' for a quote of its own.
        escaped = Str.replace_each(text, "'", "''")
        "'${escaped}'"
    }

    ## The `data` of an event, without having to reach into the record.
    data_of : Event -> Value
    data_of = |event| event.data

    ## The name of an event.
    name_of : Event -> Str
    name_of = |event| event.name
}

# =============================================================================
# Private helpers
# =============================================================================

## The host answers `eval!` with `{"ok": <value>}` or `{"err": "<reason>"}`.
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
