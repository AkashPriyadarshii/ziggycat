const std = @import("std");
const builtin = @import("builtin");

pub const Args = @This();

pub fn parse(allocator: std.mem.Allocator, args: std.process.Args) !Args {
    var result = Args{
        .files = .empty,
    };

    var iter = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer iter.deinit();

    // Skip program name
    _ = iter.next();

    var parsing_flags = true;

    while (iter.next()) |arg| {
        if (!parsing_flags) {
            try result.files.append(allocator, try allocator.dupe(u8, arg));
        } else if (std.mem.eql(u8, arg, "--")) {
            parsing_flags = false;
        } else if (std.mem.eql(u8, arg, "--number")) {
            result.number = true;
            result.number_nonblank = false;
        } else if (std.mem.eql(u8, arg, "--number-nonblank")) {
            result.number_nonblank = true;
            result.number = false;
        } else if (std.mem.eql(u8, arg, "--squeeze-blank")) {
            result.squeeze_blank = true;
        } else if (std.mem.eql(u8, arg, "--show-ends")) {
            result.show_ends = true;
        } else if (std.mem.eql(u8, arg, "--show-tabs")) {
            result.show_tabs = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            result.json_output = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            result.help = true;
            return result;
        } else if (std.mem.eql(u8, arg, "--version")) {
            result.version = true;
            return result;
        } else if (std.mem.startsWith(u8, arg, "--") and arg.len > 2) {
            return error.UnknownOption;
        } else if (std.mem.eql(u8, arg, "-")) {
            try result.files.append(allocator, try allocator.dupe(u8, arg));
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            // Handle combined short flags like -bETn
            var i: usize = 1;
            while (i < arg.len) : (i += 1) {
                switch (arg[i]) {
                    'n' => {
                        result.number = true;
                        result.number_nonblank = false;
                    },
                    'b' => {
                        result.number_nonblank = true;
                        result.number = false;
                    },
                    's' => result.squeeze_blank = true,
                    'E' => result.show_ends = true,
                    'T' => result.show_tabs = true,
                    'h' => {
                        result.help = true;
                        return result;
                    },
                    'V' => {
                        result.version = true;
                        return result;
                    },
                    else => return error.UnknownOption,
                }
            }
        } else {
            try result.files.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    return result;
}

pub fn deinit(self: *Args, allocator: std.mem.Allocator) void {
    for (self.files.items) |f| allocator.free(f);
    self.files.deinit(allocator);
}

help: bool = false,
version: bool = false,
number: bool = false,
number_nonblank: bool = false,
squeeze_blank: bool = false,
show_ends: bool = false,
show_tabs: bool = false,
json_output: bool = false,
files: std.ArrayList([]const u8) = .empty,

fn testArgs(allocator: std.mem.Allocator, cmdline: []const u8) !Args {
    const cmd = try std.unicode.utf8ToUtf16LeAlloc(allocator, cmdline);
    defer allocator.free(cmd);
    return try parse(allocator, .{ .vector = cmd });
}

test "parse: combined short flags, last flag wins" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = try testArgs(std.testing.allocator, "zcat -nbE");
    defer a.deinit(std.testing.allocator);
    try std.testing.expect(!a.number);
    try std.testing.expect(a.number_nonblank);
    try std.testing.expect(a.show_ends);
    try std.testing.expectEqual(@as(usize, 0), a.files.items.len);
}

test "parse: -b -n => n wins" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = try testArgs(std.testing.allocator, "zcat -b -n");
    defer a.deinit(std.testing.allocator);
    try std.testing.expect(a.number);
    try std.testing.expect(!a.number_nonblank);
}

test "parse: -- ends flag parsing" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = try testArgs(std.testing.allocator, "zcat -- -weird-name");
    defer a.deinit(std.testing.allocator);
    try std.testing.expect(!a.number and !a.show_ends);
    try std.testing.expectEqual(@as(usize, 1), a.files.items.len);
    try std.testing.expectEqualStrings("-weird-name", a.files.items[0]);
}

test "parse: unknown option errors" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.expectError(error.UnknownOption, testArgs(std.testing.allocator, "zcat -z"));
    try std.testing.expectError(error.UnknownOption, testArgs(std.testing.allocator, "zcat --bogus"));
}

test "parse: stdin dash + files" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = try testArgs(std.testing.allocator, "zcat - f1 f2");
    defer a.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), a.files.items.len);
    try std.testing.expectEqualStrings("-", a.files.items[0]);
    try std.testing.expectEqualStrings("f1", a.files.items[1]);
}

test "parse: long flags + json" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = try testArgs(std.testing.allocator, "zcat --number-nonblank --json file");
    defer a.deinit(std.testing.allocator);
    try std.testing.expect(a.number_nonblank);
    try std.testing.expect(a.json_output);
    try std.testing.expectEqual(@as(usize, 1), a.files.items.len);
}

test "parse: help returns immediately" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = try testArgs(std.testing.allocator, "zcat file -h");
    defer a.deinit(std.testing.allocator);
    try std.testing.expect(a.help);
}

