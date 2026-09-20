## The benchmark platform: the smallest thing shaped like roc-visidata.
##
## Same shape as roc-vim's in-process platform — a model and a handler, since
## the host owns the loop — plus the bulk entrypoints a column goes through.
platform ""
    requires {
        [Model : model] for plugin : {
            init! : () => model,
            handle! : model, Str => model,
            map_floats : List(F64) -> List(F64),
            map_strs : List(Str) -> List(Str),
        }
    }
    exposes [Bench, Value]
    packages {}
    provides {
        "roc_bench_init": init_for_host!,
        "roc_bench_handle": handle_for_host!,
        "roc_bench_map": map_for_host,
        "roc_bench_map_strs": map_strs_for_host,
    }
    hosted { "roc_bench_log": Bench.log! }

import Bench
import Value

init_for_host! : () => Box(Model)
init_for_host! = || Box.box((plugin.init!)())

handle_for_host! : Box(Model), Str => Box(Model)
handle_for_host! = |boxed, event| Box.box((plugin.handle!)(Box.unbox(boxed), event))

map_for_host : List(F64) -> List(F64)
map_for_host = |values| (plugin.map_floats)(values)

map_strs_for_host : List(Str) -> List(Str)
map_strs_for_host = |values| (plugin.map_strs)(values)
