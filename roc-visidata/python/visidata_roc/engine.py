"""A loaded Roc plugin, and the rules for calling into it.

VisiData runs commands on background threads (`visidata/threads.py`), so two
threads can reach one plugin at once. A plugin is a model and a handler, which
means its events are sequential by definition, so each one is guarded by its
own lock.

The lock is deliberately not reentrant. Roc can call `eval!`, Python can
evaluate something that triggers a command, and that command can dispatch to
the same plugin; without the guard below that is a deadlock, and with it the
inner call fails with something a person can read.
"""

import ctypes
import json
import os
import threading

from ._ffi import EngineError

KIND_PLUGIN = 1
KIND_CONFIG = 2
KIND_COLUMN = 3

KIND_NAMES = {KIND_PLUGIN: "plugin", KIND_CONFIG: "config", KIND_COLUMN: "column"}

_next_handle = itertools_count = None


class Reentered(EngineError):
    """A plugin was re-entered from inside one of its own calls."""


class RocPlugin:
    """One `.roc` file, compiled and running inside VisiData."""

    _handles = 0
    _handles_lock = threading.Lock()

    @classmethod
    def next_handle(cls):
        """Mint a handle for a plugin loaded some other way (a compiled one)."""
        with cls._handles_lock:
            cls._handles += 1
            return cls._handles

    def __init__(self, engine, path):
        self.engine = engine
        self.path = os.path.abspath(path)
        self.name = os.path.basename(self.path)
        self.source_mtime = os.path.getmtime(self.path)
        self.transport = "source"          # "compiled" once tier 2 lands
        self.error = None
        self.events = 0

        self._lock = threading.Lock()
        self._owner = None                 # thread inside a call, for reentrancy

        self.handle = RocPlugin.next_handle()

        error = ctypes.c_void_p()
        encoded = self.path.encode("utf-8")
        self.ptr = engine.lib.roc_vd_load(
            engine.api_ref, self.handle, encoded, len(encoded), ctypes.byref(error))
        if not self.ptr:
            raise EngineError(engine.take_error(error, "the plugin did not compile"))

        self.kind = engine.lib.roc_vd_kind(self.ptr)

    # -- the guard ------------------------------------------------------------

    class _Entered:
        def __init__(self, plugin):
            self.plugin = plugin

        def __enter__(self):
            me = threading.get_ident()
            if self.plugin._owner == me:
                raise Reentered(
                    f"{self.plugin.name} was called again from inside one of its "
                    f"own calls, which would deadlock")
            self.plugin._lock.acquire()
            self.plugin._owner = me
            return self.plugin

        def __exit__(self, *exc):
            self.plugin._owner = None
            self.plugin._lock.release()
            return False

    def entered(self):
        return RocPlugin._Entered(self)

    # -- calling it -----------------------------------------------------------

    def event(self, name, data=None):
        """Hand the plugin one event; return whatever it replied with, or None."""
        if not self.ptr:
            return None
        payload = json.dumps({"event": name, "data": data if data is not None else {}})
        encoded = payload.encode("utf-8")
        out_len = ctypes.c_size_t(0)

        with self.entered():
            self.events += 1
            address = self.engine.lib.roc_vd_event(
                self.ptr, self.engine.api_ref, encoded, len(encoded),
                ctypes.byref(out_len))

        if not address:
            return None
        raw = ctypes.string_at(address, out_len.value)
        self.engine.lib.roc_vd_free(address)
        try:
            return json.loads(raw.decode("utf-8"))
        except ValueError:
            return raw.decode("utf-8", "replace")

    def run_config(self):
        """Run a `.visidatarc.roc`'s `main!`."""
        error = ctypes.c_void_p()
        with self.entered():
            failed = self.engine.lib.roc_vd_run_config(
                self.ptr, self.engine.api_ref, ctypes.byref(error))
        if failed:
            raise EngineError(self.engine.take_error(error))

    def map_floats(self, values):
        """Map a whole column of numbers, in one crossing.

        `values` is any sequence of floats; an `array('d')` avoids a copy on
        the way in.
        """
        count = len(values)
        if count == 0:
            return []

        buffer = (ctypes.c_double * count)(*values)
        out = ctypes.POINTER(ctypes.c_double)()
        out_len = ctypes.c_size_t(0)
        error = ctypes.c_void_p()

        with self.entered():
            failed = self.engine.lib.roc_vd_map_floats(
                self.ptr, self.engine.api_ref, buffer, count,
                ctypes.byref(out), ctypes.byref(out_len), ctypes.byref(error))
        if failed:
            raise EngineError(self.engine.take_error(error))

        result = out[:out_len.value]
        self.engine.lib.roc_vd_free_floats(out)
        return result

    # -- lifecycle ------------------------------------------------------------

    @property
    def kind_name(self):
        return KIND_NAMES.get(self.kind, "unknown")

    @property
    def changed_on_disk(self):
        try:
            return os.path.getmtime(self.path) != self.source_mtime
        except OSError:
            return False

    def unload(self):
        if self.ptr:
            with self.entered():
                self.engine.lib.roc_vd_unload(self.ptr)
                self.ptr = None

    def __repr__(self):
        return f"<RocPlugin {self.name} {self.kind_name} handle={self.handle}>"
