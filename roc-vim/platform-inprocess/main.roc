## roc-vim, in-process: a Roc platform for plugins that run inside Vim.
##
## A plugin built with this platform is a shared library. A Vim built with the
## `+roc` feature loads it with `roc_load()`, so the plugin's code runs in
## Vim's own process and its effects are direct calls rather than messages.
##
## Vim keeps the main loop, so a plugin is shaped as a model and a handler:
## `init!` makes the first model, and `handle!` gets the model and whatever
## just happened, and returns the next one.
platform ""
    requires {
        [Model : model] for plugin : {
            ## Set the plugin up and return its first model. Called once, when
            ## Vim loads the plugin.
            init! : () => Try(model, [VimErr(Str), ..]),
            ## Handle one event and return the next model.
            handle! : model, Vim.Event => Try(model, [VimErr(Str), ..]),
        }
    }
    exposes [Vim, Value]
    packages {}
    provides {
        "roc_vim_init": init_for_host!,
        "roc_vim_handle": handle_for_host!,
    }
    hosted {
        "roc_vim_host_ex": Host.ex!,
        "roc_vim_host_eval": Host.eval!,
        "roc_vim_host_message": Host.message!,
        "roc_vim_host_reply": Host.reply!,
        "roc_vim_host_id": Host.id!,
    }
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
import Vim
import Value

## Build the first model. The host keeps the box and hands it back on every
## event, which is how a plugin keeps state without a mutable global.
init_for_host! : () => Box(Model)
init_for_host! = || {
    match (plugin.init!)() {
        Ok(model) => Box.box(model)
        Err(err) => {
            Host.message!("roc-vim: plugin failed to start: ${Str.inspect(err)}", True)
            crash "roc-vim plugin failed to start"
        }
    }
}

## Decode what Vim sent, hand it to the plugin, and box the model it returns.
## An error leaves the model as it was, so one bad event does not lose state.
handle_for_host! : Box(Model), Str => Box(Model)
handle_for_host! = |boxed_model, event_json| {
    model = Box.unbox(boxed_model)
    event = decode_event(event_json)
    match (plugin.handle!)(model, event) {
        Ok(next) => Box.box(next)
        Err(err) => {
            Host.message!("roc-vim: ${event.name}: ${Str.inspect(err)}", True)
            # `Box.unbox` consumed the box that came in, so hand back a new one
            # holding the model the plugin started this event with.
            Box.box(model)
        }
    }
}

decode_event : Str -> Vim.Event
decode_event = |text|
    match Value.parse(text) {
        Ok(message) => {
            name: Value.str_or(Value.field_or_null(message, "event"), ""),
            data: Value.field_or_null(message, "data"),
        }
        Err(_) => { name: "", data: Value.Null }
    }

# =============================================================================
# Tests
# =============================================================================

expect decode_event("{\"event\":\"BufWritePost\",\"data\":{\"file\":\"a.md\"}}") == { name: "BufWritePost", data: Value.Object([("file", Value.Text("a.md"))]) }
expect decode_event("{\"event\":\"go\"}") == { name: "go", data: Value.Null }
# Not JSON at all: no event to hand the plugin, rather than a crash.
expect decode_event("not json") == { name: "", data: Value.Null }
# No "event" field: same fallback.
expect decode_event("{}") == { name: "", data: Value.Null }
