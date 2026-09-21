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
        "roc_vd_host_message": Host.message!,
        "roc_vd_host_reply": Host.reply!,
        "roc_vd_host_reply_floats": Host.reply_floats!,
        "roc_vd_host_id": Host.id!,
    }
    # The compiled tier; see platform/build.sh. The interpreted tier ignores it.
    targets: {
        inputs_dir: "targets/",
        x64glibc: { inputs: ["libhost.a", app], output: Shared },
        arm64glibc: { inputs: ["libhost.a", app], output: Shared },
        x64musl: { inputs: ["libhost.a", app], output: Shared },
        arm64musl: { inputs: ["libhost.a", app], output: Shared },
        x64mac: { inputs: ["libhost.a", app], output: Shared },
        arm64mac: { inputs: ["libhost.a", app], output: Shared },
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
