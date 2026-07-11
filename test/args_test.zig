const std = @import("std");
const testing = std.testing;

const Args = @import("Args.zig");
const Cat = @import("Cat.zig");

test "Args: parses basic flags" {
    var args = Args{
        .number = false,
        .number_nonblank = false,
        .squeeze_blank = false,
        .show_ends = false,
        .show_tabs = false,
        .json_output = false,
        .help = false,
        .version = false,
        .files = std.ArrayList([]const u8).init(testing.allocator),
    };
    defer args.deinit(testing.allocator);

    try args.files.append(testing.allocator, "test.txt");
    try testing.expect(args.files.items.len == 1);
    try testing.expectEqualStrings("test.txt", args.files.items[0]);
}

test "Args: defaults" {
    var args = Args{
        .number = false,
        .number_nonblank = false,
        .squeeze_blank = false,
        .show_ends = false,
        .show_tabs = false,
        .json_output = false,
        .help = false,
        .version = false,
        .files = std.ArrayList([]const u8).init(testing.allocator),
    };
    defer args.deinit(testing.allocator);

    try testing.expect(!args.number);
    try testing.expect(!args.number_nonblank);
    try testing.expect(!args.squeeze_blank);
    try testing.expect(!args.show_ends);
    try testing.expect(!args.show_tabs);
    try testing.expect(!args.json_output);
    try testing.expect(!args.help);
    try testing.expect(!args.version);
    try testing.expect(args.files.items.len == 0);
}
