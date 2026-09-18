## Changing the buffer: `:RocUpper` uppercases a line, or a range of them.
##
##     :RocUpper        the line the cursor is on
##     :5,10RocUpper    lines 5 through 10
##     :%RocUpper       the whole buffer
##
## A command's event carries `line1` and `line2`, which is how Vim passes a
## range to a command.
app [main!] { vim: platform "../platform/main.roc" }

import vim.Vim
import vim.Value

main! : () => Try({}, _)
main! = || {
    Vim.add_command!("RocUpper")
    loop!()
}

loop! : () => Try({}, _)
loop! = ||
    match Vim.receive!() {
        Closed => Ok({})

        Notify(event) => {
            first = Value.int_or(Value.field_or_null(event.data, "line1"), 1)
            last = Value.int_or(Value.field_or_null(event.data, "line2"), first)
            changed = upper!(first, last)?
            Vim.echo!("uppercased ${I64.to_str(changed)} line(s)")
            loop!()
        }

        _ => loop!()
    }

upper! : I64, I64 => Try(I64, _)
upper! = |first, last| {
    var $changed = 0
    for number in first..=last {
        text = Vim.line!(number)?
        louder = Str.with_ascii_uppercased(text)
        $changed = $changed + if louder == text 0 else 1
        Vim.set_line!(number, louder)
    }
    Ok($changed)
}
