## A column computed in Roc: the bulk path.
##
## A plugin built against this platform gets a whole column at once and returns
## a whole column, so the boundary is crossed once per recalculation rather
## than once per cell.
##
## Interpreted, this is slower than the Python it replaces — `bench/RESULTS.md`
## has the numbers. It is worth building against when the compiled tier is
## available, and it is the shape a Roc-owned column wants either way.
platform ""
    requires {
        ## Compute the column's values from the source column's values.
        map_floats : List(F64) -> List(F64),
        ## The same, for a column of text.
        map_strs : List(Str) -> List(Str)
    }
    exposes [VisiData, Value]
    packages {}
    provides {
        "roc_vd_map_floats": map_floats_for_host,
        "roc_vd_map_strs": map_strs_for_host,
    }
    hosted {
        "roc_vd_host_exec": Host.exec!,
        "roc_vd_host_eval": Host.eval!,
        "roc_vd_host_message": Host.message!,
        "roc_vd_host_reply": Host.reply!,
        "roc_vd_host_reply_floats": Host.reply_floats!,
        "roc_vd_host_read_file": Host.read_file!,
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

map_floats_for_host : List(F64) -> List(F64)
map_floats_for_host = |values| map_floats(values)

map_strs_for_host : List(Str) -> List(Str)
map_strs_for_host = |values| map_strs(values)
