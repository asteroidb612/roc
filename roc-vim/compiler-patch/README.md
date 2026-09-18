# A Roc compiler that can build plugins Vim loads

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

## Building a Roc with it

```sh
git clone https://github.com/roc-lang/roc.git
cd roc
git checkout 1d982dca644aaddf1cc858f8580fadccf025358b
git apply /path/to/roc-shared-library-static-data.patch
zig build roc          # needs Zig 0.16
./zig-out/bin/roc version
```

Point Vim at it with `let g:roc_command = '/path/to/roc'`.

## Notes

- Only ELF (Linux, the BSDs) honours the flag. Mach-O and COFF ignore it, so
  in-process plugins on macOS and Windows need the same treatment in
  `object/macho.zig` and `object/coff.zig` before they will link.
- Nothing changes for executables: the flag is false unless the output is a
  shared library, so every existing build emits the same bytes as before.
- The channel platform (`platform/`) does not need any of this. It builds
  ordinary executables with a released Roc.
