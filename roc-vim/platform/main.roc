## roc-vim: a Roc platform for writing Vim plugins.
##
## A plugin built with this platform is an ordinary executable. Vim starts it as
## a job at startup and talks to it over a JSON channel, so plugins are loaded
## dynamically when Vim starts and are unloaded when Vim exits.
platform ""
    requires {
        ## What a plugin provides: a program Vim runs. Returning from it ends
        ## the plugin, which usually happens when Vim closes the channel.
        main! : () => Try({}, [Exit(I32), ..])
    }
    exposes [Vim, Value]
    packages {}
    provides { "roc_main": main_for_host! }
    hosted {
        "roc_vim_ex": Host.ex!,
        "roc_vim_normal": Host.normal!,
        "roc_vim_send": Host.send!,
        "roc_vim_eval": Host.eval!,
        "roc_vim_call": Host.call!,
        "roc_vim_reply": Host.reply!,
        "roc_vim_receive": Host.receive!,
        "roc_vim_log": Host.log!,
        "roc_vim_plugin_id": Host.plugin_id!,
    }
    targets: {
        inputs_dir: "targets/",
        x64musl: { inputs: ["crt1.o", "crti.o", "libhost.a", app, "libc.a", "crtn.o"], output: Exe },
        x64v1musl: { inputs: ["crt1.o", "crti.o", "libhost.a", app, "libc.a", "crtn.o"], output: Exe },
        arm64musl: { inputs: ["crt1.o", "crti.o", "libhost.a", app, "libc.a", "crtn.o"], output: Exe },
        arm64v1musl: { inputs: ["crt1.o", "crti.o", "libhost.a", app, "libc.a", "crtn.o"], output: Exe },
        x64glibc: { inputs: ["Scrt1.o", "crti.o", "libhost.a", app, "crtn.o", "libc.so"], output: Exe },
        arm64glibc: { inputs: ["Scrt1.o", "crti.o", "libhost.a", app, "crtn.o", "libc.so"], output: Exe },
    }

import Host
import Vim
import Value

main_for_host! : () => I32
main_for_host! = ||
    match main!() {
        Ok({}) => 0
        Err(Exit(code)) => code
        Err(other) => {
            Host.log!("plugin stopped with an error: ${Str.inspect(other)}")
            1
        }
    }
