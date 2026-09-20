## A derived column of the shape people actually write: two arithmetic ops on
## a number, and an uppercase on text.
app [Model, plugin] { bench: platform "../platform/main.roc" }

Model : I64

plugin = { init!, handle!, map_floats, map_strs }

init! : () => Model
init! = || 0

handle! : Model, Str => Model
handle! = |count, _event| count + 1

map_floats : List(F64) -> List(F64)
map_floats = |values| List.map(values, |x| x * 2.5 + 1.0)

map_strs : List(Str) -> List(Str)
map_strs = |values| List.map(values, |s| Str.with_ascii_uppercased(s))
