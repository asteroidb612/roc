## A derived column of the shape people actually write: two arithmetic ops.
app [handle!, map_floats, map_strs] { bench: platform "../platform/main.roc" }

handle! : Str => Str
handle! = |event| event

map_floats : List(F64) -> List(F64)
map_floats = |values| List.map(values, |x| x * 2.5 + 1.0)

## The string equivalent: a column of text, uppercased.
map_strs : List(Str) -> List(Str)
map_strs = |values| List.map(values, |s| Str.to_upper(s))
