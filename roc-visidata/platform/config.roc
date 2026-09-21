## `.visidatarc.roc`: configuring VisiData in Roc.
##
## The same engine as a plugin, with one entrypoint and no model. A config
## runs once, when VisiData starts, after `.visidatarc` so an existing Python
## config still wins on anything both of them set.
platform ""
    requires {
        ## Set VisiData up. Called once, at startup.
        main! : () => Try({}, [VdErr(Str), ..])
    }
    exposes [VisiData, Value]
    packages {}
    provides { "roc_vd_config": config_for_host! }
    hosted {
        "roc_vd_host_exec": Host.exec!,
        "roc_vd_host_eval": Host.eval!,
        "roc_vd_host_reply": Host.reply!,
        "roc_vd_host_id": Host.id!,
    }

import Host
import VisiData
import Value

config_for_host! : () => {}
config_for_host! = || {
    match main!() {
        Ok(_) => {}
        Err(err) => {
            Host.message!("roc-visidata: .visidatarc.roc: ${Str.inspect(err)}", True)
            {}
        }
    }
}
