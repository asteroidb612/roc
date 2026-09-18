#!/usr/bin/env sh
#
# Set up roc-vim: build the platform's host, install the Vim side, and leave a
# plugin directory ready for your own .roc files.
#
# Usage: ./setup.sh [--examples] [--vim-dir DIR]
#   --examples      copy every example into the plugin directory, not just hello
#   --vim-dir DIR   install into DIR instead of ~/.vim

set -eu

repo=$(cd "$(dirname "$0")" && pwd)
vim_dir="${HOME}/.vim"
copy_all_examples=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --examples) copy_all_examples=1 ;;
        --vim-dir) shift; vim_dir=$1 ;;
        -h | --help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

say() { printf 'roc-vim: %s\n' "$1"; }

# ---------------------------------------------------------------------------
# What we need
# ---------------------------------------------------------------------------

if ! command -v vim >/dev/null 2>&1; then
    say "vim is not installed. Install it (e.g. 'sudo apt install vim'), then run this again."
    exit 1
fi

if ! vim --version | grep -q '+channel'; then
    say "this vim was built without +channel, so it cannot run plugins as jobs."
    say "Install a full Vim 8 or later (on Debian/Ubuntu: 'sudo apt install vim-nox')."
    exit 1
fi

if ! command -v roc >/dev/null 2>&1; then
    say "warning: the roc compiler is not on your PATH."
    say "Plugins are built with it, so install Roc from https://roc-lang.org/install"
    say "or set g:roc_command in your vimrc to point at it."
fi

# ---------------------------------------------------------------------------
# The native host
# ---------------------------------------------------------------------------

say "building the platform host"
"$repo/platform/build.sh"

# ---------------------------------------------------------------------------
# The Vim side
# ---------------------------------------------------------------------------

pack_dir="$vim_dir/pack/roc/start"
mkdir -p "$pack_dir"

if [ -L "$pack_dir/roc-vim" ]; then
    rm -f "$pack_dir/roc-vim"
elif [ -e "$pack_dir/roc-vim" ]; then
    say "$pack_dir/roc-vim already exists and is not a link; leaving it alone."
    say "Point it at $repo/vim yourself, or remove it and run this again."
    exit 1
fi
ln -s "$repo/vim" "$pack_dir/roc-vim"
say "installed the Vim plugin at $pack_dir/roc-vim"

if [ -d "$repo/vim/doc" ]; then
    vim -u NONE -es -c "helptags $repo/vim/doc" -c quit >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# The plugin directory
# ---------------------------------------------------------------------------

plugin_dir="$vim_dir/roc"
mkdir -p "$plugin_dir"

# Plugins refer to the platform by relative path, so put it one level down.
if [ -L "$plugin_dir/platform" ]; then
    rm -f "$plugin_dir/platform"
fi
if [ -e "$plugin_dir/platform" ]; then
    say "$plugin_dir/platform already exists and is not a link; leaving it alone."
else
    ln -s "$repo/platform" "$plugin_dir/platform"
fi

if [ "$copy_all_examples" -eq 1 ]; then
    examples="hello word_count uppercase ticker"
else
    examples="hello"
fi

for example in $examples; do
    destination="$plugin_dir/$example.roc"
    if [ -e "$destination" ]; then
        say "keeping your $destination"
        continue
    fi
    sed 's|"../platform/main.roc"|"platform/main.roc"|' \
        "$repo/examples/$example.roc" > "$destination"
    say "added $destination"
done

cat <<EOF

Done. Start vim and try :RocHello

Your plugins live in $plugin_dir - every .roc file there is built if needed and
started when Vim starts. Useful commands:

    :RocPlugins     what is running
    :RocLog         what your plugins have logged, and build errors
    :RocRestart     rebuild and restart everything

Saving a plugin's source rebuilds and restarts it, so the edit-run loop is just
:w. The other examples are in $repo/examples.
EOF
