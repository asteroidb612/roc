"""Finding Roc plugins, loading them, and getting events to them."""

import os
import traceback

from visidata import AttrDict, Column, ItemColumn, Sheet, VisiData, vd

from ._ffi import Engine, EngineError, find_library
from .bridge import HELPERS, VisiDataBridge
from .engine import KIND_COLUMN, KIND_CONFIG, KIND_PLUGIN, RocPlugin

vd.option("roc_plugin_dir", "~/.visidata/roc",
          "directory of Roc plugins to load at startup")
vd.option("roc_engine", "",
          "path to libroc_vd_engine.so (empty to look in the usual places)")
vd.option("roc_autoload", True,
          "load Roc plugins from roc_plugin_dir at startup")
vd.option("roc_reload_on_save", True,
          "recompile a Roc plugin when its source changes on disk")


@VisiData.lazy_property
def rocEngine(vd):
    """The one engine per process, loaded the first time something needs it."""
    path = find_library(vd.options.roc_engine or None)
    if not path:
        raise EngineError(
            "no libroc_vd_engine found. Build it with roc-visidata/engine/build.sh, "
            "or point options.roc_engine at it.")
    vd.addGlobals(HELPERS)
    return Engine(path, VisiDataBridge())


@VisiData.lazy_property
def rocPlugins(vd):
    """Loaded plugins, by the handle they were loaded under."""
    return {}


@VisiData.lazy_property
def rocSubscriptions(vd):
    """Which plugins asked about which hook."""
    return {}


@VisiData.api
def rocLoad(vd, path):
    """Compile one `.roc` file and keep it. Returns the plugin, or None."""
    path = os.path.abspath(os.path.expanduser(path))
    for plugin in vd.rocPlugins.values():
        if plugin.path == path:
            vd.rocUnload(plugin)
            break
    try:
        plugin = RocPlugin(vd.rocEngine, path)
    except EngineError as e:
        vd.warning(f"roc: {os.path.basename(path)}: {e}")
        vd.rocFailures[path] = str(e)
        return None

    vd.rocFailures.pop(path, None)
    vd.rocPlugins[plugin.handle] = plugin
    if plugin.kind == KIND_CONFIG:
        try:
            plugin.run_config()
        except EngineError as e:
            vd.warning(f"roc: {plugin.name}: {e}")
    return plugin


@VisiData.lazy_property
def rocFailures(vd):
    """Files that would not compile, and why, so :RocPlugins can show them."""
    return {}


@VisiData.api
def rocUnload(vd, plugin):
    plugin.unload()
    vd.rocPlugins.pop(plugin.handle, None)
    for subscribers in vd.rocSubscriptions.values():
        subscribers.discard(plugin.handle)


@VisiData.api
def rocSubscribe(vd, plugin_id, hook):
    vd.rocSubscriptions.setdefault(hook, set()).add(int(plugin_id))


@VisiData.api
def rocDispatch(vd, plugin_id, event, data=None):
    """Send one event to one plugin, and return what it replied.

    This is what a Roc plugin's commands are bound to: `addCommand` takes a
    Python statement, so a command registered from Roc is a call to this.
    """
    plugin = vd.rocPlugins.get(int(plugin_id))
    if plugin is None:
        vd.warning(f"roc: plugin {plugin_id} is not loaded")
        return None

    if vd.options.roc_reload_on_save and plugin.changed_on_disk:
        reloaded = vd.rocLoad(plugin.path)
        if reloaded is None:
            return None
        plugin = reloaded

    if data is None:
        data = vd.rocContext()
    try:
        return plugin.event(event, data)
    except Exception as e:
        vd.warning(f"roc: {plugin.name}: {e}")
        vd.debug(traceback.format_exc())
        return None


@VisiData.api
def rocContext(vd):
    """What every event carries: where the cursor is, and on what."""
    sheet = vd.sheet
    if sheet is None:
        return {}
    try:
        return {
            "sheet": sheet.name,
            "rows": len(sheet.rows),
            "cursorRowIndex": sheet.cursorRowIndex,
            "cursorCol": sheet.cursorCol.name if sheet.cursorCol else None,
        }
    except Exception:
        return {"sheet": getattr(sheet, "name", "")}


@VisiData.api
def rocHook(vd, hook, data=None):
    """Tell every plugin that subscribed to `hook` that it happened."""
    for handle in sorted(vd.rocSubscriptions.get(hook, ())):
        plugin = vd.rocPlugins.get(handle)
        if plugin is not None:
            vd.rocDispatch(handle, hook, data if data is not None else vd.rocContext())


@VisiData.api
def rocLoadDir(vd, directory=None):
    """Load every `.roc` file in the plugin directory."""
    directory = os.path.expanduser(directory or vd.options.roc_plugin_dir)
    if not os.path.isdir(directory):
        return []

    loaded = []
    for name in sorted(os.listdir(directory)):
        if name.endswith(".roc") and not name.startswith("_"):
            plugin = vd.rocLoad(os.path.join(directory, name))
            if plugin is not None:
                loaded.append(plugin)
    return loaded


@VisiData.api
def rocUnloadAll(vd):
    for plugin in list(vd.rocPlugins.values()):
        try:
            plugin.unload()
        except Exception:
            pass
    vd.rocPlugins.clear()


# =============================================================================
# :RocPlugins
# =============================================================================

class RocPluginsSheet(Sheet):
    """What is loaded, what it is, and what went wrong."""

    rowtype = "roc plugins"  # rowdef: AttrDict
    columns = [
        ItemColumn("name"),
        ItemColumn("kind", width=8),
        ItemColumn("transport", width=10),
        ItemColumn("events", type=int, width=7),
        ItemColumn("status", width=40),
        ItemColumn("path", width=60),
    ]

    def iterload(self):
        for plugin in sorted(vd.rocPlugins.values(), key=lambda p: p.name):
            yield AttrDict(
                name=plugin.name,
                kind=plugin.kind_name,
                transport=plugin.transport,
                events=plugin.events,
                status="changed on disk" if plugin.changed_on_disk else "ok",
                path=plugin.path,
                plugin=plugin,
            )
        for path, error in sorted(vd.rocFailures.items()):
            yield AttrDict(
                name=os.path.basename(path),
                kind="-",
                transport="-",
                events=0,
                status=error.strip().split("\n")[0][:200],
                path=path,
                plugin=None,
            )


@VisiData.api
def rocPluginsSheet(vd):
    return RocPluginsSheet("roc_plugins")
