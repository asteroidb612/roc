## A loader: Roc parses the file, and Roc keeps what it parsed.
##
## This is the shape the benchmarks pointed at. A plugin that computes a column
## over VisiData's rows has to drag every value out of a Python object and push
## the results back, which costs more than the computation saves. A loader does
## not: the table lives on the Roc side, and only the cells actually on screen
## ever cross — about fifty at a time, not a million.
##
## A loader writes four functions and gets the protocol for free. VisiData asks
## for what it is about to draw, as JSON requests, and this file answers them:
##
##   {"q":"load","path":"..."}   -> {"ok":true,"nrows":N,"columns":[...]}
##   {"q":"nrows"}               -> {"ok":true,"nrows":N}
##   {"q":"columns"}             -> {"ok":true,"columns":[...]}
##   {"q":"cell","row":R,"col":C} -> {"ok":true,"cell":"..."}
##   {"q":"rows","from":A,"to":B} -> {"ok":true,"rows":[[...],...]}
##
## It reuses the plugin entrypoints, so the engine needs to know nothing about
## loaders: the table is the model the host holds between calls.
platform ""
    requires {
        [Table : table] for loader : {
            ## Parse the file at this path and return the table.
            load! : Str => Try(table, [VdErr(Str), ..]),
            ## The column names, in order.
            columns : table -> List(Str),
            ## How many rows the table has.
            nrows : table -> I64,
            ## One cell as text, by row and column index, both counting from 0.
            cell : table, I64, I64 -> Str,
        }
    }
    exposes [VisiData, Value]
    packages {}
    provides {
        "roc_vd_init": init_for_host!,
        "roc_vd_handle": handle_for_host!,
    }
    hosted {
        "roc_vd_host_exec": Host.exec!,
        "roc_vd_host_eval": Host.eval!,
        "roc_vd_host_message": Host.message!,
        "roc_vd_host_reply": Host.reply!,
        "roc_vd_host_id": Host.id!,
    }
    # The compiled tier; see platform/build.sh. The interpreted tier ignores it.
    targets: {
        inputs_dir: "targets/",
        x64glibc: { inputs: ["libhost.a", app], output: Shared },
        arm64glibc: { inputs: ["libhost.a", app], output: Shared },
        x64musl: { inputs: ["libhost.a", app], output: Shared },
        arm64musl: { inputs: ["libhost.a", app], output: Shared },
        x64mac: { inputs: ["libhost.a", app], output: Shared },
        arm64mac: { inputs: ["libhost.a", app], output: Shared },
    }

import Host
import VisiData
import Value

## A loader starts with nothing and holds the table once the file is read.
State : [Empty, Ready(Table)]

init_for_host! : () => Box(State)
init_for_host! = || Box.box(Empty)

handle_for_host! : Box(State), Str => Box(State)
handle_for_host! = |boxed, request_json| {
    state = Box.unbox(boxed)
    request = parse_request(request_json)

    if request.q == "load" {
        match (loader.load!)(request.path) {
            Ok(table) => {
                Host.reply!(describe(table))
                Box.box(Ready(table))
            }
            Err(err) => {
                Host.reply!(error_json(Str.inspect(err)))
                Box.box(Empty)
            }
        }
    } else {
        match state {
            Empty => {
                Host.reply!(error_json("nothing loaded"))
                Box.box(Empty)
            }
            Ready(table) => {
                answer =
                    if request.q == "nrows" {
                        "{\"ok\":true,\"nrows\":${I64.to_str((loader.nrows)(table))}}"
                    } else if request.q == "columns" {
                        describe(table)
                    } else if request.q == "cell" {
                        text = (loader.cell)(table, request.row, request.col)
                        "{\"ok\":true,\"cell\":${Value.to_str(Value.Text(text))}}"
                    } else if request.q == "rows" {
                        rows_json(table, request.from, request.to)
                    } else {
                        error_json("unknown request ${request.q}")
                    }
                Host.reply!(answer)
                Box.box(Ready(table))
            }
        }
    }
}

## `{"ok":true,"nrows":N,"columns":[...]}` — what a sheet needs to draw itself.
describe : Table -> Str
describe = |table| {
    names = (loader.columns)(table)
    var $items = []
    for name in names {
        $items = $items.append(Value.Text(name))
    }
    count = I64.to_str((loader.nrows)(table))
    "{\"ok\":true,\"nrows\":${count},\"columns\":${Value.to_str(Value.Array($items))}}"
}

## A block of rows at once, which is how a screenful is fetched: one crossing
## for everything about to be drawn, rather than one per cell.
rows_json : Table, I64, I64 -> Str
rows_json = |table, from, to| {
    total = (loader.nrows)(table)
    last = if to > total { total } else { to }
    width =
        match List.len((loader.columns)(table)).to_i64_try() {
            Ok(n) => n
            Err(_) => 0
        }

    var $rows = []
    var $row = from
    while $row < last {
        var $cells = []
        var $col = 0
        while $col < width {
            $cells = $cells.append(Value.Text((loader.cell)(table, $row, $col)))
            $col = $col + 1
        }
        $rows = $rows.append(Value.Array($cells))
        $row = $row + 1
    }
    "{\"ok\":true,\"rows\":${Value.to_str(Value.Array($rows))}}"
}

error_json : Str -> Str
error_json = |reason|
    "{\"ok\":false,\"err\":${Value.to_str(Value.Text(reason))}}"

Request : { q : Str, path : Str, row : I64, col : I64, from : I64, to : I64 }

parse_request : Str -> Request
parse_request = |text|
    match Value.parse(text) {
        Ok(message) => {
            data = Value.field_or_null(message, "data")
            {
                q: Value.str_or(Value.field_or_null(data, "q"), ""),
                path: Value.str_or(Value.field_or_null(data, "path"), ""),
                row: Value.int_or(Value.field_or_null(data, "row"), 0),
                col: Value.int_or(Value.field_or_null(data, "col"), 0),
                from: Value.int_or(Value.field_or_null(data, "from"), 0),
                to: Value.int_or(Value.field_or_null(data, "to"), 0),
            }
        }
        Err(_) => { q: "", path: "", row: 0, col: 0, from: 0, to: 0 }
    }
