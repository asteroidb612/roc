"""roc-visidata inside real VisiData, with no terminal.

VisiData is importable without curses as long as nothing draws, so this loads
the package, makes a real sheet, loads a real plugin, and runs its command the
way a keypress would — through the execstr the plugin registered.

    python3 test/visidata_test.py
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "python"))

from visidata import BaseSheet, Sheet, ItemColumn, vd     # noqa: E402

import visidata_roc                                        # noqa: E402,F401


def check(condition, what):
    if not condition:
        raise AssertionError(what)
    print(f"  ok: {what}")


def make_sheet():
    rows = [{"name": f"row{i}", "amount": i * 1.5} for i in range(1000)]
    sheet = Sheet("sales.csv", rows=rows,
                  columns=[ItemColumn("name"), ItemColumn("amount", type=float)])
    sheet.rows = rows
    vd.sheets = [sheet]
    return sheet


def main():
    sheet = make_sheet()
    check(vd.sheet is sheet, "a sheet is current")

    # Load the plugin the way startup would.
    plugin = vd.rocLoad(os.path.join(HERE, "..", "examples", "hello.roc"))
    check(plugin is not None, "hello.roc compiled inside VisiData")
    check(plugin.kind_name == "plugin", "it loaded as a plugin")

    # init! registered a command through the real addCommand.
    registered = vd.commands.get("roc-hello", BaseSheet)
    check(registered, "roc-hello is a real VisiData command")
    command = registered["BaseSheet"]
    check("rocDispatch" in command.execstr, "it dispatches back into Roc")

    # Run it the way a keypress does: exec the execstr in VisiData's globals.
    statuses_before = len(vd.statuses)
    exec(command.execstr, vd.getGlobals(), {"sheet": sheet})
    said = " ".join(str(s) for s in vd.statuses)
    check("hello from Roc" in said, f"the command said hello (statuses: {vd.statuses})")
    check("sales.csv" in said, "it read the real sheet's name")
    check("1000 rows" in said, "it read the real row count")

    # The plugins sheet lists it.
    plugins_sheet = vd.rocPluginsSheet()
    listed = list(plugins_sheet.iterload())
    check(any(r.name == "hello.roc" and r.kind == "plugin" for r in listed),
          ":RocPlugins lists the plugin")

    # A hook reaches a subscriber.
    vd.rocSubscribe(plugin.handle, "rowSelected")
    events_before = plugin.events
    vd.rocHook("rowSelected", {"row": 1})
    check(plugin.events == events_before + 1, "a hook reached the plugin")

    # A config runs its main! at load.
    config = vd.rocLoad(os.path.join(HERE, "..", "examples", "visidatarc.roc"))
    check(config is not None and config.kind_name == "config",
          "visidatarc.roc loads as a config")
    said = " ".join(str(s) for s in vd.statuses)
    check("visidatarc.roc loaded" in said, "the config ran its main!")
    check(str(vd.options.disp_float_fmt) == "{:.2f}",
          f"the config set a real option (got {vd.options.disp_float_fmt!r})")

    # A column plugin computes the whole column in one crossing.
    column = vd.rocLoad(os.path.join(HERE, "..", "examples", "zscore.roc"))
    check(column is not None and column.kind_name == "column",
          "zscore.roc loads as a column")
    zs = column.map_floats([1.0, 2.0, 3.0, 4.0, 5.0])
    check(len(zs) == 5, "it returned a value per row")
    check(abs(zs[2]) < 1e-9, "the middle of 1..5 is at the mean")
    check(abs(zs[0] + 1.41421356) < 1e-6, f"the first is -sqrt(2) sigma (got {zs[0]})")

    # And as a real column on a real sheet.
    sheet.cursorVisibleColIndex = 1
    col = vd.rocAddColumn(os.path.join(HERE, "..", "examples", "zscore.roc"))
    check(col is not None, "roc-addcol added a column to the sheet")
    first = col.getValue(sheet.rows[0])
    check(isinstance(first, float), f"it computes a real value (got {first!r})")

    # A plugin that reads a whole column and selects rows.
    outliers = vd.rocLoad(os.path.join(HERE, "..", "examples", "outliers.roc"))
    check(outliers is not None, "outliers.roc compiled")
    sheet.rows.append({"name": "huge", "amount": 1e6})
    sheet.clearSelected()
    # Put the cursor back on the source column: adding the z-score column moved it.
    for i, c in enumerate(sheet.visibleCols):
        if c.name == "amount":
            sheet.cursorVisibleColIndex = i
            break
    check(sheet.cursorCol.name == "amount", "the cursor is on the amount column")
    replied = outliers.event("command:roc-select-outliers", vd.rocContext())
    check(replied == 1, f"it found the one outlier (replied {replied!r})")
    check(len(sheet.selectedRows) == 1, "and selected it on the real sheet")

    vd.rocUnloadAll()
    check(not vd.rocPlugins, "unloading clears the registry")
    print("\nvisidata_test: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
