# zcat

Fast `cat` replacement. 179KB binary. Zero dependencies.

```
$ zcat -n file.txt
     1	hello
     2	world
```

## Install

```bash
# Build from source
git clone https://github.com/AkashPriyadarshii/zcat.git
cd zcat
zig build -Doptimize=ReleaseSmall
```

Binary: `zig-out/bin/zcat`

## Usage

```
zcat [OPTIONS] [FILE...]
```

No file arguments reads stdin. Multiple files concatenate in order.

## Flags

| Short | Long | Effect |
|-------|------|--------|
| `-n` | `--number` | Number every output line |
| `-b` | `--number-nonblank` | Number non-empty lines only |
| `-s` | `--squeeze-blank` | Collapse runs of empty lines into one |
| `-E` | `--show-ends` | Append `$` to each line ending |
| `-T` | `--show-tabs` | Render tabs as `^I` |
| | `--json` | Structured output (see below) |
| `-h` | `--help` | Usage |
| `-V` | `--version` | Version |

Short flags combine: `-nbsET` is the same as `-n -b -s -E -T`.

## JSON mode

`--json` wraps output for machine consumption:

```json
{"files":[{"path":"example.txt","size":2048,"lines":[{"n":1,"text":"first line"},{"n":2,"text":"second line"}]}]}
```

- `path` is `"-"` when reading from stdin.
- Empty files produce `"lines":[]`.
- Multiple files produce multiple objects in the `files` array.

Designed for AI coding agents that need structured file reads instead of raw text dumps.

## Performance

Tested against a 5.4MB JSON file and a 20K-line Python file:

| Operation | Time |
|-----------|------|
| Basic read (5.4MB) | 23ms |
| All flags (5.4MB) | 24ms |
| JSON output (5.4MB) | 3.3s |
| All flags (20K lines) | 1.1s |

## Compatibility

Works on macOS, Linux, and Windows. Builds with Zig 0.16.0.

## License

MIT
