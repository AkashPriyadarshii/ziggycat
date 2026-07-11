const std = @import("std");
const Io = std.Io;
const File = Io.File;

const Args = @import("Args.zig");
const Cat = @import("Cat.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = Args.parse(gpa, init.minimal.args) catch |err| switch (err) {
        error.UnknownOption => {
            try File.stderr().writeStreamingAll(io, "zcat: unknown option\n");
            std.process.exit(1);
        },
        error.OutOfMemory => {
            try File.stderr().writeStreamingAll(io, "zcat: out of memory\n");
            std.process.exit(1);
        },
    };
    defer args.deinit(gpa);

    if (args.help) {
        try File.stdout().writeStreamingAll(io, help_text);
        return;
    }

    if (args.version) {
        try File.stdout().writeStreamingAll(io, version_text);
        return;
    }

    var cat = Cat.init(gpa, io, &args) catch |err| switch (err) {
        error.OutOfMemory => {
            try File.stderr().writeStreamingAll(io, "zcat: out of memory\n");
            std.process.exit(1);
        },
    };
    defer cat.deinit(gpa);

    if (args.json_output) {
        cat.processJson() catch |err| switch (err) {
            error.FileNotFound => {
                try File.stderr().writeStreamingAll(io, "zcat: no such file or directory\n");
                std.process.exit(1);
            },
            error.AccessDenied => {
                try File.stderr().writeStreamingAll(io, "zcat: permission denied\n");
                std.process.exit(1);
            },
            error.IsDir => {
                try File.stderr().writeStreamingAll(io, "zcat: is a directory\n");
                std.process.exit(1);
            },
            error.ReadFailed => {
                try File.stderr().writeStreamingAll(io, "zcat: read error\n");
                std.process.exit(1);
            },
            else => return err,
        };
    } else {
        cat.process() catch |err| switch (err) {
            error.FileNotFound => {
                try File.stderr().writeStreamingAll(io, "zcat: no such file or directory\n");
                std.process.exit(1);
            },
            error.AccessDenied => {
                try File.stderr().writeStreamingAll(io, "zcat: permission denied\n");
                std.process.exit(1);
            },
            error.IsDir => {
                try File.stderr().writeStreamingAll(io, "zcat: is a directory\n");
                std.process.exit(1);
            },
            error.ReadFailed => {
                try File.stderr().writeStreamingAll(io, "zcat: read error\n");
                std.process.exit(1);
            },
            else => return err,
        };
    }
}

const help_text =
    \\zcat v0.1.0 - A modern cat replacement
    \\
    \\Usage: zcat [OPTIONS] [FILE...]
    \\
    \\Read files and write to standard output.
    \\
    \\Options:
    \\  -n, --number          Number all output lines
    \\  -b, --number-nonblank Number only non-empty output lines
    \\  -s, --squeeze-blank   Suppress repeated empty output lines
    \\  -E, --show-ends       Display $ at end of each line
    \\  -T, --show-tabs       Display tab characters as ^I
    \\  --json                Output as JSON (for AI agents)
    \\  -h, --help            Display this help and exit
    \\  -V, --version         Display version and exit
    \\
    \\Examples:
    \\  zcat file.txt          Print file contents
    \\  zcat -n file.txt       Print with line numbers
    \\  zcat *.md              Print all markdown files
    \\  zcat --json file.txt   Print as JSON for AI agents
    \\
;

const version_text = "zcat 0.1.0\n";
