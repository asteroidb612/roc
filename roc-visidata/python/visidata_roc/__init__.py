"""roc-visidata: write VisiData plugins in Roc, with no build step.

A `.roc` file in `options.roc_plugin_dir` is compiled inside VisiData's own
process when it loads — the same pipeline the Roc playground runs in a browser
tab — and its commands, key bindings and hooks then work like any other
plugin's. `~/.visidatarc.roc` configures VisiData the same way.

Enable it the way any VisiData plugin is enabled, from `~/.visidatarc`:

    import visidata_roc
"""

from visidata import BaseSheet, VisiData, vd

from ._ffi import Engine, EngineError, find_library          # noqa: F401
from .engine import RocPlugin                                # noqa: F401
from . import manager                                        # noqa: F401
from . import columns                                        # noqa: F401
from . import loader                                         # noqa: F401
from .config import loadRocConfig                            # noqa: F401

__version__ = "0.1.0"


@VisiData.api
def rocStatus(vd):
    """One line about what Roc is doing, for the status line."""
    plugins = vd.rocPlugins.values()
    if not plugins:
        return "roc: nothing loaded"
    kinds = {}
    for plugin in plugins:
        kinds[plugin.kind_name] = kinds.get(plugin.kind_name, 0) + 1
    return "roc: " + ", ".join(f"{n} {k}" for k, n in sorted(kinds.items()))


BaseSheet.addCommand(None, "roc-plugins", "vd.push(vd.rocPluginsSheet())",
                     "open the Roc plugins sheet")
BaseSheet.addCommand(None, "roc-load", "vd.rocLoad(vd.input('load roc plugin: ', type='file'))",
                     "compile and load a Roc plugin from a path")
BaseSheet.addCommand(None, "roc-reload-all",
                     "[vd.rocLoad(p.path) for p in list(vd.rocPlugins.values())]",
                     "recompile every loaded Roc plugin")
BaseSheet.addCommand(None, "roc-addcol",
                     "vd.rocAddColumn(vd.input('roc column plugin: ', type='file'))",
                     "add a column computed by a Roc column plugin")
BaseSheet.addCommand(None, "roc-open",
                     "vd.rocOpen(vd.input('roc loader: ', type='file'), "
                     "vd.input('file to open: ', type='file'))",
                     "open a file with a Roc loader, which keeps the data on the Roc side")
BaseSheet.addCommand(None, "roc-status", "vd.status(vd.rocStatus())",
                     "say what Roc has loaded")

vd.addMenuItems('''
    Plugins > Roc > loaded plugins > roc-plugins
    Plugins > Roc > load a plugin > roc-load
    Plugins > Roc > reload all > roc-reload-all
    Column > Add column > Roc column > roc-addcol
''')


@VisiData.before
def run(vd, *args, **kwargs):
    """Load plugins and `.visidatarc.roc` once, just before the main loop."""
    if getattr(vd, "_roc_started", False):
        return
    vd._roc_started = True
    try:
        loadRocConfig()
        if vd.options.roc_autoload:
            vd.rocLoadDir()
    except EngineError as e:
        vd.warning(f"roc: {e}")
