## A plugin the size people actually write: it imports the platform's JSON
## module and does real work with it. This is the compile-latency case that
## matters, since every roc-visidata plugin imports Value the same way.
app [Model, plugin] { bench: platform "../platform-full/main.roc" }

import bench.Value
import bench.Bench

Model : I64

plugin = { init!, handle!, map_floats, map_strs }

init! : () => Model
init! = || 0

handle! : Model, Str => Model
handle! = |count, event|
    match Value.parse(event) {
        Ok(message) => {
            name = Value.str_or(Value.field_or_null(message, "event"), "")
            Bench.log!("bench: handled ${name}")
            count + 1
        }
        Err(_) => count
    }

map_floats : List(F64) -> List(F64)
map_floats = |values| List.map(values, |x| x * 2.5 + 1.0)

map_strs : List(Str) -> List(Str)
map_strs = |values| List.map(values, |s| Str.with_ascii_uppercased(s))
