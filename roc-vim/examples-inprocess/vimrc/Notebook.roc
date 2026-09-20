## The poor man's notebook: which fenced code block did you mean?
##
## This is the half of the notebook worth reading carefully. Given the buffer's
## lines and where the cursor is, it answers "which block?" — a question with
## more edge cases than it looks: an unclosed fence, the cursor sitting below
## the last block, fences indented inside a list item.
##
## Nothing here imports the platform, which is the point. A module that imports
## `vim.Vim` can only be compiled as part of a plugin, but this one can be run
## directly:
##
##     roc test examples-inprocess/vimrc/Notebook.roc
##
## The Vim half — reading the buffer, running the code, writing the output back
## — is `run_block!` in main.roc, which is thin on purpose.
Notebook := [].{

    ## A fenced block, in Vim's line numbering: `open` and `close` are the fence
    ## lines themselves, and `code` is what lies between them.
    Block : { open : I64, close : I64, code : List(Str) }

    ## The fenced block the cursor is in, or the last one above it.
    ##
    ## Fences pair up in order — the first opens a block, the second closes it —
    ## which is what keeps the cursor sitting *below* a block from pairing that
    ## block's closing fence with the next block's opening one.
    find_block : List(Str), I64 -> Try(Block, [NoBlock])
    find_block = |lines, here| {
        var $fences = []
        var $row = 0
        for line in lines {
            $row = $row + 1
            if Str.starts_with(Str.trim_start(line), "```") {
                $fences = $fences.append($row)
            } else {
                {}
            }
        }

        var $open = 0
        var $close = 0
        var $index = 0
        while $index + 1 < List.len($fences) {
            opens = row_at($fences, $index)
            closes = row_at($fences, $index + 1)
            if opens <= here {
                $open = opens
                $close = closes
            } else {
                {}
            }
            $index = $index + 2
        }

        if $open == 0 {
            Err(NoBlock)
        } else {
            Ok({ open: $open, close: $close, code: between(lines, $open + 1, $close - 1) })
        }
    }
}

# =============================================================================
# Private helpers
# =============================================================================

row_at : List(I64), U64 -> I64
row_at = |rows, index|
    match List.get(rows, index) {
        Ok(row) => row
        Err(_) => 0
    }

## The lines from `first` to `last`, counting from 1 as Vim does.
between : List(Str), I64, I64 -> List(Str)
between = |lines, first, last| {
    var $chosen = []
    var $row = 0
    for line in lines {
        $row = $row + 1
        if $row >= first and $row <= last {
            $chosen = $chosen.append(line)
        } else {
            {}
        }
    }
    $chosen
}

# =============================================================================
# Tests
#
# `roc test examples-inprocess/vimrc/Notebook.roc` runs these. No Vim, no
# plugin, no platform: find_block is a function from lines and a cursor to a
# block, so it can be asked directly.
# =============================================================================

## The buffer most of the tests below work on.
##
##      1  # notes
##      2  (blank)
##      3  ```
##      4  echo one
##      5  ```
##      6  (blank)
##      7  ```
##      8  echo two
##      9  ```
##     10  after
two_blocks : List(Str)
two_blocks = [
    "# notes",
    "",
    "```",
    "echo one",
    "```",
    "",
    "```",
    "echo two",
    "```",
    "after",
]

code_at : List(Str), I64 -> List(Str)
code_at = |lines, here|
    match Notebook.find_block(lines, here) {
        Ok(block) => block.code
        Err(NoBlock) => ["<no block>"]
    }

close_at : List(Str), I64 -> I64
close_at = |lines, here|
    match Notebook.find_block(lines, here) {
        Ok(block) => block.close
        Err(NoBlock) => 0
    }

found : List(Str), I64 -> Bool
found = |lines, here|
    match Notebook.find_block(lines, here) {
        Ok(_) => Bool.True
        Err(NoBlock) => Bool.False
    }

# The cursor inside a block finds that block, wherever in it the cursor sits.
expect code_at(two_blocks, 3) == ["echo one"]
expect code_at(two_blocks, 4) == ["echo one"]
expect code_at(two_blocks, 5) == ["echo one"]
expect code_at(two_blocks, 8) == ["echo two"]

# The cursor between two blocks belongs to the one above it, not the one below.
expect code_at(two_blocks, 6) == ["echo one"]

# The cursor below the last block finds the last block. This is the case the
# original vimrc got wrong: searching backwards for ``` from line 10 lands on
# the closing fence of block two, and then searching forwards for the next ```
# runs off the end.
expect code_at(two_blocks, 10) == ["echo two"]

# The output is inserted after the *closing* fence, so it lands below the
# block rather than inside it.
expect close_at(two_blocks, 4) == 5
expect close_at(two_blocks, 8) == 9

# Above every block there is nothing to run.
expect !found(two_blocks, 1)
expect !found(two_blocks, 2)

# A buffer with no fences at all.
expect !found(["just", "some", "prose"], 2)

# An unclosed fence is not a block: one fence cannot pair with anything, and
# running to the end of the buffer is not what anyone meant.
expect !found(["```", "echo one"], 2)
expect !found(["# notes", "", "```", "echo one"], 4)

# A block can hold several lines, and blank ones.
expect code_at(["```", "one", "", "two", "```"], 2) == ["one", "", "two"]

# An empty block has no code, but is still a block.
expect code_at(["```", "```", "after"], 1) == []

# Fences indented inside a list item still count.
expect code_at(["- like this:", "  ```", "  echo one", "  ```"], 3) == ["  echo one"]

# Three blocks in a row: the pairing has to keep up.
three_blocks : List(Str)
three_blocks = ["```", "a", "```", "```", "b", "```", "```", "c", "```"]

expect code_at(three_blocks, 2) == ["a"]
expect code_at(three_blocks, 5) == ["b"]
expect code_at(three_blocks, 8) == ["c"]
