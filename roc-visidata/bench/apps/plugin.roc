## A plugin the size people actually write: it imports the platform's JSON
## module and does real work with it. This is the compile-latency case that
## matters, since every roc-visidata plugin imports Value the same way.
app [handle!, map_floats, map_strs] { bench: platform "../platform-full/main.roc" }

import bench.Value
import bench.Bench

handle! : Str => Str
handle! = |event|
    match Value.parse(event) {
        Ok(message) => {
            name = Value.str_or(Value.field_or_null(message, "event"), "")
            if name == "command:bench" {
                Bench.log!("bench: handled ${name}")
                Value.to_str(Value.Text("ok: ${name}"))
            } else {
                Value.to_str(Value.Null)
            }
        }
        Err(_) => Value.to_str(Value.Text("parse failed"))
    }

map_floats : List(F64) -> List(F64)
map_floats = |values| List.map(values, |x| x * 2.5 + 1.0)

map_strs : List(Str) -> List(Str)
map_strs = |values| List.map(values, |s| Str.to_upper(s))
