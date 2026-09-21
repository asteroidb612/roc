## Talking to VisiData from inside VisiData.
##
## A plugin runs in VisiData's own process, so everything here is a direct
## call: [exec!] runs a statement, [eval!] evaluates and returns.
##
## ```
## app [Model, plugin] { vd: platform "platform/main.roc" }
##
## import vd.VisiData
##
## Model : I64
##
## plugin = { init!, handle! }
##
## init! : () => Try(Model, _)
## init! = || {
##     VisiData.add_command!("z#", "roc-count", "count the rows")
##     Ok(0)
## }
##
## handle! : Model, VisiData.Event => Try(Model, _)
## handle! = |runs, event|
##     if event.name == "command:roc-count" {
##         n = VisiData.nrows!()?
##         VisiData.status!("${I64.to_str(n)} rows")
##         Ok(runs + 1)
##     } else {
##         Ok(runs)
##     }
## ```
import Host
import Value

VisiData := [].{

    ## Something that happened: a command the plugin defined, a key it bound,
    ## or a hook it subscribed to.
    ##
    ## `data` is whatever VisiData sent along — for a command, the sheet name
    ## and the cursor position; for a hook, whatever the hook carries.
    Event : {
        name : Str,
        data : Value,
    }

    # =========================================================================
    # Running Python
    # =========================================================================

    ## Execute a Python statement in VisiData's globals, the way a line in
    ## `.visidatarc` does.
    ## ```
    ## VisiData.exec!("vd.push(vd.sheet.copy())")
    ## ```
    exec! : Str => {}
    exec! = |statement| Host.exec!(statement)

    ## Evaluate a Python expression and get its value back.
    ## ```
    ## rows = VisiData.eval!("len(vd.sheet.rows)")?
    ## ```
    eval! : Str => Try(Value, [VdErr(Str), ..])
    eval! = |expression| decode_answer(Host.eval!(expression))

    ## Evaluate a Python expression that returns a string.
    eval_str! : Str => Try(Str, [VdErr(Str), ..])
    eval_str! = |expression| as_str(eval!(expression)?)

    ## Evaluate a Python expression that returns a whole number.
    eval_int! : Str => Try(I64, [VdErr(Str), ..])
    eval_int! = |expression| as_int(eval!(expression)?)

    ## Call a Python function in VisiData's globals with JSON-shaped
    ## arguments.
    ## ```
    ## _ = VisiData.call!("vd.status", [Value.Text("hello")])?
    ## ```
    call! : Str, List(Value) => Try(Value, [VdErr(Str), ..])
    call! = |function_name, arguments| {
        args_json = Value.to_str(Value.Array(arguments))
        eval!("${function_name}(*_roc_json(${quote(args_json)}))")
    }

    # =========================================================================
    # Saying things
    # =========================================================================

    ## Show a message on the status line.
    status! : Str => {}
    status! = |message| Host.exec!("vd.status(${quote(message)})")

    ## Show a warning.
    warning! : Str => {}
    warning! = |message| Host.exec!("vd.warning(${quote(message)})")

    ## Show an error, and log it where `^E` will find it.
    error! : Str => {}
    error! = |message| Host.message!(message, True)

    ## Note something in VisiData's debug log.
    log! : Str => {}
    log! = |message| Host.exec!("vd.debug(${quote(message)})")

    # =========================================================================
    # Registering with VisiData
    # =========================================================================

    ## Define a command, and optionally bind it to a key.
    ##
    ## Running it sends this plugin an event named `"command:<longname>"`.
    ## Pass `""` for `keystrokes` to define the command without a binding.
    ## ```
    ## VisiData.add_command!("z#", "roc-count", "count the rows")
    ## ```
    add_command! : Str, Str, Str => {}
    add_command! = |keystrokes, longname, help| {
        _ = call!("_roc_add_command", [
            Value.Text(id!()),
            Value.Text(keystrokes),
            Value.Text(longname),
            Value.Text(help),
        ])
        {}
    }

    ## Bind a key to a command that already exists, whether it came from Roc
    ## or from VisiData itself.
    bind_key! : Str, Str => {}
    bind_key! = |keystrokes, longname| {
        _ = call!("_roc_bind_key", [Value.Text(keystrokes), Value.Text(longname)])
        {}
    }

    ## Ask to hear about a VisiData hook, by name.
    ## ```
    ## VisiData.subscribe!(["rowSelected", "sheetLoaded"])
    ## ```
    subscribe! : List(Str) => {}
    subscribe! = |hooks| {
        var $items = []
        for hook in hooks {
            $items = $items.append(Value.Text(hook))
        }
        _ = call!("_roc_subscribe", [Value.Text(id!()), Value.Array($items)])
        {}
    }

    ## Have VisiData open files with this extension using a Roc loader.
    ##
    ## `vd sales.tsv` then goes through the loader rather than VisiData's own,
    ## with the table staying on the Roc side. The path is to the loader's
    ## `.roc` file, resolved from the plugin directory if it is not absolute.
    ## ```
    ## VisiData.register_loader!("tsv", "tsv_loader.roc")
    ## ```
    register_loader! : Str, Str => {}
    register_loader! = |extension, loader_path| {
        _ = call!("_roc_register_loader", [
            Value.Text(extension),
            Value.Text(loader_path),
        ])
        {}
    }

    ## Declare an option, the way `vd.option()` does.
    declare_option! : Str, Value, Str => {}
    declare_option! = |name, default, description| {
        _ = call!("_roc_option", [
            Value.Text(name),
            default,
            Value.Text(description),
        ])
        {}
    }

    ## Set an option's value.
    set_option! : Str, Value => {}
    set_option! = |name, value| {
        _ = call!("_roc_set_option", [Value.Text(name), value])
        {}
    }

    ## Read an option's value.
    option! : Str => Try(Value, [VdErr(Str), ..])
    option! = |name| eval!("getattr(vd.options, ${quote(name)})")

    ## The handle VisiData loaded this plugin under.
    id! : () => Str
    id! = || Host.id!()

    ## Answer the command that is running right now. VisiData gets this back
    ## from the dispatch, which is what makes a Roc plugin able to back
    ## something Python waits on.
    reply! : Value => {}
    reply! = |value| Host.reply!(Value.to_str(value))

    # =========================================================================
    # The sheet
    # =========================================================================

    ## The name of the current sheet.
    sheet_name! : () => Try(Str, [VdErr(Str), ..])
    sheet_name! = || eval_str!("vd.sheet.name")

    ## How many rows the current sheet has.
    nrows! : () => Try(I64, [VdErr(Str), ..])
    nrows! = || eval_int!("len(vd.sheet.rows)")

    ## The names of the current sheet's visible columns, in order.
    column_names! : () => Try(List(Str), [VdErr(Str), ..])
    column_names! = || {
        answer = eval!("[c.name for c in vd.sheet.visibleCols]")?
        items = to_vd_err(Value.as_list(answer))?
        var $names = []
        for item in items {
            $names = $names.append(Value.str_or(item, ""))
        }
        Ok($names)
    }

    ## The name of the column the cursor is on.
    cursor_column! : () => Try(Str, [VdErr(Str), ..])
    cursor_column! = || eval_str!("vd.sheet.cursorCol.name")

    ## The index of the row the cursor is on, counting from 0.
    cursor_row! : () => Try(I64, [VdErr(Str), ..])
    cursor_row! = || eval_int!("vd.sheet.cursorRowIndex")

    ## The value under the cursor.
    cursor_value! : () => Try(Value, [VdErr(Str), ..])
    cursor_value! = || eval!("vd.sheet.cursorCol.getValue(vd.sheet.cursorRow)")

    ## Every value in one column, in row order.
    ##
    ## This crosses the boundary once for the whole column, which is the only
    ## way to read a lot of rows without paying per row. It is still one
    ## Python list comprehension on the far side: see `bench/RESULTS.md` for
    ## what that costs.
    column! : Str => Try(List(Value), [VdErr(Str), ..])
    column! = |name| {
        answer = eval!("_roc_column(${quote(name)})")?
        to_vd_err(Value.as_list(answer))
    }

    ## Every value in one column, as numbers, with anything unparseable left
    ## out.
    column_floats! : Str => Try(List(F64), [VdErr(Str), ..])
    column_floats! = |name| {
        items = column!(name)?
        var $values = []
        for item in items {
            match Value.as_f64(item) {
                Ok(number) => { $values = $values.append(number) }
                Err(_) => {}
            }
        }
        Ok($values)
    }

    ## Set a cell, by row index and column name.
    set_cell! : I64, Str, Value => {}
    set_cell! = |row, name, value| {
        _ = call!("_roc_set_cell", [Value.Int(row), Value.Text(name), value])
        {}
    }

    ## Select rows, by index.
    select_rows! : List(I64) => {}
    select_rows! = |indices| {
        var $items = []
        for index in indices {
            $items = $items.append(Value.Int(index))
        }
        _ = call!("_roc_select_rows", [Value.Array($items)])
        {}
    }

    ## Drop the current selection.
    unselect_all! : () => {}
    unselect_all! = || Host.exec!("vd.sheet.clearSelected()")

    ## Add a column to the current sheet, holding the values given, in row
    ## order.
    add_column! : Str, List(Value) => {}
    add_column! = |name, values| {
        _ = call!("_roc_add_column", [Value.Text(name), Value.Array(values)])
        {}
    }

    ## Push a new sheet of rows. Each row is an object; its fields become the
    ## columns.
    push_sheet! : Str, List(Value) => {}
    push_sheet! = |name, rows| {
        _ = call!("_roc_push_sheet", [Value.Text(name), Value.Array(rows)])
        {}
    }

    # =========================================================================
    # Quoting, and reading answers
    # =========================================================================

    ## Quote a string as a Python literal. JSON's string syntax is a subset of
    ## Python's, so encoding it as JSON is enough.
    quote : Str -> Str
    quote = |text| Value.to_str(Value.Text(text))

    ## The host answers `eval!` with `{"ok": <value>}` or `{"err": "<why>"}`.
    decode_answer : Str -> Try(Value, [VdErr(Str), ..])
    decode_answer = |text|
        match Value.parse(text) {
            Ok(answer) =>
                match Value.get(answer, "ok") {
                    Ok(value) => Ok(value)
                    Err(_) =>
                        match Value.get(answer, "err") {
                            Ok(reason) => Err(VdErr(Value.str_or(reason, "unknown error")))
                            Err(_) => Err(VdErr("the host answered with neither ok nor err"))
                        }
                }
            Err(_) => Err(VdErr("the host answered with something that is not JSON"))
        }

    as_str : Value -> Try(Str, [VdErr(Str), ..])
    as_str = |value| to_vd_err(Value.as_str(value))

    as_int : Value -> Try(I64, [VdErr(Str), ..])
    as_int = |value| to_vd_err(Value.as_int(value))

    to_vd_err : Try(a, [ValueErr(Str), ..]) -> Try(a, [VdErr(Str), ..])
    to_vd_err = |result|
        match result {
            Ok(value) => Ok(value)
            Err(ValueErr(reason)) => Err(VdErr(reason))
            Err(other) => Err(VdErr(Str.inspect(other)))
        }
}
