# The versions roc-vim is built and tested against.
#
# Everything that needs a version number reads it from here, so there is one
# place to change when moving to a newer compiler. Scripts use it as:
#
#     . "$repo/versions.sh"
#
# One Roc compiler builds everything. The channel platform would be happy with
# a released nightly, but the in-process platform needs the shared-library fix
# and the source-loading engine needs the embedding library, both of which come
# from compiler-patch/. Rather than keep two compilers around and have to think
# about which one built what, roc-vim uses the patched one for all of it, and
# accepts being a little behind the nightlies.

# roc-lang/roc, the commit compiler-patch/*.patch are made against.
ROC_VIM_ROC_COMMIT=1d982dca644aaddf1cc858f8580fadccf025358b
ROC_VIM_ROC_DATE=2026-09-18

# The Zig that compiler builds with (see roc's build.zig.zon).
ROC_VIM_ZIG_VERSION=0.16.0

# The Vim vim-patch/vim-roc-interface.patch is made against.
ROC_VIM_VIM_TAG=v9.2.1119

# Where build-roc.sh and build-vim.sh leave what they build, relative to this
# directory. Everything else looks here first.
ROC_VIM_ROC_BUILD=compiler-patch/build/roc
ROC_VIM_VIM_BUILD=vim-patch/build/vim

# roc_vim_is_program <path>: an existing file we can run. `-x` alone says yes
# to a directory, and $VIM is a directory whenever Vim itself set it.
roc_vim_is_program() {
    [ -n "$1" ] && [ -f "$1" ] && [ -x "$1" ]
}

# roc_vim_find_roc <repo>: print the path to a Roc compiler, or nothing.
#
# $ROC wins, then the one this repository built, then PATH. The repository's
# own build comes before PATH on purpose: a machine with a released Roc
# installed should still get the compiler the platforms were built against,
# because a released one cannot build in-process plugins.
roc_vim_find_roc() {
    if roc_vim_is_program "${ROC:-}"; then
        printf '%s\n' "$ROC"
        return 0
    fi
    if roc_vim_is_program "$1/$ROC_VIM_ROC_BUILD/zig-out/bin/roc"; then
        printf '%s\n' "$1/$ROC_VIM_ROC_BUILD/zig-out/bin/roc"
        return 0
    fi
    command -v roc 2>/dev/null || true
}

# roc_vim_find_vim <repo>: the same, for Vim. $VIM_BIN is the one to set;
# $VIM is accepted too, but ignored when it holds Vim's runtime directory
# rather than a program, which is what Vim exports into its own shells.
roc_vim_find_vim() {
    for candidate in "${VIM_BIN:-}" "${VIM:-}" "$1/$ROC_VIM_VIM_BUILD/src/vim"; do
        if roc_vim_is_program "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    command -v vim 2>/dev/null || true
}
