"""The C boundary: loading the engine and giving it VisiData to call back into.

Everything here is `ctypes` — there is no C extension to build, because
`ctypes.CFUNCTYPE` produces real C function pointers that the engine cannot
tell from compiled ones. That is the whole reason roc-visidata needs no fork of
VisiData, where roc-vim needed a patched Vim.

Only text crosses: Python source for statements and expressions, JSON for
values. Nothing here depends on how Roc lays out its types.
"""

import ctypes
import json
import os
import sys

ABI_VERSION = 1

#: Where the engine looks for the library, in order.
_LIB_NAMES = ("libroc_vd_engine.so", "libroc_vd_engine.dylib")


#: The callback signatures, named so the struct and the instances agree.
EXEC_FN = ctypes.CFUNCTYPE(None, ctypes.c_char_p, ctypes.c_size_t)
EVAL_FN = ctypes.CFUNCTYPE(
    ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t,
    ctypes.POINTER(ctypes.c_size_t))
FREE_FN = ctypes.CFUNCTYPE(None, ctypes.c_void_p)
MESSAGE_FN = ctypes.CFUNCTYPE(
    None, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_int)


class RocVdApi(ctypes.Structure):
    """The function table the engine calls VisiData through.

    Mirrors `struct roc_vd_api` in platform/roc_vd_api.h. Both sides check
    abi_version before using it.
    """

    _fields_ = [
        ("abi_version", ctypes.c_int),
        ("exec", EXEC_FN),
        ("eval_json", EVAL_FN),
        ("free_result", FREE_FN),
        ("message", MESSAGE_FN),
    ]


class EngineError(Exception):
    """The engine refused to do something, and said why."""


def find_library(explicit=None):
    """Where libroc_vd_engine lives, or None.

    Looked for in: the path given, $ROC_VD_ENGINE, next to this package (where
    a wheel puts it), and the engine/ directory of a source checkout.
    """
    candidates = []
    if explicit:
        candidates.append(explicit)
    if os.environ.get("ROC_VD_ENGINE"):
        candidates.append(os.environ["ROC_VD_ENGINE"])

    here = os.path.dirname(os.path.abspath(__file__))
    checkout_engine = os.path.join(here, "..", "..", "engine")
    for directory in (here, checkout_engine):
        for name in _LIB_NAMES:
            candidates.append(os.path.join(directory, name))

    for candidate in candidates:
        if candidate and os.path.exists(candidate):
            return os.path.abspath(candidate)
    return None


class Engine:
    """The loaded engine, and the callbacks VisiData answers it with.

    One of these per process. It owns the callback objects, which must outlive
    every call the engine makes through them — a garbage-collected ctypes
    callback is a segfault waiting for the next event.
    """

    def __init__(self, path, evaluator):
        self.path = path
        self.lib = ctypes.CDLL(path)
        self._declare()

        engine_abi = self.lib.roc_vd_engine_abi_version()
        if engine_abi != ABI_VERSION:
            raise EngineError(
                f"the engine at {path} speaks ABI version {engine_abi}, "
                f"and this visidata_roc speaks {ABI_VERSION}")

        # `evaluator` is what actually reaches into VisiData; keeping it behind
        # an object rather than importing vd here is what lets the engine be
        # tested with no VisiData at all (see test/engine_test.py).
        self.evaluator = evaluator

        # Buffers handed to C, kept alive until it calls free_result.
        self._owned = {}

        self._callbacks = (
            EXEC_FN(self._exec),
            EVAL_FN(self._eval_json),
            FREE_FN(self._free_result),
            MESSAGE_FN(self._message),
        )
        self.api = RocVdApi(ABI_VERSION, *self._callbacks)
        self.api_ref = ctypes.byref(self.api)

    def _declare(self):
        lib = self.lib
        c, p, s, i = ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int

        lib.roc_vd_engine_abi_version.restype = i
        lib.roc_vd_load.argtypes = [p, i, c, s, ctypes.POINTER(p)]
        lib.roc_vd_load.restype = p
        lib.roc_vd_kind.argtypes = [p]
        lib.roc_vd_kind.restype = i
        lib.roc_vd_event.argtypes = [p, p, c, s, ctypes.POINTER(s)]
        lib.roc_vd_event.restype = p
        lib.roc_vd_run_config.argtypes = [p, p, ctypes.POINTER(p)]
        lib.roc_vd_run_config.restype = i
        lib.roc_vd_map_floats.argtypes = [
            p, p, ctypes.POINTER(ctypes.c_double), s,
            ctypes.POINTER(ctypes.POINTER(ctypes.c_double)),
            ctypes.POINTER(s), ctypes.POINTER(p)]
        lib.roc_vd_map_floats.restype = i
        lib.roc_vd_free_floats.argtypes = [ctypes.POINTER(ctypes.c_double)]
        lib.roc_vd_free.argtypes = [p]
        lib.roc_vd_free_error.argtypes = [p]
        lib.roc_vd_unload.argtypes = [p]

    # -- what the engine calls ------------------------------------------------

    def _exec(self, stmt, length):
        try:
            self.evaluator.exec_(stmt[:length].decode("utf-8", "replace"))
        except Exception as e:                      # never unwind into C
            self.evaluator.report(f"{type(e).__name__}: {e}", True)

    def _eval_json(self, expr, length, out_len):
        try:
            source = expr[:length].decode("utf-8", "replace")
            payload = json.dumps({"ok": self.evaluator.eval_(source)},
                                 default=self.evaluator.jsonable)
        except Exception as e:
            payload = json.dumps({"err": f"{type(e).__name__}: {e}"})

        encoded = payload.encode("utf-8")
        buffer = ctypes.create_string_buffer(encoded, len(encoded))
        address = ctypes.cast(buffer, ctypes.c_void_p).value
        self._owned[address] = buffer            # keep it alive for C
        if out_len:
            out_len[0] = len(encoded)
        return address

    def _free_result(self, address):
        self._owned.pop(address, None)

    def _message(self, text, length, is_error):
        try:
            self.evaluator.report(text[:length].decode("utf-8", "replace"), bool(is_error))
        except Exception:
            pass

    # -- errors ---------------------------------------------------------------

    def take_error(self, holder, fallback="the engine did not say why"):
        """Read and free an owned error message the engine handed back."""
        if not holder.value:
            return fallback
        message = ctypes.cast(holder.value, ctypes.c_char_p).value
        self.lib.roc_vd_free_error(holder.value)
        return message.decode("utf-8", "replace") if message else fallback
