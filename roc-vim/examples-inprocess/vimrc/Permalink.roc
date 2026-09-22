## Turning `git config remote.origin.url` into a link a browser can open.
##
## This has more edge cases than it looks: ssh vs. https remotes, a trailing
## `.git` that is not always there, and a repo whose name itself contains
## ".git" (`foo.github`, say) which a careless strip would mangle. Nothing
## here imports the platform, so `roc test examples-inprocess/vimrc/Permalink.roc`
## runs it directly.
##
## The Vim half - running `git`, reading the cursor position, writing the
## clipboard - is `github_url!` in main.roc, which is thin on purpose.
Permalink := [].{

    ## Turn a `git config --get remote.origin.url` answer into a URL a browser
    ## can open.
    web_url : Str -> Str
    web_url = |remote| {
        over_https =
            if Str.starts_with(remote, "git@github.com:") {
                "https://github.com/${Str.drop_prefix(remote, "git@github.com:")}"
            } else {
                remote
            }
        # Only a trailing ".git" is the extension. Stripping the first ".git"
        # anywhere in the URL would mangle a repo called "foo.github".
        drop_suffix(over_https, ".git")
    }
}

# =============================================================================
# Private helpers
# =============================================================================

## `text` without `suffix` on the end, if it was there at all.
##
## `Str.drop_last_bytes` says this in one call, but it crashes the interpreter
## these plugins run under, so this counts bytes itself.
drop_suffix : Str, Str -> Str
drop_suffix = |text, suffix|
    if Str.ends_with(text, suffix) {
        keep = Str.count_utf8_bytes(text) - Str.count_utf8_bytes(suffix)
        var $kept = []
        var $index = 0
        for byte in Str.to_utf8(text) {
            if $index < keep {
                $kept = $kept.append(byte)
            } else {
                {}
            }
            $index = $index + 1
        }
        match Str.from_utf8($kept) {
            Ok(shorter) => shorter
            Err(_) => text
        }
    } else {
        text
    }

# =============================================================================
# Tests
# =============================================================================

expect Permalink.web_url("git@github.com:a/b.git") == "https://github.com/a/b"
expect Permalink.web_url("https://github.com/a/b.git") == "https://github.com/a/b"
expect Permalink.web_url("https://github.com/a/b") == "https://github.com/a/b"
# The case the original vimrc got wrong: only a trailing .git is the
# extension, not the first ".git" anywhere in the URL.
expect Permalink.web_url("git@github.com:a/b.github.git") == "https://github.com/a/b.github"
# A remote with no .git suffix at all, ssh form.
expect Permalink.web_url("git@github.com:a/b") == "https://github.com/a/b"
# Not GitHub at all: passed through except for the trailing .git.
expect Permalink.web_url("https://gitlab.com/a/b.git") == "https://gitlab.com/a/b"

expect drop_suffix("hello.git", ".git") == "hello"
expect drop_suffix("hello", ".git") == "hello"
expect drop_suffix(".git", ".git") == ""
expect drop_suffix("", ".git") == ""
