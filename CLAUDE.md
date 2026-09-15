# zcat

## What is this?

A drop-in `cat` replacement. Reads files, writes to stdout. Written in
pure Zig 0.16.0, no deps, no libc. Windows-first; builds for macOS/Linux.

## Build

```bash
zig build -Doptimize=ReleaseSmall
```

Binary lands at `zig-out/bin/zcat` (~502KB).

## Test

```bash
zig build test
```

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
`-n`/`-b` output is byte-identical to GNU cat.

## I/O architecture

- Raw syscalls only: self-declared kernel32 `ReadFile`/`WriteFile` on
  Windows, `std.posix` on POSIX. std.Io buffered layers bypassed.
- `Out` = 64KB buffer, 60000-byte max raw writes, direct methods.
- Zero-copy `feed`: complete lines from the 256KB chunk slice, only
  partials touch the pending buffer.
- `Dir.openFile(.cwd(), ...)`, not `openFileAbsolute` (POSIX isAbsolute
  assert rejects Windows drive paths).
- Args copied via `allocator.dupe` (Iterator deinit frees its strings).

## JSON output

`--json` outputs structured data:

```json
{"files":[{"path":"file.txt","size":1234,"lines":[{"n":1,"text":"..."}]}]}
```

Stdin shows as `"path":"-"`, `"size":null`. Control chars become
`\uXXXX`; quotes/backslashes escape. Unreadable files emit
`{"path":"...","error":"..."}` and processing continues (exit 1 if any
file failed).

## Install (Claude Code / general use)

```bash
cp zig-out/bin/zcat.exe ~/.local/bin/zcat.exe
```

On PATH in PowerShell. In Git Bash, `zcat` collides with GNU gzip's zcat
(decompressor) — use full path `~/.local/bin/zcat.exe` there.

## Exit codes

- 0: success. 1: any file error. 141: stdout broken pipe (silent).

## Project structure

```
src/
  main.zig    — entry point, error handling
  Args.zig    — CLI argument parsing (+ unit tests)
  Cat.zig     — core logic (read, transform, write)
build.zig     — Zig build script
build.zig.zon — package metadata
```

## Notes

- No external dependencies. Pure Zig 0.16.0.
- Streaming I/O, no mmap. Flat memory on any input size.
- Error messages go to stderr. Clean exit codes.
- Benchmarks vs GNU cat: plain 12% faster, `-n` 40%, `-s` 30%
  (96MB fixture, ReleaseFast). Full table in README.