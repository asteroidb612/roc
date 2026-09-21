## roc-visidata: a Roc platform for VisiData plugins.
##
## A plugin runs inside VisiData's process, compiled there from its source, so
## its effects are direct calls rather than messages and there is nothing to
## build first.
##
## VisiData keeps the main loop, so a plugin is shaped as a model and a
## handler: `init!` makes the first model, and `handle!` gets the model and
## whatever just happened, and returns the next one.
platform ""
    requires {
        [Model : model] for plugin : {
            ## Set the plugin up and return its first model. Called once, when
            ## VisiData loads the plugin.
            init! : () => Try(model, [VdErr(Str), ..]),
            ## Handle one event and return the next model.
            handle! : model, VisiData.Event => Try(model, [VdErr(Str), ..]),
        }
    }
    exposes [VisiData, Value]
    packages {}
    provides {
        "roc_vd_init": init_for_host!,
        "roc_vd_handle": handle_for_host!,
    }
    hosted {
        "roc_vd_host_exec": Host.exec!,
        "roc_vd_host_eval": Host.eval!,
        "roc_vd_host_message": Host.message!,
        "roc_vd_host_reply": Host.reply!,
        "roc_vd_host_reply_floats": Host.reply_floats!,
        "roc_vd_host_read_file": Host.read_file!,
        "roc_vd_host_id": Host.id!,
    }
    # The compiled tier: a plugin built for it is a shared library VisiData
    # dlopens. Building one needs `build.sh` to have made targets/libhost.a
    # first; the interpreted tier ignores all of this.
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

## Build the first model. The host keeps the box and hands it back on every
## event, which is how a plugin keeps state without a mutable global.
init_for_host! : () => Box(Model)
init_for_host! = || {
    match (plugin.init!)() {
        Ok(model) => Box.box(model)
        Err(err) => {
            Host.message!("roc-visidata: plugin failed to start: ${Str.inspect(err)}", True)
            crash "roc-visidata plugin failed to start"
        }
    }
}

## Decode what VisiData sent, hand it to the plugin, and box the model it
## returns. An error leaves the model as it was, so one bad event does not lose
## state.
handle_for_host! : Box(Model), Str => Box(Model)
handle_for_host! = |boxed_model, event_json| {
    model = Box.unbox(boxed_model)
    event = decode_event(event_json)
    match (plugin.handle!)(model, event) {
        Ok(next) => Box.box(next)
        Err(err) => {
            Host.message!("roc-visidata: ${event.name}: ${Str.inspect(err)}", True)
            # `Box.unbox` consumed the box that came in, so hand back a new one
            # holding the model the plugin started this event with.
            Box.box(model)
        }
    }
}

decode_event : Str -> VisiData.Event
decode_event = |text|
    match Value.parse(text) {
        Ok(message) => {
            name: Value.str_or(Value.field_or_null(message, "event"), ""),
            data: Value.field_or_null(message, "data"),
        }
        Err(_) => { name: "", data: Value.Null }
    }
