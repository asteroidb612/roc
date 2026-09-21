"""Sheets whose data lives on the Roc side.

This is the architecture `bench/RESULTS.md` argues for. A Roc loader parses the
file and keeps the table; VisiData holds row *indices* and asks for the cells it
is about to draw. A million-row file costs a million rows of parsing once, and
about a screenful of cells per keystroke after that — nothing is dragged
through Python per row.

Rows arrive a block at a time rather than a cell at a time, because one request
for the fifty rows about to be drawn beats fifty requests for one row each.
"""

import os

from visidata import Column, Sheet, VisiData, vd

from ._ffi import EngineError

#: How many rows to fetch at once. A screen is ~50; this covers a few pages of
#: scrolling without asking again.
BLOCK = 256


class RocSheet(Sheet):
    """A sheet backed by a Roc loader."""

    rowtype = "rows"  # rowdef: int, the row's index on the Roc side

    def __init__(self, name, loader_path=None, plugin=None, source=None, **kwargs):
        super().__init__(name, source=source, **kwargs)
        self.loader_path = loader_path
        self.plugin = plugin
        self._blocks = {}          # block index -> list of rows (list of str)
        self._ncols = 0

    def ask(self, **request):
        answer = self.plugin.event("loader", request)
        if not isinstance(answer, dict) or not answer.get("ok"):
            reason = (answer or {}).get("err", "the loader did not answer")
            vd.warning(f"roc: {self.plugin.name}: {reason}")
            return None
        return answer

    def iterload(self):
        # Made here, on VisiData's loader thread, so compiling shows up as the
        # sheet taking a moment to open rather than as the UI locking up.
        if self.plugin is None:
            self.plugin = vd.rocInstance(self.loader_path)

        answer = self.ask(q="load", path=str(self.source))
        if answer is None:
            return

        names = answer.get("columns") or []
        self._ncols = len(names)
        self._blocks.clear()
        self.columns = []
        for index, name in enumerate(names):
            self.addColumn(Column(name, getter=self._getter(index)))

        for row in range(answer.get("nrows", 0)):
            yield row

    def _getter(self, column):
        def get(col, row, _c=column):
            fields = self._row(row)
            return fields[_c] if _c < len(fields) else None
        return get

    def _row(self, index):
        """The fields of one row, fetching its block if this is the first ask."""
        block = index // BLOCK
        rows = self._blocks.get(block)
        if rows is None:
            answer = self.ask(q="rows", **{"from": block * BLOCK,
                                           "to": (block + 1) * BLOCK})
            rows = (answer or {}).get("rows") or []
            self._blocks[block] = rows
        offset = index - block * BLOCK
        return rows[offset] if offset < len(rows) else []


@VisiData.api
def rocOpen(vd, loader_path, source):
    """Open `source` with the Roc loader at `loader_path`."""
    name = os.path.basename(str(source))
    sheet = RocSheet(name, loader_path=loader_path, source=source)
    vd.push(sheet)
    return sheet
