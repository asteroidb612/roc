"""Columns computed in Roc.

A column plugin gets a whole column and returns a whole column, so the boundary
is crossed once per recalculation rather than once per cell. `RocColumn` caches
the result and serves `getter` out of it.

Two honest caveats, measured in `bench/RESULTS.md`:

- Interpreted, the map itself is slower than the Python it replaces. This is
  worth using when the compiled tier is available, or when the column's values
  already live on the Roc side.
- VisiData's display is lazy — `getCell` runs per *visible* cell — so filling a
  whole column eagerly is only a win for whole-column work (sort, aggregate,
  select, save), not for looking at it.
"""

from visidata import Column, Progress, VisiData, vd

from ._ffi import EngineError
from .engine import KIND_COLUMN


class RocColumn(Column):
    """A column whose values come from a Roc `map_floats`, computed in one go."""

    def __init__(self, name, plugin=None, source=None, **kwargs):
        super().__init__(name, **kwargs)
        self.plugin = plugin
        self.source = source        # the column whose values feed the map
        self._values = None

    def calcValue(self, row):
        if self._values is None:
            self._compute()
        return self._values.get(id(row))

    def _compute(self):
        sheet = self.sheet
        rows = sheet.rows
        source = self.source or sheet.cursorCol

        numbers = []
        for row in Progress(rows, "reading"):
            value = source.getValue(row)
            try:
                numbers.append(float(value))
            except (TypeError, ValueError):
                numbers.append(float("nan"))

        try:
            mapped = self.plugin.map_floats(numbers)
        except EngineError as e:
            vd.warning(f"roc: {self.plugin.name}: {e}")
            self._values = {}
            return

        self._values = {id(row): value for row, value in zip(rows, mapped)}

    def recalc(self, sheet=None):
        self._values = None
        super().recalc(sheet)


@VisiData.api
def rocAddColumn(vd, path, source=None):
    """Load a column plugin and add the column it computes to the sheet."""
    plugin = vd.rocLoad(path)
    if plugin is None:
        return None
    if plugin.kind != KIND_COLUMN:
        vd.warning(f"roc: {plugin.name} is a {plugin.kind_name}, not a column")
        return None

    sheet = vd.sheet
    col = RocColumn(plugin.name.removesuffix(".roc"), plugin=plugin,
                    source=source or sheet.cursorCol, type=float)
    sheet.addColumnAtCursor(col)
    return col
