"""Roc loaders: the table lives on the Roc side.

Covers what broke when loaders were first made to work well: two sheets over
the same loader must not share one table, a loader must never be swapped from
under a sheet by a background upgrade, and a numeric column must come back as
numbers rather than as JSON.

    python3 test/loader_test.py
"""

import os
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "python"))

from visidata import vd                                    # noqa: E402

import visidata_roc                                        # noqa: E402,F401
from visidata_roc.loader import (BLOCK, RocFloatColumn,    # noqa: E402
                                 RocTextColumn)
from visidata_roc.tier2 import find_compiler               # noqa: E402

LOADER = os.path.join(HERE, "..", "examples", "tsv_loader.roc")


def check(condition, what):
    if not condition:
        raise AssertionError(what)
    print(f"  ok: {what}")


def write_tsv(path, rows, header="name\tamount\tregion"):
    with open(path, "w") as f:
        f.write(header + "\n")
        for i in range(rows):
            f.write(f"row{i}\t{i}.5\t{'east' if i % 2 else 'west'}\n")


def settled(sheet, timeout=600):
    """Wait for an async iterload to stop adding rows."""
    previous = -1
    deadline = time.time() + timeout
    while time.time() < deadline:
        count = len(sheet.rows)
        if count and count == previous:
            return sheet
        previous = count
        time.sleep(0.1)
    return sheet


def main():
    compiled = bool(find_compiler())
    print(f"compiler: {'yes' if compiled else 'no (loaders will be interpreted)'}")
    # Interpreted loaders are ~240 us/row, so keep the file small without one.
    rows = 2000 if compiled else 40

    work = tempfile.mkdtemp(prefix="roc-visidata-loader-")
    try:
        first = os.path.join(work, "first.tsv")
        second = os.path.join(work, "second.tsv")
        write_tsv(first, rows)
        write_tsv(second, rows // 2, header="name\tamount")

        a = settled(vd.rocOpen(LOADER, first))
        b = settled(vd.rocOpen(LOADER, second))

        check(len(a.rows) == rows, f"the first sheet read its own file ({len(a.rows)} rows)")
        check(len(b.rows) == rows // 2, f"the second read its own ({len(b.rows)} rows)")
        check(a.plugin.handle != b.plugin.handle,
              "each sheet got its own loader instance")
        check([c.name for c in a.columns] == ["name", "amount", "region"],
              "the first sheet has its own columns")
        check([c.name for c in b.columns] == ["name", "amount"],
              "and the second has its own, which is what sharing one table broke")

        if compiled:
            check(a.plugin.transport == "compiled",
                  "a loader is compiled up front, not upgraded under the sheet")

        # A column of numbers comes back as numbers.
        amount = [c for c in a.columns if c.name == "amount"][0]
        name = [c for c in a.columns if c.name == "name"][0]
        check(isinstance(amount, RocFloatColumn),
              "the numeric column was detected and uses the typed path")
        check(not isinstance(name, RocFloatColumn),
              "the text column was not")

        values = [amount.getValue(r) for r in a.rows]
        check(len(values) == rows, "the typed column has a value per row")
        check(values[0] == 0.5 and values[-1] == rows - 1 + 0.5,
              f"its values are right ({values[0]}, {values[-1]})")
        check(all(isinstance(v, float) for v in values),
              "and they are floats, not text")

        # Text reads block by block while browsing, and whole once scanned.
        check(isinstance(name, RocTextColumn), "the text column is the adaptive one")
        check(name.getValue(a.rows[0]) == "row0", "text cells read from the first block")
        check(name.getValue(a.rows[-1]) == f"row{rows - 1}",
              "and from the last, which needs another block")
        check(name._whole is None,
              "browsing a few rows does not pull the whole column")

        if rows > BLOCK * 5:
            name.recalc()
            scanned = [name.getValue(r) for r in a.rows]
            check(name._whole is not None,
                  "scanning every row switches it to the whole column")
            check(scanned[0] == "row0" and scanned[-1] == f"row{rows - 1}",
                  "and the values are the same either way")
            check(len(scanned) == rows, "with one per row")

        # A loader can claim a file extension, so `vd file.rtsv` just works.
        from visidata import Path
        from visidata_roc.bridge import _roc_register_loader

        _roc_register_loader("rtsv", os.path.abspath(LOADER))
        claimed = os.path.join(work, "third.rtsv")
        write_tsv(claimed, rows // 4)
        by_extension = vd.openSource(Path(claimed))
        check(type(by_extension).__name__ == "RocSheet",
              "openSource routes a claimed extension to the Roc loader")
        vd.sheets = [by_extension]
        by_extension.reload()
        settled(by_extension)
        check(len(by_extension.rows) == rows // 4,
              f"and it read the file ({len(by_extension.rows)} rows)")

        # Failing well matters as much as working.
        missing = vd.rocOpen(LOADER, os.path.join(work, "not-here.tsv"))
        missing.reload()
        time.sleep(3)
        said = " ".join(str(s) for s in vd.statuses)
        check(len(missing.rows) == 0 and "No such file" in said,
              "a missing file is reported, not crashed on")

        empty_path = os.path.join(work, "empty.tsv")
        open(empty_path, "w").close()
        empty = vd.rocOpen(LOADER, empty_path)
        empty.reload()
        time.sleep(3)
        check(len(empty.rows) == 0 and not empty.columns,
              "an empty file is an empty sheet, with no phantom column")

        not_a_loader = vd.rocOpen(
            os.path.join(HERE, "..", "examples", "hello.roc"), first)
        not_a_loader.reload()
        time.sleep(3)
        said = " ".join(str(s) for s in vd.statuses)
        check("is not a loader" in said,
              "a plugin used as a loader says so")

        vd.rocUnloadAll()
        print("\nloader_test: all checks passed")
        return 0
    finally:
        import shutil
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
