"""VisiData's side of the boundary: what a Roc plugin's effects actually do.

`Engine` (in `_ffi`) knows nothing about VisiData — it calls whatever evaluator
it was given. This is that evaluator for the real thing, plus the handful of
helper functions Roc reaches for by name, which are added to VisiData's globals
so `eval!` can see them.
"""

import datetime
import json
import os

from visidata import vd


class VisiDataBridge:
    """Runs Python in VisiData's globals on a Roc plugin's behalf."""

    def __init__(self):
        self.last_error = None

    # -- what the engine calls ------------------------------------------------

    def exec_(self, statement):
        exec(statement, vd.getGlobals())

    def eval_(self, expression):
        return jsonable(eval(expression, vd.getGlobals()))

    def report(self, text, is_error):
        self.last_error = text if is_error else self.last_error
        if is_error:
            vd.warning(text)
        else:
            vd.status(text)

    def jsonable(self, value):
        return jsonable(value)


def jsonable(value):
    """Turn a VisiData cell into something JSON can carry.

    Dates become ISO-8601 strings, because JSON has no date and losing the
    ordering would be worse than losing the type. Anything else with no JSON
    shape becomes its `str()`, which is what the cell displays anyway.
    """
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    if isinstance(value, (datetime.date, datetime.datetime, datetime.time)):
        return value.isoformat()
    if isinstance(value, (list, tuple)):
        return [jsonable(v) for v in value]
    if isinstance(value, dict):
        return {str(k): jsonable(v) for k, v in value.items()}
    # TypedWrapper and friends stringify to what the cell shows.
    return str(value)


# =============================================================================
# The helpers Roc calls by name, through eval!
# =============================================================================

def _roc_json(text):
    """Decode the JSON argument list `VisiData.call!` sends."""
    return json.loads(text)


def _roc_read_file(path):
    """Read a file for a Roc loader.

    Roc has no file access of its own here — the platform's effects are
    VisiData's, not the operating system's — so a loader asks for the bytes and
    parses them itself.
    """
    with open(os.path.expanduser(path), encoding="utf-8", errors="replace") as f:
        return f.read()


def _roc_add_command(plugin_id, keystrokes, longname, help_text):
    """Define a command that dispatches back into the plugin that asked."""
    from visidata import BaseSheet

    execstr = f"vd.rocDispatch({plugin_id!r}, {'command:' + longname!r})"
    BaseSheet.addCommand(keystrokes or None, longname, execstr, help_text or "")
    return longname


def _roc_bind_key(keystrokes, longname):
    from visidata import BaseSheet

    vd.bindkey(keystrokes, longname, BaseSheet)
    return longname


def _roc_subscribe(plugin_id, hooks):
    """Hear about a VisiData hook, by name."""
    for hook in hooks:
        vd.rocSubscribe(plugin_id, hook)
    return list(hooks)


def _roc_option(name, default, description):
    vd.option(name, default, description)
    return name


def _roc_set_option(name, value):
    vd.options[name] = value
    return value


def _roc_column(name):
    """Every value in one column, in row order."""
    sheet = vd.sheet
    for col in sheet.visibleCols:
        if col.name == name:
            return [jsonable(col.getValue(row)) for row in sheet.rows]
    raise KeyError(f"no column named {name!r} on {sheet.name}")


def _roc_set_cell(row_index, name, value):
    sheet = vd.sheet
    for col in sheet.visibleCols:
        if col.name == name:
            col.setValue(sheet.rows[row_index], value)
            return value
    raise KeyError(f"no column named {name!r} on {sheet.name}")


def _roc_select_rows(indices):
    sheet = vd.sheet
    sheet.selectedRows  # touch, so the cache exists
    for index in indices:
        if 0 <= index < len(sheet.rows):
            sheet.selectRow(sheet.rows[index])
    return len(indices)


def _roc_add_column(name, values):
    from visidata import Column

    sheet = vd.sheet
    by_row = {id(row): value for row, value in zip(sheet.rows, values)}
    col = Column(name, getter=lambda c, r, _v=by_row: _v.get(id(r)))
    sheet.addColumn(col)
    return name


def _roc_push_sheet(name, rows):
    from visidata import ItemColumn, Sheet

    columns = []
    seen = set()
    for row in rows:
        if isinstance(row, dict):
            for key in row:
                if key not in seen:
                    seen.add(key)
                    columns.append(ItemColumn(key))

    sheet = Sheet(name, rows=list(rows), columns=columns or [ItemColumn("value")])
    vd.push(sheet)
    return name


#: Everything above that Roc is allowed to reach by name.
HELPERS = {
    "_roc_json": _roc_json,
    "_roc_read_file": _roc_read_file,
    "_roc_add_command": _roc_add_command,
    "_roc_bind_key": _roc_bind_key,
    "_roc_subscribe": _roc_subscribe,
    "_roc_option": _roc_option,
    "_roc_set_option": _roc_set_option,
    "_roc_column": _roc_column,
    "_roc_set_cell": _roc_set_cell,
    "_roc_select_rows": _roc_select_rows,
    "_roc_add_column": _roc_add_column,
    "_roc_push_sheet": _roc_push_sheet,
}
