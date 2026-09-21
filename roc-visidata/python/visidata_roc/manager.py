"""Finding Roc plugins, loading them, and getting events to them."""

import os
import threading
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
vd.option("roc_compile", True,
          "build loaded plugins to native code in the background, if a roc compiler is installed")
vd.option("roc_compiler", "",
          "path to the roc compiler (empty to look on PATH)")


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
    elif plugin.kind == KIND_PLUGIN and vd.options.roc_compile:
        vd.rocUpgrade(plugin)
    return plugin


@VisiData.api
def rocInstance(vd, path, prefer_compiled=True):
    """Load a plugin for one caller's exclusive use, compiled if it can be.

    Loaders need this rather than `rocLoad`. A loader's state *is* the table it
    parsed, so two sheets cannot share one — and it must never be swapped from
    under a sheet by a background upgrade, because the replacement starts with
    no table at all. So the compile happens up front, here, and the caller owns
    what it gets back.

    Compiling up front is also the fast path rather than a delay: interpreted,
    a Roc loader parses about 240 µs per row, against 0.4 µs compiled
    (`bench/RESULTS.md` §4). Waiting ~3 s once for a build that is then cached
    beats parsing anything larger than a toy file interpreted.
    """
    from .tier2 import CompiledPlugin, build, find_compiler

    path = os.path.abspath(os.path.expanduser(path))
    compiler = find_compiler(vd.options.roc_compiler or None)

    if prefer_compiled and compiler and vd.options.roc_compile:
        try:
            library = build(path, vd.options.roc_compiler or None)
            plugin = CompiledPlugin(vd.rocEngine, path, library,
                                    RocPlugin.next_handle())
            vd.rocPlugins[plugin.handle] = plugin
            return plugin
        except Exception as e:
            vd.warning(f"roc: {os.path.basename(path)} would not compile, "
                       f"running it interpreted: {e}")

    plugin = RocPlugin(vd.rocEngine, path)
    vd.rocPlugins[plugin.handle] = plugin
    if not compiler:
        vd.warning(f"roc: {plugin.name} is interpreted — install a roc compiler "
                   f"for anything bigger than a small file")
    return plugin


@VisiData.api
def rocUpgrade(vd, plugin):
    """Build this plugin to native code, off the UI thread, and swap it in.

    The plugin keeps working interpreted meanwhile; if there is no compiler
    installed, or the build fails, nothing happens and it stays interpreted.
    That is the whole degradation story — a missing compiler is not an error.
    """
    from .tier2 import CompiledPlugin, build, find_compiler

    if not find_compiler(vd.options.roc_compiler or None):
        return None

    def run():
        try:
            library = build(plugin.path, vd.options.roc_compiler or None)
        except Exception as e:
            vd.debug(f"roc: {plugin.name} stays interpreted: {e}")
            return
        try:
            compiled = CompiledPlugin(vd.rocEngine, plugin.path, library, plugin.handle)
        except Exception as e:
            vd.debug(f"roc: {plugin.name} built but would not load: {e}")
            return

        # Swap only if this plugin is still the one loaded under that handle.
        # Anything holding the old object directly keeps a plugin that no
        # longer receives events, which is why everything routes through
        # vd.rocPlugins[handle] rather than through a saved reference.
        compiled.events = plugin.events
        if vd.rocPlugins.get(plugin.handle) is plugin:
            vd.rocPlugins[plugin.handle] = compiled
            plugin.unload()
            vd.debug(f"roc: {plugin.name} is now compiled")
        else:
            compiled.unload()

    thread = threading.Thread(target=run, daemon=True,
                              name=f"roc-build-{plugin.name}")
    thread.start()
    return thread


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
def rocEnsurePlatform(vd, directory):
    """Make `platform/` inside the plugin directory point at ours.

    A plugin names its platform by path, and that path is resolved relative to
    the plugin file — so a plugin in ~/.visidata/roc cannot reach a platform
    that lives in the installed package. A symlink beside the plugins fixes
    that once, and lets every plugin say `platform "platform/main.roc"`
    wherever it lives.
    """
    link = os.path.join(directory, "platform")
    target = os.path.abspath(os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "..", "platform"))

    if not os.path.isdir(target):
        return None
    if os.path.islink(link):
        if os.path.realpath(link) == os.path.realpath(target):
            return link
        os.unlink(link)
    elif os.path.exists(link):
        return link                 # a real directory: leave it alone
    try:
        os.symlink(target, link)
    except OSError as e:
        vd.debug(f"roc: could not link {link} -> {target}: {e}")
        return None
    return link


@VisiData.api
def rocLoadDir(vd, directory=None):
    """Load every `.roc` file in the plugin directory."""
    directory = os.path.expanduser(directory or vd.options.roc_plugin_dir)
    if not os.path.isdir(directory):
        return []
    vd.rocEnsurePlatform(directory)

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
