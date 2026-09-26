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
            try File.stderr().writeStreamingAll(io, "ziggycat: unknown option\n");
            std.process.exit(1);
        },
        error.OutOfMemory => {
            try File.stderr().writeStreamingAll(io, "ziggycat: out of memory\n");
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
            try File.stderr().writeStreamingAll(io, "ziggycat: out of memory\n");
            std.process.exit(1);
        },
    };
    defer cat.deinit(gpa);

    if (args.json_output) {
        cat.processJson() catch |err| switch (err) {
            error.BrokenPipe => std.process.exit(141), // SIGPIPE semantics
            error.InputOutput => {
                try File.stderr().writeStreamingAll(io, "ziggycat: i/o error\n");
                std.process.exit(1);
            },
            else => return err,
        };
    } else {
        cat.process() catch |err| switch (err) {
            error.OutOfMemory => {
                try File.stderr().writeStreamingAll(io, "ziggycat: out of memory\n");
                std.process.exit(1);
            },
            error.BrokenPipe => std.process.exit(141), // SIGPIPE semantics
            error.InputOutput => {
                try File.stderr().writeStreamingAll(io, "ziggycat: i/o error\n");
                std.process.exit(1);
            },
            else => return err,
        };
    }

    if (cat.any_file_error) std.process.exit(1);
}

const help_text =
    \\ziggycat v0.1.3 - A modern cat replacement
    \\
    \\Usage: ziggycat [OPTIONS] [FILE...]
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
    \\  ziggycat file.txt          Print file contents
    \\  ziggycat -n file.txt       Print with line numbers
    \\  ziggycat *.md              Print all markdown files
    \\  ziggycat --json file.txt   Print as JSON for AI agents
    \\
;

const version_text = "ziggycat 0.1.3\n";
