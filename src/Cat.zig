const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const Args = @import("Args.zig");

const Self = @This();

io: Io,
args: *const Args,
line_number: u64 = 1,
prev_was_blank: bool = false,

pub fn init(allocator: std.mem.Allocator, io: Io, args: *const Args) !Self {
    _ = allocator;
    return Self{
        .io = io,
        .args = args,
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    _ = self;
    _ = allocator;
}

pub fn process(self: *Self) !void {
    if (self.args.files.items.len == 0) {
        try self.processStdin();
    } else {
        for (self.args.files.items) |file_path| {
            try self.processFile(file_path);
        }
    }
}

pub fn processJson(self: *Self) !void {
    const stdout = File.stdout();

    try stdout.writeStreamingAll(self.io, "{\"files\":[");

    if (self.args.files.items.len == 0) {
        try self.processStdinJson(stdout);
    } else {
        for (self.args.files.items, 0..) |file_path, i| {
            if (i > 0) try stdout.writeStreamingAll(self.io, ",");
            try self.processFileJson(stdout, file_path);
        }
    }

    try stdout.writeStreamingAll(self.io, "]}\n");
}

fn processStdin(self: *Self) !void {
    var stdin_buf: [8192]u8 = undefined;
    var stdin_file = File.stdin();
    var stdin_reader = stdin_file.readerStreaming(self.io, &stdin_buf);

    var stdout_file = File.stdout();
    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = stdout_file.writer(self.io, &stdout_buf);

    while (true) {
        var bufs: [1][]u8 = .{&stdin_buf};
        const bytes_read = stdin_reader.interface.readVec(&bufs) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (bytes_read == 0) break;

        const content = stdin_buf[0..bytes_read];
        var lines = std.mem.splitScalar(u8, content, '\n');

        while (lines.next()) |line| {
            const is_last = lines.index == null;
            if (is_last) {
                const has_newline = content.len > 0 and content[content.len - 1] == '\n';
                try self.processLine(&stdout_writer, line, has_newline);
            } else {
                try self.processLine(&stdout_writer, line, true);
            }
        }
    }

    try stdout_writer.flush();
}

fn processStdinJson(self: *Self, stdout: File) !void {
    var stdin_buf: [8192]u8 = undefined;
    var stdin_file = File.stdin();
    var stdin_reader = stdin_file.readerStreaming(self.io, &stdin_buf);

    try stdout.writeStreamingAll(self.io, "{\"path\":\"-\",\"lines\":[");

    var line_num: u64 = 1;
    var first_line = true;

    while (true) {
        var bufs: [1][]u8 = .{&stdin_buf};
        const bytes_read = stdin_reader.interface.readVec(&bufs) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (bytes_read == 0) break;

        const content = stdin_buf[0..bytes_read];
        var lines = std.mem.splitScalar(u8, content, '\n');

        while (lines.next()) |line| {
            const is_last = lines.index == null;
            if (is_last and content.len > 0 and content[content.len - 1] == '\n') {
                break;
            }

            if (!first_line) {
                try stdout.writeStreamingAll(self.io, ",");
            }
            first_line = false;

            try stdout.writeStreamingAll(self.io, "{\"n\":");

            var num_buf: [20]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{line_num}) catch "1";
            try stdout.writeStreamingAll(self.io, num_str);
            line_num += 1;

            try stdout.writeStreamingAll(self.io, ",\"text\":\"");

            for (line) |byte| {
                switch (byte) {
                    '"' => try stdout.writeStreamingAll(self.io, "\\\""),
                    '\\' => try stdout.writeStreamingAll(self.io, "\\\\"),
                    '\n' => {},
                    '\r' => {},
                    '\t' => try stdout.writeStreamingAll(self.io, "\\t"),
                    else => {
                        if (byte >= 0x20) {
                            const char_buf = [1]u8{byte};
                            try stdout.writeStreamingAll(self.io, &char_buf);
                        }
                    },
                }
            }

            try stdout.writeStreamingAll(self.io, "\"}");
        }
    }

    try stdout.writeStreamingAll(self.io, "]}");
}

fn processFile(self: *Self, file_path: []const u8) !void {
    var file = try Dir.openFileAbsolute(
        self.io,
        file_path,
        .{ .mode = .read_only },
    );
    defer file.close(self.io);

    var file_buf: [8192]u8 = undefined;
    var file_reader = file.reader(self.io, &file_buf);

    var stdout_file = File.stdout();
    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = stdout_file.writer(self.io, &stdout_buf);

    var last_was_newline = true;

    while (true) {
        var bufs: [1][]u8 = .{&file_buf};
        const bytes_read = file_reader.interface.readVec(&bufs) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (bytes_read == 0) break;

        const content = file_buf[0..bytes_read];
        var lines = std.mem.splitScalar(u8, content, '\n');

        while (lines.next()) |line| {
            const is_last = lines.index == null;
            if (is_last and content.len > 0 and content[content.len - 1] == '\n') {
                break;
            }
            if (is_last) {
                try self.processLine(&stdout_writer, line, last_was_newline);
                last_was_newline = false;
            } else {
                try self.processLine(&stdout_writer, line, last_was_newline);
                last_was_newline = true;
            }
        }
    }

    try stdout_writer.flush();
}

fn processLine(
    self: *Self,
    writer: *Io.File.Writer,
    line: []const u8,
    has_newline: bool,
) !void {
    const is_blank = line.len == 0;

    if (self.args.squeeze_blank and is_blank and self.prev_was_blank) {
        return;
    }
    self.prev_was_blank = is_blank;

    var buf: [32]u8 = undefined;

    if (self.args.number and !is_blank) {
        const num_str = std.fmt.bufPrint(&buf, "{d:6}\t", .{self.line_number}) catch &buf;
        try writer.interface.writeAll(num_str);
        self.line_number += 1;
    } else if (self.args.number_nonblank and !is_blank) {
        const num_str = std.fmt.bufPrint(&buf, "{d:6}\t", .{self.line_number}) catch &buf;
        try writer.interface.writeAll(num_str);
        self.line_number += 1;
    } else if (self.args.number) {
        const num_str = std.fmt.bufPrint(&buf, "{s:6}\t", .{""}) catch &buf;
        try writer.interface.writeAll(num_str);
    }

    for (line) |byte| {
        if (self.args.show_tabs and byte == '\t') {
            try writer.interface.writeAll("^I");
        } else {
            try writer.interface.writeByte(byte);
        }
    }

    if (has_newline) {
        if (self.args.show_ends) {
            try writer.interface.writeAll("$\n");
        } else {
            try writer.interface.writeByte('\n');
        }
    }
}

fn processFileJson(self: *Self, stdout: File, file_path: []const u8) !void {
    var file = try Dir.openFileAbsolute(
        self.io,
        file_path,
        .{ .mode = .read_only },
    );
    defer file.close(self.io);

    const stat = try file.stat(self.io);

    try stdout.writeStreamingAll(self.io, "{\"path\":\"");
    try stdout.writeStreamingAll(self.io, file_path);
    try stdout.writeStreamingAll(self.io, "\",\"size\":");

    var size_buf: [20]u8 = undefined;
    const size_str = std.fmt.bufPrint(&size_buf, "{d}", .{stat.size}) catch "0";
    try stdout.writeStreamingAll(self.io, size_str);

    try stdout.writeStreamingAll(self.io, ",\"lines\":[");

    var file_buf: [8192]u8 = undefined;
    var file_reader = file.reader(self.io, &file_buf);

    var line_num: u64 = 1;
    var first_line = true;

    while (true) {
        var bufs: [1][]u8 = .{&file_buf};
        const bytes_read = file_reader.interface.readVec(&bufs) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (bytes_read == 0) break;

        const content = file_buf[0..bytes_read];
        var lines = std.mem.splitScalar(u8, content, '\n');

        while (lines.next()) |line| {
            const is_last = lines.index == null;
            if (is_last and content.len > 0 and content[content.len - 1] == '\n') {
                break;
            }

            if (!first_line) {
                try stdout.writeStreamingAll(self.io, ",");
            }
            first_line = false;

            try stdout.writeStreamingAll(self.io, "{\"n\":");

            var num_buf: [20]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{line_num}) catch "1";
            try stdout.writeStreamingAll(self.io, num_str);
            line_num += 1;

            try stdout.writeStreamingAll(self.io, ",\"text\":\"");

            for (line) |byte| {
                switch (byte) {
                    '"' => try stdout.writeStreamingAll(self.io, "\\\""),
                    '\\' => try stdout.writeStreamingAll(self.io, "\\\\"),
                    '\n' => {},
                    '\r' => {},
                    '\t' => try stdout.writeStreamingAll(self.io, "\\t"),
                    else => {
                        if (byte >= 0x20) {
                            const char_buf = [1]u8{byte};
                            try stdout.writeStreamingAll(self.io, &char_buf);
                        }
                    },
                }
            }

            try stdout.writeStreamingAll(self.io, "\"}");
        }
    }

    try stdout.writeStreamingAll(self.io, "]}");
}
