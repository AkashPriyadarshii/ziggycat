# zcat

## What is this?

A drop-in `cat` replacement. Reads files, writes to stdout. Written in
pure Zig 0.16.0, no deps, no libc. Windows-first; builds for macOS/Linux.

## Build

```bash
zig build -Doptimize=ReleaseSmall
```

Binary lands at `zig-out/bin/zcat` (~502KB). Bench builds use
`-Doptimize=ReleaseFast`.

## Test

```bash
zig build test
```

Tests live in Args.zig (7 blocks, Windows-only, vector-based argv).
Line-transform correctness is verified against GNU cat byte-for-byte:
`-n`, `-b`, `-s`, `-E` output identical (see README benchmark section).

## Flags

| Flag | Long | What it does |
|------|------|-------------|
| `-n` | `--number` | Number all lines (including blanks, GNU-identical) |
| `-b` | `--number-nonblank` | Number non-blank lines only |
| `-s` | `--squeeze-blank` | Collapse consecutive blank lines |
| `-E` | `--show-ends` | Show `$` at line endings |
| `-T` | `--show-tabs` | Show tabs as `^I` |
| | `--json` | JSON output for programs/agents |
| `-h` | `--help` | Usage |
| `-V` | `--version` | Version |

Combined short flags work: `-nbsET` is valid. `-n`/`-b` last-wins.

## I/O architecture (read before editing)

- All reads/writes go through `raw_io`: self-declared kernel32
  `ReadFile`/`WriteFile` on Windows, `std.posix` on POSIX. The std.Io
  reader/writer layers are not used for file data (their async threading
  breaks MSYS pipe writes above 64KB, and value-init writers dangle
  self-references).
- `Out` struct = 64KB buffer, max 60000-byte raw writes, direct methods
  (no self-referential interface).
- `feed`/`feedJson` = zero-copy line splitter. Complete lines process from
  the 256KB chunk slice; only partial lines enter `pending` (4096B stack
  scratch, appendSlice fallback). EOF flush handles trailing non-newline.
- plain mode (`copyStream`) = one buffer, raw read + partial-write loop.
- Paths open via `Dir.openFile(.cwd(), ...)`, never `openFileAbsolute`
  (asserts POSIX `isAbsolute`, which rejects Windows drive paths).
- Args are copied (`allocator.dupe`) because `std.process.Args.Iterator`
  deinit frees its strings.

## Exit codes and errors

- 0: success. 1: any file error (processing continues past failures).
- 141: broken pipe on stdout, silent, SIGPIPE semantics.
- Errors: `zcat: path: reason` on stderr. Dirs report "is a directory".
- JSON errors: `{"path":"...","error":"..."}` records, exit 1 if any.

## JSON output

`--json` outputs structured data:

```json
{"files":[{"path":"file.txt","size":1234,"lines":[{"n":1,"text":"..."}]}]}
```

Stdin shows as `"path":"-"`, `"size":null`. Control chars become
`\uXXXX`; quotes/backslashes escape. Multiple files produce multiple
entries. Unreadable files yield error records, processing continues.

## Benchmarks

96MB fixture, ReleaseFast, NUL sink, median of 3, vs GNU cat 9.x:

| Operation | zcat | cat | Speedup |
|-----------|------|-----|---------|
| Plain | 72ms | 82ms | 12% |
| `-n` | 112ms | 185ms | 40% |
| `-s` | 100ms | 145ms | 30% |
| `--json` | 275ms | n/a | |

## Project structure

```
src/
  main.zig    — entry point, error handling, exit codes
  Args.zig    — CLI argument parsing (+ unit tests)
  Cat.zig     — core logic (read, transform, write)
build.zig     — Zig build script
build.zig.zon — package metadata
```