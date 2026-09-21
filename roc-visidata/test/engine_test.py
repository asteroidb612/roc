"""The engine, driven with no VisiData at all.

This is the M0 test: it loads a real plugin through the real engine, answers
its effects with a stub, and asserts on what the plugin asked for. It needs
libroc_vd_engine.so and nothing else — no terminal, no curses, no sheet.

    python3 test/engine_test.py [path/to/libroc_vd_engine.so]
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "python"))

from visidata_roc._ffi import Engine, EngineError, find_library      # noqa: E402
from visidata_roc.engine import KIND_PLUGIN, RocPlugin              # noqa: E402


class StubVisiData:
    """VisiData's side of the boundary, without VisiData.

    Records the statements a plugin ran and answers its expressions from a
    small fixed world, so a test can assert on both.
    """

    def __init__(self):
        self.statements = []
        self.expressions = []
        self.messages = []
        self.world = {
            "vd.sheet.name": "sales.csv",
            "len(vd.sheet.rows)": 1000,
            "vd.sheet.cursorCol.name": "amount",
        }

    def exec_(self, statement):
        self.statements.append(statement)

    def eval_(self, expression):
        self.expressions.append(expression)
        if expression in self.world:
            return self.world[expression]
        if expression.startswith("_roc_"):
            return None                       # registration helpers return nothing
        raise NameError(f"stub has no {expression!r}")

    def report(self, text, is_error):
        self.messages.append((text, is_error))

    def jsonable(self, value):
        return str(value)


def check(condition, what):
    if not condition:
        raise AssertionError(what)
    print(f"  ok: {what}")


def main():
    explicit = sys.argv[1] if len(sys.argv) > 1 else None
    library = find_library(explicit)
    if not library:
        print("engine_test: no libroc_vd_engine.so; run engine/build.sh first",
              file=sys.stderr)
        return 2

    print(f"engine: {library}")
    stub = StubVisiData()
    engine = Engine(library, stub)

    plugin_path = os.path.join(HERE, "..", "examples", "hello.roc")
    print(f"loading: {plugin_path}")
    plugin = RocPlugin(engine, plugin_path)

    check(plugin.kind == KIND_PLUGIN, "hello.roc loads as a plugin")

    # init! should have registered the command.
    registrations = [s for s in stub.expressions if "_roc_add_command" in s]
    check(len(registrations) == 1, "init! registered exactly one command")
    check("roc-hello" in registrations[0], "it registered roc-hello")
    check("zR" in registrations[0], "bound to zR")

    # An event it does not handle should change nothing.
    before = len(stub.statements)
    plugin.event("rowSelected", {"row": 1})
    check(len(stub.statements) == before, "an unhandled event runs no statements")

    # The command it does handle should read the sheet and say something.
    reply = plugin.event("command:roc-hello", {"sheet": "sales.csv"})
    said = [s for s in stub.statements if "vd.status" in s]
    check(len(said) == 1, "the command put one thing on the status line")
    check("sales.csv" in said[0], "it read the sheet name through eval!")
    check("1000 rows" in said[0], "it read the row count through eval!")
    check(reply == 1, f"it replied with its model (got {reply!r})")

    # State survives between events, which is the whole point of the model.
    plugin.event("command:roc-hello", {})
    said = [s for s in stub.statements if "vd.status" in s]
    check("greeting 2" in said[-1], "the model carried over to the next event")

    # Reentrancy is refused rather than deadlocking.
    class Reenterer(StubVisiData):
        def __init__(self, outer):
            super().__init__()
            self.outer = outer
            self.reentered = None

        def eval_(self, expression):
            if "_roc_add_command" not in expression and self.reentered is None:
                try:
                    self.outer[0].event("command:roc-hello", {})
                    self.reentered = "allowed"
                except Exception as e:
                    self.reentered = type(e).__name__
            return super().eval_(expression)

    holder = []
    reenterer = Reenterer(holder)
    engine2 = Engine(library, reenterer)
    plugin2 = RocPlugin(engine2, plugin_path)
    holder.append(plugin2)
    plugin2.event("command:roc-hello", {})
    check(reenterer.reentered == "Reentered",
          f"re-entering a plugin is refused (got {reenterer.reentered!r})")

    plugin.unload()
    plugin2.unload()
    print("\nengine_test: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
