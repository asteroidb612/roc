## `~/.visidatarc.roc`: VisiData configured in Roc.
##
## Copy this to ~/.visidatarc.roc. It runs after ~/.visidatarc, so anything
## your Python config already sets wins.
app [main!] { vd: platform "platform/config.roc" }

import vd.VisiData
import vd.Value

main! : () => Try({}, _)
main! = || {
    # Options, the way `options.x = y` does in Python.
    VisiData.set_option!("disp_float_fmt", Value.Text("{:.2f}"))
    VisiData.set_option!("quitguard", Value.Bool(True))

    # Keys, the way `bindkey` does.
    VisiData.bind_key!("gw", "sysopen-row")

    # Open .rtsv files with the Roc loader instead of VisiData's own, so the
    # table stays on the Roc side. The path is resolved from the plugin
    # directory when it is not absolute.
    VisiData.register_loader!("rtsv", "tsv_loader.roc")

    VisiData.status!("visidatarc.roc loaded")
    Ok({})
}
