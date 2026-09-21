## A TSV loader written in Roc, where Roc keeps the table.
##
## VisiData has its own TSV loader, which makes this the fair comparison for
## what a Roc loader is worth: same file, same shape, one in Python and one
## here. See bench/RESULTS.md.
##
## The table never leaves Roc. VisiData asks for the screenful it is about to
## draw and gets that, so a million-row file costs a million rows of parsing
## once and about fifty cells per keystroke after that.
app [Table, loader] { vd: platform "platform/loader.roc" }

import vd.VisiData

## The header, and every row already split into its fields.
Table : {
    header : List(Str),
    rows : List(List(Str)),
}

loader = { load!, columns, nrows, cell, col_f64 }

load! : Str => Try(Table, _)
load! = |path| {
    text = VisiData.eval_str!("_roc_read_file(${VisiData.quote(path)})")?
    lines = Str.split_on(text, "\n")

    match lines {
        [] => Ok({ header: [], rows: [] })
        [first, .. as rest] => {
            header = Str.split_on(first, "\t")
            var $rows = []
            for line in rest {
                if line != "" {
                    $rows = $rows.append(Str.split_on(line, "\t"))
                }
            }
            Ok({ header: header, rows: $rows })
        }
    }
}

columns : Table -> List(Str)
columns = |table| table.header

nrows : Table -> I64
nrows = |table|
    match List.len(table.rows).to_i64_try() {
        Ok(n) => n
        Err(_) => 0
    }

## Narrowing a signed index to an unsigned one can fail, so it is a `Try`:
## anything out of range reads as an empty cell rather than crashing the sheet.
cell : Table, I64, I64 -> Str
cell = |table, row, column|
    match (row.to_u64_try(), column.to_u64_try()) {
        (Ok(r), Ok(c)) =>
            match List.get(table.rows, r) {
                Ok(fields) =>
                    match List.get(fields, c) {
                        Ok(text) => text
                        Err(_) => ""
                    }
                Err(_) => ""
            }
        _ => ""
    }

## One column as numbers. Anything unparseable becomes NaN so the list still
## lines up with the rows — dropping them would misalign every row after.
col_f64 : Table, I64 -> List(F64)
col_f64 = |table, column|
    match column.to_u64_try() {
        Ok(c) =>
            List.map(table.rows, |fields|
                match List.get(fields, c) {
                    Ok(text) =>
                        match F64.from_str(text) {
                            Ok(number) => number
                            Err(_) => F64.nan
                        }
                    Err(_) => F64.nan
                })
        Err(_) => []
    }
