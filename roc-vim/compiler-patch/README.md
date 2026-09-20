# Roc compiler patches

Two patches live here. `roc-shared-library-static-data.patch` lets Roc build a
real program as a shared library, which in-process plugins are.
`roc-embed-library.patch` adds an embedding library, which is what lets Vim
compile and run a plugin from its source without building anything.

`build-roc.sh` does the whole thing — clone at the pinned commit, apply both
patches, build the compiler and the library:

```sh
./build-roc.sh
```

It leaves `build/roc/zig-out/bin/roc` and `build/roc/zig-out/lib/libroc_embed.a`,
which is where `embed/build.sh`, `setup.sh` and the tests all look, so nothing
downstream needs to be told where they are. `--compiler-only` skips the
library, which is much quicker if you do not want source loading; `--debug`
builds unoptimized, which is faster to build and produces a ~3GB binary.

The commit and the Zig version are pinned in [`../versions.sh`](../versions.sh)
— `1d982dca` (2026-09-18) and Zig 0.16.0 — and that is the only place to change
them.

**This is the only Roc compiler roc-vim uses.** A released nightly can build
channel plugins, but not in-process ones (they need the shared-library fix) and
not source loading (that needs the embedding library). Keeping one patched
compiler for all three is simpler than remembering which compiler built what,
at the cost of trailing the nightlies a little.

By hand, if you would rather:

```sh
git clone https://github.com/roc-lang/roc.git && cd roc
git checkout 1d982dca644aaddf1cc858f8580fadccf025358b
git apply /path/to/roc-shared-library-static-data.patch
git apply /path/to/roc-embed-library.patch
zig build roc -Doptimize=ReleaseSafe
zig build roc-embed -Doptimize=ReleaseSafe
```

## roc-shared-library-static-data.patch

In-process plugins are shared libraries, which Roc knows how to build
(`output: Shared` in a platform's `targets:` section). One thing stops it
working for a real plugin: the object Roc emits for a program's **static data**
— every string literal in the program — puts that data in a read-only section
with absolute relocations. A shared library's data is placed at load time, so
the dynamic linker has to rewrite those pointers, and it cannot write a
read-only section. The link fails:

```
ld.lld: error: relocation R_X86_64_64 cannot be used against symbol
        'roc__ctfe_1_1'; recompile with -fPIC
>>> defined in .../roc_static_data_x64glibc.o
```

`roc-shared-library-static-data.patch` marks that section writable when, and
only when, the output is a shared library — which is what a C compiler does for
`.data.rel.ro`. The generated code was already position-independent for shared
output (`llvmObjectUsesPic`), so this is the last piece.

It is 43 lines across four files, made against roc-lang/roc commit
`1d982dca644aaddf1cc858f8580fadccf025358b` (2026-09-18):

| File | Change |
| --- | --- |
| `src/backend/dev/object/elf.zig` | a `rodata_writable` flag that adds `SHF_WRITE` |
| `src/backend/dev/ObjectWriter.zig` | an `ObjectOptions` struct to carry it |
| `src/backend/dev/ObjectFileCompiler.zig` | pass it through to the static-data object |
| `src/cli/main.zig` | set it when `link_type == .shared` |

## roc-embed-library.patch

`zig build roc-embed` builds `libroc_embed.a`: the compiler, plus a C API for
running Roc source inside another program. It is a new file
(`src/embed/main.zig`, ~600 lines) and a build target; nothing existing
changes, so a compiler built from this patch behaves exactly as before.

The library follows the embedding sequence the compiler already documents in
`src/echo_platform/runner.zig`: build the checked artifacts, lower them to LIR,
materialize the static data, and run an entrypoint through the interpreter with
a `RocOps` the host supplies. What it adds is the C boundary around that, and
binding the platform's hosted functions to the host's own C functions by name:

```c
void *program = roc_embed_open(path, len, ctx, resolve_hosted, &error);
int   ordinal = roc_embed_entrypoint(program, "roc_vim_handle", 14);
roc_embed_call(program, ordinal, args, &result, &error);
```

`roc-vim/embed/` is one consumer; nothing in the library knows about Vim.

## Notes

- Only ELF (Linux, the BSDs) honours the flag. Mach-O and COFF ignore it, so
  in-process plugins on macOS and Windows need the same treatment in
  `object/macho.zig` and `object/coff.zig` before they will link.
- Nothing changes for executables: the flag is false unless the output is a
  shared library, so every existing build emits the same bytes as before.
- The channel platform (`platform/`) does not need any of this. It builds
  ordinary executables with a released Roc.
