"""The compiled tier: the same plugin, as machine code.

`bench/RESULTS.md` is blunt about why this exists. Interpreted, Roc costs about
3.4 µs per basic operation — 22× slower than Python on a column and 242× slower
on a loader — so anything that computes needs to be compiled. Commands,
bindings, hooks and config do not, and run interpreted with no compiler
installed at all.

The upgrade is meant to be invisible: a plugin starts interpreted, a build runs
on a background thread if a `roc` compiler is on PATH, and the next event goes
to the compiled library instead. The artifact is cached by the source's
contents, so the second run of a plugin is native from the first keystroke.
"""

import ctypes
import hashlib
import os
import platform
import shutil
import subprocess
import threading

from ._ffi import PLUGIN_ABI_VERSION, EngineError

CACHE = os.path.expanduser("~/.cache/roc-visidata")


def find_compiler(explicit=None):
    """Where the `roc` compiler is, or None if there is none."""
    return (explicit or os.environ.get("ROC_COMPILER")
            or shutil.which("roc"))


def native_target():
    """The Roc target name for this machine.

    glibc rather than musl, because the library is dlopened into CPython.
    """
    machine = platform.machine().lower()
    system = platform.system()
    arch = "arm64" if machine in ("aarch64", "arm64") else "x64"
    if system == "Darwin":
        return f"{arch}mac"
    return f"{arch}glibc"


def artifact_for(source):
    """Where the compiled library for this source belongs.

    Keyed by the source's contents, so editing a plugin misses the cache and
    an unchanged one never rebuilds.
    """
    with open(source, "rb") as f:
        digest = hashlib.sha256(f.read()).hexdigest()[:16]
    name = os.path.basename(source).removesuffix(".roc")
    return os.path.join(CACHE, f"{name}-{digest}.so")


def build(source, compiler=None, timeout=300):
    """Build `source` into a shared library. Returns its path.

    Raises EngineError with the compiler's own words if it will not build.
    """
    compiler = find_compiler(compiler)
    if not compiler:
        raise EngineError("no roc compiler on PATH")

    target = artifact_for(source)
    if os.path.exists(target):
        return target

    os.makedirs(CACHE, exist_ok=True)
    # The output is a shared library because the platform's `targets:` section
    # says so; the flags only say where to put it and what to build it for.
    # They take `=`, not a separate argument.
    result = subprocess.run(
        [compiler, "build", f"--output={target}", f"--target={native_target()}", source],
        capture_output=True, text=True, timeout=timeout)
    if result.returncode != 0 or not os.path.exists(target):
        detail = (result.stderr or result.stdout or "").strip()
        raise EngineError(f"roc build failed: {detail[:500]}")
    return target


class CompiledPlugin:
    """A plugin loaded as a shared library, called directly.

    Deliberately the same shape as `RocPlugin`, so the manager can swap one for
    the other without anything else noticing.
    """

    def __init__(self, engine, source, library, handle):
        self.engine = engine
        self.path = os.path.abspath(source)
        self.name = os.path.basename(self.path)
        self.library_path = library
        self.handle = handle
        self.transport = "compiled"
        self.kind = 1                    # only plugins compile today
        self.events = 0
        self.source_mtime = os.path.getmtime(self.path)

        self._lock = threading.Lock()
        self._owner = None

        self.lib = ctypes.CDLL(library)
        self._declare()

        abi = self.lib.roc_vd_plugin_abi_version()
        if abi != PLUGIN_ABI_VERSION:
            raise EngineError(
                f"{self.name} was built for plugin ABI {abi}, and this "
                f"visidata_roc speaks {PLUGIN_ABI_VERSION}; rebuild it")

        # One instance per caller: dlopening the same library twice gives the
        # same code, so the plugin's state has to be here rather than in it.
        # A loader's state is the table it parsed, so sharing would mean two
        # sheets showing one file.
        self.instance = self.lib.roc_vd_plugin_new(engine.api_ref, handle)
        if not self.instance:
            raise EngineError(f"{self.name} failed to start")

    def _declare(self):
        lib, p, i, s, c = (self.lib, ctypes.c_void_p, ctypes.c_int,
                           ctypes.c_size_t, ctypes.c_char_p)
        lib.roc_vd_plugin_abi_version.restype = i
        lib.roc_vd_plugin_new.argtypes = [p, i]
        lib.roc_vd_plugin_new.restype = p
        lib.roc_vd_plugin_event.argtypes = [p, p, c, s, ctypes.POINTER(s)]
        lib.roc_vd_plugin_event.restype = p
        lib.roc_vd_plugin_free.argtypes = [p]
        lib.roc_vd_plugin_unload.argtypes = [p]
        lib.roc_vd_take_floats.argtypes = [ctypes.POINTER(s)]
        lib.roc_vd_take_floats.restype = p
        lib.roc_vd_free_floats.argtypes = [ctypes.POINTER(ctypes.c_double)]

    # The guard is the same as the interpreted plugin's, for the same reason:
    # VisiData dispatches on background threads, and re-entry would deadlock.
    entered = None      # set below, to RocPlugin's implementation

    def event(self, name, data=None):
        import json

        payload = json.dumps({"event": name, "data": data if data is not None else {}})
        encoded = payload.encode("utf-8")
        out_len = ctypes.c_size_t(0)

        with self.entered():
            self.events += 1
            address = self.lib.roc_vd_plugin_event(
                self.instance, self.engine.api_ref, encoded, len(encoded),
                ctypes.byref(out_len))

        if not address:
            return None
        raw = ctypes.string_at(address, out_len.value)
        self.lib.roc_vd_plugin_free(address)
        try:
            return json.loads(raw.decode("utf-8"))
        except ValueError:
            return raw.decode("utf-8", "replace")

    def take_floats(self):
        """The numbers the last event answered with, or None."""
        out_len = ctypes.c_size_t(0)
        address = self.lib.roc_vd_take_floats(ctypes.byref(out_len))
        if not address:
            return None
        buffer = ctypes.cast(address, ctypes.POINTER(ctypes.c_double))
        values = buffer[:out_len.value]
        self.lib.roc_vd_free_floats(buffer)
        return values

    @property
    def kind_name(self):
        return "plugin"

    @property
    def changed_on_disk(self):
        try:
            return os.path.getmtime(self.path) != self.source_mtime
        except OSError:
            return False

    def unload(self):
        if getattr(self, "instance", None):
            try:
                self.lib.roc_vd_plugin_unload(self.instance)
            except Exception:
                pass
            self.instance = None

    def __repr__(self):
        return f"<CompiledPlugin {self.name} handle={self.handle}>"


# Share the interpreted plugin's reentrancy guard rather than writing it twice.
from .engine import RocPlugin                                   # noqa: E402

CompiledPlugin.entered = RocPlugin.entered
CompiledPlugin._Entered = RocPlugin._Entered
