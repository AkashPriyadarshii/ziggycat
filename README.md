# zcat

<!-- keywords: zig, cat clone, gnu cat alternative, command line, cli, terminal tools, text processing, json output, ai agents, llm tools, zero dependency, cross-platform, windows, performance -->

Fast `cat` replacement. Zero dependencies, no libc, pure Zig 0.16.0.

**Topics:** `zig` `cat` `cli` `terminal` `json` `ai-agents` `zero-dependency` `windows` `cross-platform`
Windows-first, also builds for macOS and Linux.

<img src="assets/zcat-demo.svg" alt="zcat -n terminal demo" width="640">

```
$ zcat -n file.txt
     1	hello
     2	world
```

## Install

```bash
git clone https://github.com/AkashPriyadarshii/zcat.git
cd zcat
zig build -Doptimize=ReleaseSmall
```

Binary: `zig-out/bin/zcat` (or `zcat.exe` on Windows, ~502KB).

## Usage

```
zcat [OPTIONS] [FILE...]
```

No file arguments reads stdin. `-` also means stdin and can appear
anywhere in the list. Multiple files concatenate in order.

## Flags

| Short | Long | Effect |
|-------|------|--------|
| `-n` | `--number` | Number every output line |
| `-b` | `--number-nonblank` | Number non-empty lines only |
| `-s` | `--squeeze-blank` | Collapse runs of empty lines into one |
| `-E` | `--show-ends` | Append `$` to each line ending |
| `-T` | `--show-tabs` | Render tabs as `^I` |
| | `--json` | Structured output for agents (see below) |
| `-h` | `--help` | Usage |
| `-V` | `--version` | Version |

Short flags combine: `-nbsET` works. Last-wins for `-n`/`-b`.
`-n` and `-b` output is byte-identical to GNU `cat`.

## JSON mode

`--json` wraps output for machine consumption:

```json
{"files":[{"path":"example.txt","size":2048,"lines":[{"n":1,"text":"first line"},{"n":2,"text":"second line"}]}]}
```

- `path` is `"-"` and `size` is `null` when reading stdin.
- Control characters escape as `\uXXXX`. Quotes and backslashes escape.
- Unreadable files emit `{"path":"...","error":"..."}` and processing continues.
- Empty files produce `"lines":[]`.
- Multiple files produce multiple objects in the `files` array.

Designed for AI coding agents that need structured file reads instead of
raw text dumps.

## Performance

96MB file, build `ReleaseFast`, sink `/dev/null`. Median of 3 runs,
compared against GNU coreutils cat 9.x:

| Operation | zcat | cat | Speedup |
|-----------|------|-----|---------|
| Plain copy | 72ms | 82ms | 12% |
| `-n` (number all lines) | 112ms | 185ms | 40% |
| `-s` (squeeze blanks) | 100ms | 145ms | 30% |
| `--json` | 275ms | (no counterpart) | |

## Architecture

- **Raw syscalls, no std buffering.** Windows uses self-declared kernel32
  `ReadFile`/`WriteFile`. POSIX uses `std.posix`. The std.Io reader/writer
  layers are bypassed entirely.
- **Single 256KB read buffer.** Line modes scan chunks in place; complete
  lines are processed directly from the chunk, only partial lines touch a
  small pending buffer (zero-copy feed). Plain mode is one buffer, one loop.
- **No mmap.** Streaming I/O keeps memory flat and works on pipes.
- **Broken pipe exits 141** (SIGPIPE semantics), silently. File errors go to
  stderr as `zcat: file: reason`, processing continues, exit code 1.

## Project structure

```
src/
  main.zig    — entry point, error handling, exit codes
  Args.zig    — CLI argument parsing (+ unit tests)
  Cat.zig     — core logic: reads, line transforms, JSON
build.zig     — Zig build script
build.zig.zon — package metadata
```

## Test

```bash
zig build test
```

## License

MIT