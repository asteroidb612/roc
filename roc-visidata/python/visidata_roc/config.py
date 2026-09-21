"""`~/.visidatarc.roc`: configuring VisiData in Roc.

Loaded after `~/.visidatarc`, so an existing Python config wins on anything
both of them set. Both existing is expected during a migration.
"""

import os

from visidata import VisiData, vd

from ._ffi import EngineError
from .engine import KIND_CONFIG

#: Looked for in this order; the first that exists is used.
CONFIG_PATHS = (
    "~/.visidatarc.roc",
    "~/.config/visidata/config.roc",
)


@VisiData.api
def rocConfigPath(vd):
    for path in CONFIG_PATHS:
        expanded = os.path.expanduser(path)
        if os.path.exists(expanded):
            return expanded
    return None


def loadRocConfig(path=None):
    """Compile and run the Roc config, if there is one."""
    path = path or vd.rocConfigPath()
    if not path:
        return None

    plugin = vd.rocLoad(path)
    if plugin is None:
        return None
    if plugin.kind != KIND_CONFIG:
        vd.warning(f"roc: {os.path.basename(path)} is a {plugin.kind_name}, "
                   f"not a config (its app header should use config.roc)")
        return None
    return plugin
