## Select the rows whose value in the current column is more than three
## standard deviations from its mean.
##
## The whole column crosses the boundary once, the arithmetic happens in Roc,
## and the selection goes back in one call.
app [Model, plugin] { vd: platform "platform/main.roc" }

import vd.VisiData
import vd.Value

## How many rows we have selected for the user so far.
Model : I64

plugin = { init!, handle! }

init! : () => Try(Model, _)
init! = || {
    VisiData.add_command!("zX", "roc-select-outliers",
        "select rows more than 3 sigma from the mean of this column")
    Ok(0)
}

handle! : Model, VisiData.Event => Try(Model, _)
handle! = |selected_so_far, event|
    if event.name == "command:roc-select-outliers" {
        name = VisiData.cursor_column!()?
        values = VisiData.column_floats!(name)?
        count = U64.to_f64(List.len(values))

        if count == 0.0 {
            VisiData.warning!("${name} has no numbers in it")
            Ok(selected_so_far)
        } else {
            mean = List.sum(values) / count
            variance = List.sum(List.map(values, |x| (x - mean) * (x - mean))) / count
            limit = 3.0 * F64.sqrt(variance)

            # Counting as we go keeps everything I64, which is what
            # `select_rows!` and `Value.Int` both want.
            var $indices = []
            var $index = 0
            var $found = 0
            for value in values {
                if value - mean > limit or mean - value > limit {
                    $indices = $indices.append($index)
                    $found = $found + 1
                }
                $index = $index + 1
            }

            VisiData.select_rows!($indices)
            VisiData.status!("roc: selected ${I64.to_str($found)} outliers in ${name}")
            VisiData.reply!(Value.Int($found))
            Ok(selected_so_far + $found)
        }
    } else {
        Ok(selected_so_far)
    }
