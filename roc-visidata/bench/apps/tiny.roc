app [handle!, map_floats, map_strs] { bench: platform "../platform/main.roc" }

handle! : Str => Str
handle! = |event| event

map_floats : List(F64) -> List(F64)
map_floats = |values| values

map_strs : List(Str) -> List(Str)
map_strs = |values| values
