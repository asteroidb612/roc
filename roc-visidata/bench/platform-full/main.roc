## The benchmark platform: the smallest thing shaped like roc-visidata.
##
## Two entrypoints, matching the two questions the benchmarks answer:
## `roc_bench_handle` is an event handler (what a plugin command costs), and
## `roc_bench_map` is the bulk column path (what a derived column costs).
platform ""
    requires {} {
        handle! : Str => Str,
        map_floats : List(F64) -> List(F64),
        map_strs : List(Str) -> List(Str),
    }
    exposes [Bench, Value]
    packages {}
    provides {
        "roc_bench_handle": handle_for_host!,
        "roc_bench_map": map_for_host,
        "roc_bench_map_strs": map_strs_for_host,
    }
    hosted { "roc_bench_log": Bench.log! }

import Bench

handle_for_host! : Str => Str
handle_for_host! = |event| handle!(event)

map_for_host : List(F64) -> List(F64)
map_for_host = |values| map_floats(values)

map_strs_for_host : List(Str) -> List(Str)
map_strs_for_host = |values| map_strs(values)
