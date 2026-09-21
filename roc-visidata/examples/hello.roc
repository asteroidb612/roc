## The smallest useful plugin: a command that reports on the current sheet.
##
## Drop this in ~/.visidata/roc/ and press z# — there is nothing to build.
app [Model, plugin] { vd: platform "../platform/main.roc" }

import vd.VisiData
import vd.Value

## How many times we have said hello this session.
Model : I64

plugin = { init!, handle! }

init! : () => Try(Model, _)
init! = || {
    VisiData.add_command!("z#", "roc-hello", "say hello, from Roc, inside VisiData")
    Ok(0)
}

handle! : Model, VisiData.Event => Try(Model, _)
handle! = |greetings, event|
    if event.name == "command:roc-hello" {
        sheet = VisiData.sheet_name!()?
        rows = VisiData.nrows!()?
        total = greetings + 1
        VisiData.status!(
            "hello from Roc! ${sheet} has ${I64.to_str(rows)} rows (greeting ${I64.to_str(total)})")
        VisiData.reply!(Value.Int(total))
        Ok(total)
    } else {
        Ok(greetings)
    }
