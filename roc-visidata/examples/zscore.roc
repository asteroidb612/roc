## A column computed in Roc: how many standard deviations each value is from
## the mean of its column.
##
## Add it with `roc-addcol` on a numeric column. The whole column crosses the
## boundary once, gets mapped here, and comes back — see bench/RESULTS.md for
## what that is and is not worth.
app [map_floats, map_strs] { vd: platform "../platform/column.roc" }

map_floats : List(F64) -> List(F64)
map_floats = |values| {
    count = U64.to_f64(List.len(values))
    if count == 0.0 {
        values
    } else {
        mean = List.sum(values) / count
        variance = List.sum(List.map(values, |x| (x - mean) * (x - mean))) / count
        sigma = F64.sqrt(variance)
        if sigma == 0.0 {
            List.map(values, |_| 0.0)
        } else {
            List.map(values, |x| (x - mean) / sigma)
        }
    }
}

map_strs : List(Str) -> List(Str)
map_strs = |values| values
