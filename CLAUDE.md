# zcat

## What is this?

A drop-in `cat` replacement. Reads files, writes to stdout. Written in Zig.

## Build

```bash
zig build -Doptimize=ReleaseSmall
```

Binary lands at `zig-out/bin/zcat` (~179KB).

## Test

```bash
zig build test
```

## Flags

| Flag | Long | What it does |
|------|------|-------------|
| `-n` | `--number` | Number all lines |
| `-b` | `--number-nonblank` | Number non-blank lines only |
| `-s` | `--squeeze-blank` | Collapse consecutive blank lines |
| `-E` | `--show-ends` | Show `$` at line endings |
| `-T` | `--show-tabs` | Show tabs as `^I` |
| | `--json` | JSON output for programs/agents |
| `-h` | `--help` | Usage |
| `-V` | `--version` | Version |

Combined short flags work: `-nbsET` is valid.

## Project structure

```
src/
  main.zig    — entry point, error handling
  Args.zig    — CLI argument parsing
  Cat.zig     — core logic (read, transform, write)
build.zig     — Zig build script
build.zig.zon — package metadata
```

## JSON output

`--json` outputs structured data:

```json
{"files":[{"path":"file.txt","size":1234,"lines":[{"n":1,"text":"..."}]}]}
```

Stdin shows as `"path":"-","size":null`. Multiple files produce multiple entries.
Unreadable files emit `{"path":"...","error":"..."}` and processing continues
(exit code 1 if any file failed).

## Install (Claude Code / general use)

```bash
cp zig-out/bin/zcat.exe ~/.local/bin/zcat.exe
```

On PATH in PowerShell. In Git Bash, `zcat` collides with GNU gzip's zcat
(decompressor) — use full path `~/.local/bin/zcat.exe` there.

## Notes

- No external dependencies. Pure Zig 0.16.0.
- Uses `std.Io` streaming APIs, not mmap.
- Error messages go to stderr. Clean exit codes.
