const std = @import("std");

pub const Args = @This();

pub fn parse(allocator: std.mem.Allocator, args: std.process.Args) !Args {
    var result = Args{
        .files = .empty,
    };

    var iter = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer iter.deinit();

    // Skip program name
    _ = iter.next();

    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--number")) {
            result.number = true;
        } else if (std.mem.eql(u8, arg, "--number-nonblank")) {
            result.number_nonblank = true;
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
            try result.files.append(allocator, arg);
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            // Handle combined short flags like -bETn
            var i: usize = 1;
            while (i < arg.len) : (i += 1) {
                switch (arg[i]) {
                    'n' => result.number = true,
                    'b' => result.number_nonblank = true,
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
            try result.files.append(allocator, arg);
        }
    }

    return result;
}

pub fn deinit(self: *Args, allocator: std.mem.Allocator) void {
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
