## The floor: a plugin that imports nothing and does nothing.
app [Model, plugin] { bench: platform "../platform/main.roc" }

Model : I64

plugin = { init!, handle!, map_floats, map_strs }

init! : () => Model
init! = || 0

handle! : Model, Str => Model
handle! = |count, _event| count + 1

map_floats : List(F64) -> List(F64)
map_floats = |values| values

map_strs : List(Str) -> List(Str)
map_strs = |values| values
