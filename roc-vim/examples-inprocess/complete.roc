## Completion: the thing a plugin beside Vim cannot do.
##
## Vim asks a 'completefunc' for matches and waits for the return value, so the
## answer has to come back from a function call, not from a message. A plugin
## loaded into Vim can give it.
##
## Try it: type a few letters of a word that appears elsewhere in the buffer
## and press CTRL-X CTRL-U.
app [Model, plugin] { vim: platform "../platform-inprocess/main.roc" }

import vim.Vim
import vim.Value

## Nothing to remember between events: the buffer is the state.
Model : {}

plugin = { init!, handle! }

init! : () => Try(Model, _)
init! = || {
    # roc#complete is a Vimscript shim that hands the question to this plugin.
    Vim.ex!("let g:roc_complete_plugin = 'complete'")
    Vim.ex!("set completefunc=roc#complete")
    Ok({})
}

handle! : Model, Vim.Event => Try(Model, _)
handle! = |model, event|
    if event.name == "complete" {
        # Vim asks twice: first where the word being completed starts, then
        # for the matches themselves.
        if Value.int_or(Value.field_or_null(event.data, "findstart"), 0) == 1 {
            column = Vim.eval_int!("col('.')")?
            line = Vim.current_line!()?
            Vim.reply!(Value.Int(word_start(line, column)))
            Ok(model)
        } else {
            base = Value.str_or(Value.field_or_null(event.data, "base"), "")
            matches = matching_words!(base)?
            Vim.reply!(Value.Array(matches))
            Ok(model)
        }
    } else {
        Ok(model)
    }

## Where the word before the cursor starts, as a byte index counting from 0.
word_start : Str, I64 -> I64
word_start = |line, column| {
    bytes = line.to_utf8()
    # `col('.')` counts from 1 and points just past the typed text.
    var $index = column - 1
    while $index > 0 {
        previous = List.get(bytes, ($index - 1).to_u64_wrap())
        match previous {
            Ok(byte) =>
                if is_word_byte(byte) {
                    $index = $index - 1
                } else {
                    break
                }
            Err(_) => break
        }
    }
    $index
}

is_word_byte : U8 -> Bool
is_word_byte = |byte|
    (byte >= 'a' and byte <= 'z')
    or (byte >= 'A' and byte <= 'Z')
    or (byte >= '0' and byte <= '9')
    or byte == '_'

## Every distinct word in the buffer that starts with what has been typed.
matching_words! : Str => Try(List(Value), _)
matching_words! = |base| {
    lines = Vim.lines!()?
    var $found = []
    for line in lines {
        for word in words_in(line) {
            is_new = !List.contains($found, word)
            if is_new and word != base and Str.starts_with(word, base) {
                $found = $found.append(word)
            } else {
                {}
            }
        }
    }
    var $matches = []
    for word in $found {
        $matches = $matches.append(Value.Text(word))
    }
    Ok($matches)
}

## Split a line into words, the way Vim's `iskeyword` roughly does.
words_in : Str -> List(Str)
words_in = |line| {
    var $words = []
    var $current = []
    for byte in line.to_utf8() {
        if is_word_byte(byte) {
            $current = $current.append(byte)
        } else {
            $words = push_word($words, $current)
            $current = []
        }
    }
    push_word($words, $current)
}

push_word : List(Str), List(U8) -> List(Str)
push_word = |words, bytes|
    if List.len(bytes) < 2 {
        # One-letter words are noise in a completion list.
        words
    } else {
        match Str.from_utf8(bytes) {
            Ok(word) => words.append(word)
            Err(_) => words
        }
    }
