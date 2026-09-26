const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const Args = @import("Args.zig");

const is_windows = builtin.os.tag == .windows;

// Buffered stdout sink backed by raw kernel32/posix writes. std.Io's writer
// flushes everything in one NtWriteFile, which MSYS pipes reject above 64KB;
// raw WriteFile of <=32KB chunks works everywhere.
const Out = struct {
    data: [65536]u8 = undefined,
    len: usize = 0,
    fd: usize,
    // MSYS pipes accept raw WriteFile of any size, but keep chunks modest.
    const chunk_cap: usize = 60000;

    fn init(fd: usize) Out {
        return .{ .fd = fd };
    }

    fn writeAll(self: *Out, bytes: []const u8) !void {
        var rest = bytes;
        while (true) {
            const free = chunk_cap - self.len;
            if (rest.len <= free) {
                @memcpy(self.data[self.len..][0..rest.len], rest);
                self.len += rest.len;
                return;
            }
            @memcpy(self.data[self.len..][0..free], rest[0..free]);
            self.len = chunk_cap;
            try self.flush();
            rest = rest[free..];
        }
    }

    inline fn writeByte(self: *Out, byte: u8) !void {
        if (self.len == chunk_cap) try self.flush();
        self.data[self.len] = byte;
        self.len += 1;
    }

    fn flush(self: *Out) !void {
        if (self.len == 0) return;
        try raw_io.writeAll(self.fd, self.data[0..self.len]);
        self.len = 0;
    }
};

const fd_of = if (is_windows) struct {
    // File.handle is a *anyopaque (HANDLE) on Windows.
    fn get(h: anytype) usize {
        return @intFromPtr(h);
    }
} else struct {
    // File.handle is an fd_t (i32) on POSIX.
    fn get(h: anytype) usize {
        return @intCast(h);
    }
};

// Direct fd I/O: std.posix lacks read/write on Windows, so bind kernel32
// (NT layer only if needed later); POSIX uses std.posix. Avoids the extra
// memcpy of the buffered std.Io path.
const raw_io = if (is_windows) struct {
    extern "kernel32" fn ReadFile(
        hFile: usize,
        lpBuffer: [*]u8,
        nNumberOfBytesToRead: u32,
        lpNumberOfBytesRead: *u32,
        lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) i32;
    extern "kernel32" fn WriteFile(
        hFile: usize,
        lpBuffer: [*]const u8,
        nNumberOfBytesToWrite: u32,
        lpNumberOfBytesWritten: *u32,
        lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) i32;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;

    const ERROR_BROKEN_PIPE: u32 = 0x6D;
    const ERROR_NO_DATA: u32 = 0xE8;

    fn read(hFile: usize, buf: []u8) !usize {
        var n: u32 = 0;
        if (ReadFile(hFile, buf.ptr, @intCast(buf.len), &n, null) == 0) {
            switch (GetLastError()) {
                ERROR_BROKEN_PIPE, ERROR_NO_DATA => return 0,
                else => return error.InputOutput,
            }
        }
        return n;
    }

    fn writeAll(hFile: usize, bytes: []const u8) !void {
        var rest = bytes;
        while (rest.len > 0) {
            const n = try write(hFile, rest);
            rest = rest[n..];
        }
    }

    fn write(hFile: usize, bytes: []const u8) !usize {
        var n: u32 = 0;
        if (WriteFile(hFile, bytes.ptr, @intCast(bytes.len), &n, null) == 0) {
            switch (GetLastError()) {
                ERROR_BROKEN_PIPE, ERROR_NO_DATA => return error.BrokenPipe,
                else => return error.InputOutput,
            }
        }
        if (n == 0) return error.InputOutput; // 0-byte "success" would spin writeAll
        return n;
    }
} else struct {
    // std.posix.write was removed in 0.16 (write goes through evented Io).
    // No-libc raw write needs a direct syscall, arch + OS keyed to the CI
    // matrix: x86_64-linux and aarch64-macos. macOS prefixes BSD numbers.
    const sys_write = switch (builtin.cpu.arch) {
        .x86_64 => struct {
            fn call(fd: i32, buf: [*]const u8, len: usize) usize {
                const nr = if (builtin.os.tag == .macos) @as(usize, 0x2000004) else @as(usize, 1);
                return asm volatile ("syscall"
                    : [ret] "={rax}" (-> usize),
                    : [nr] "{rax}" (nr),
                      [fd] "{rdi}" (@as(usize, @intCast(fd))),
                      [p]  "{rsi}" (@as(usize, @intFromPtr(buf))),
                      [n]  "{rdx}" (len),
                    : .{ .rcx = true, .r11 = true, .memory = true }
                );
            }
        },
        .aarch64 => struct {
            fn call(fd: i32, buf: [*]const u8, len: usize) usize {
                const nr = if (builtin.os.tag == .macos) @as(usize, 0x2000004) else @as(usize, 64);
                return asm volatile ("svc #0"
                    : [ret] "={x0}" (-> usize),
                    : [nr] "{x8}" (nr),
                      [fd] "{x0}" (@as(usize, @intCast(fd))),
                      [p]  "{x1}" (@as(usize, @intFromPtr(buf))),
                      [n]  "{x2}" (len),
                    : .{ .memory = true }
                );
            }
        },
        else => @compileError("unsupported arch"),
    };

    fn read(hFile: usize, buf: []u8) !usize {
        return std.posix.read(@intCast(hFile), buf);
    }

    fn write(hFile: usize, bytes: []const u8) !usize {
        // Raw syscalls return -errno on failure.
        const ret: isize = @bitCast(sys_write.call(@intCast(hFile), bytes.ptr, bytes.len));
        if (ret < 0) {
            return switch (@as(u32, @truncate(@as(u64, @bitCast(-ret))))) {
                32 => error.BrokenPipe, // EPIPE
                else => error.InputOutput,
            };
        }
        if (ret == 0 and bytes.len > 0) return error.InputOutput; // would spin writeAll
        return @intCast(ret);
    }

    fn writeAll(hFile: usize, bytes: []const u8) !void {
        var rest = bytes;
        while (rest.len > 0) {
            const n = try write(hFile, rest);
            rest = rest[n..];
        }
    }
};

const Self = @This();

fn u64Len(n: u64) usize {
    if (n == 0) return 1;
    var v = n;
    var len: usize = 0;
    while (v > 0) : (v /= 10) len += 1;
    return len;
}

fn writeU64(writer: *Out, n: u64) !void {
    var tmp: [20]u8 = undefined;
    const len = u64Len(n);
    var v = n;
    var i = len;
    if (v == 0) {
        tmp[0] = '0';
    } else {
        while (v > 0) : (v /= 10) {
            i -= 1;
            tmp[i] = @intCast('0' + (v % 10));
        }
    }
    try writer.writeAll(tmp[0..len]);
}

// GNU `%6d\t` number column without format machinery.
// ponytail: pad loop, no cached prefix; numbers change every line anyway.
fn writeLineNum(writer: *Out, n: u64) !void {
    const len = u64Len(n);
    var s: usize = len;
    while (s < 6) : (s += 1) try writer.writeByte(' ');
    try writeU64(writer, n);
    try writer.writeByte('\t');
}

io: Io,
allocator: std.mem.Allocator,
args: *const Args,
line_number: u64 = 1,
prev_was_blank: bool = false,
any_file_error: bool = false,

pub fn init(allocator: std.mem.Allocator, io: Io, args: *const Args) !Self {
    return Self{
        .io = io,
        .allocator = allocator,
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
            if (std.mem.eql(u8, file_path, "-")) {
                try self.processStdin();
            } else {
                try self.processFile(file_path);
            }
        }
    }
}

fn needsLineMode(self: *const Self) bool {
    return self.args.number or self.args.number_nonblank or
        self.args.squeeze_blank or self.args.show_ends or self.args.show_tabs;
}

pub fn processJson(self: *Self) !void {
    var writer = Out.init(fd_of.get(File.stdout().handle));
    const w = JsonWriter{ .writer = &writer };

    try w.writer.writeAll("{\"files\":[");

    if (self.args.files.items.len == 0) {
        try self.processStdinJson(w);
    } else {
        for (self.args.files.items, 0..) |file_path, i| {
            if (i > 0) try w.writer.writeAll(",");
            if (std.mem.eql(u8, file_path, "-")) {
                try self.processStdinJson(w);
            } else {
                try self.processFileJson(w, file_path);
            }
        }
    }

    try w.writer.writeAll("]}\n");
    try writer.flush();
}

fn copyStream(self: *Self, in: File, out: File) !void {
    _ = self;
    const in_fd: usize = fd_of.get(in.handle);
    const out_fd: usize = fd_of.get(out.handle);
    var buf: [1048576]u8 = undefined;
    while (true) {
        const n = try raw_io.read(in_fd, &buf);
        if (n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const w = try raw_io.write(out_fd, buf[off..n]);
            off += w;
        }
    }
}

// Read chunked bytes, accumulate into `pending` until a '\n' or EOF, then
// emit complete lines. Guarantees a line spanning chunk boundaries is
// processed exactly once, with correct newline state.
const Pending = struct {
    buf: std.ArrayList(u8) = .empty,

    fn deinit(self: *Pending, allocator: std.mem.Allocator) void {
        self.buf.deinit(allocator);
    }
};

fn feed(
    self: *Self,
    pending: *Pending,
    writer: anytype,
    bytes: []const u8,
    eof: bool,
) !void {
    var start: usize = 0;

    // A partial line carried from the previous chunk; join with the first
    // segment of this chunk (small, typically < line length).
    if (pending.buf.items.len > 0) {
        if (std.mem.indexOfScalar(u8, bytes, '\n')) |nl| {
            const total = pending.buf.items.len + nl;
            var scratch: [4096]u8 = undefined;
            const line = if (total <= scratch.len) blk: {
                @memcpy(scratch[0..pending.buf.items.len], pending.buf.items);
                @memcpy(scratch[pending.buf.items.len..total], bytes[0..nl]);
                break :blk scratch[0..total];
            } else blk: {
                try pending.buf.appendSlice(self.allocator, bytes[0..nl]);
                break :blk pending.buf.items;
            };
            pending.buf.clearRetainingCapacity();
            try self.processLine(writer, line, true);
            start = nl + 1;
        } else {
            // No newline: the partial continues in the next chunk... unless
            // this is the final chunk, in which case flush it as the last line.
            if (eof) {
                try self.processLine(writer, pending.buf.items, false);
                pending.buf.clearRetainingCapacity();
                return;
            }
            try pending.buf.appendSlice(self.allocator, bytes);
            return;
        }
    }

    // Complete lines wholly inside this chunk: no copies.
    while (std.mem.indexOfScalarPos(u8, bytes, start, '\n')) |nl| {
        try self.processLine(writer, bytes[start..nl], true);
        start = nl + 1;
    }

    // Unterminated tail becomes the new pending partial.
    pending.buf.clearRetainingCapacity();
    if (start < bytes.len) {
        try pending.buf.appendSlice(self.allocator, bytes[start..]);
    }

    if (eof and pending.buf.items.len > 0) {
        try self.processLine(writer, pending.buf.items, false);
        pending.buf.clearRetainingCapacity();
    }
}

const JsonWriter = struct {
    writer: *Out,
};

fn feedJson(
    self: *Self,
    pending: *Pending,
    w: JsonWriter,
    bytes: []const u8,
    eof: bool,
    line_num: *u64,
    first_line: *bool,
) !void {
    var start: usize = 0;

    if (pending.buf.items.len > 0) {
        if (std.mem.indexOfScalar(u8, bytes, '\n')) |nl| {
            const total = pending.buf.items.len + nl;
            var scratch: [4096]u8 = undefined;
            const line = if (total <= scratch.len) blk: {
                @memcpy(scratch[0..pending.buf.items.len], pending.buf.items);
                @memcpy(scratch[pending.buf.items.len..total], bytes[0..nl]);
                break :blk scratch[0..total];
            } else blk: {
                try pending.buf.appendSlice(self.allocator, bytes[0..nl]);
                break :blk pending.buf.items;
            };
            pending.buf.clearRetainingCapacity();
            try self.writeJsonLine(w, line, line_num, first_line);
            start = nl + 1;
        } else {
            if (eof) {
                try self.writeJsonLine(w, pending.buf.items, line_num, first_line);
                pending.buf.clearRetainingCapacity();
                return;
            }
            try pending.buf.appendSlice(self.allocator, bytes);
            return;
        }
    }

    while (std.mem.indexOfScalarPos(u8, bytes, start, '\n')) |nl| {
        try self.writeJsonLine(w, bytes[start..nl], line_num, first_line);
        start = nl + 1;
    }

    pending.buf.clearRetainingCapacity();
    if (start < bytes.len) {
        try pending.buf.appendSlice(self.allocator, bytes[start..]);
    }

    if (eof and pending.buf.items.len > 0) {
        try self.writeJsonLine(w, pending.buf.items, line_num, first_line);
        pending.buf.clearRetainingCapacity();
    }
}

fn writeJsonLine(self: *Self, w: JsonWriter, line: []const u8, line_num: *u64, first_line: *bool) !void {
    if (!first_line.*) {
        try w.writer.writeAll(",");
    }
    first_line.* = false;

    try w.writer.writeAll("{\"n\":");

    try writeU64(w.writer, line_num.*);
    line_num.* += 1;

    try w.writer.writeAll(",\"text\":\"");
    try self.writeEscaped(w.writer, line);
    try w.writer.writeAll("\"}");
}

fn processStdin(self: *Self) !void {
    if (!self.needsLineMode()) {
        return self.copyStream(File.stdin(), File.stdout());
    }

    const stdin_fd: usize = fd_of.get(File.stdin().handle);
    var stdin_buf: [1048576]u8 = undefined;

    var stdout_writer = Out.init(fd_of.get(File.stdout().handle));

    var pending = Pending{};
    defer pending.deinit(self.allocator);

    while (true) {
        const bytes_read = try raw_io.read(stdin_fd, &stdin_buf);
        if (bytes_read == 0) break;
        try self.feed(&pending, &stdout_writer, stdin_buf[0..bytes_read], false);
    }

    try self.feed(&pending, &stdout_writer, "", true);
    try stdout_writer.flush();
}

fn processFile(self: *Self, file_path: []const u8) !void {
    var file = Dir.openFile(
        .cwd(), self.io, file_path,
        .{ .mode = .read_only },
    ) catch |err| {
        self.any_file_error = true;
        try self.reportFileError(file_path, err);
        return;
    };
    defer file.close(self.io);

    const st = file.stat(self.io) catch {
        self.any_file_error = true;
        try self.reportFileError(file_path, error.InputOutput);
        return;
    };
    if (st.kind == .directory) {
        self.any_file_error = true;
        try self.reportFileError(file_path, error.IsDir);
        return;
    }

    if (!self.needsLineMode()) {
        return self.copyStream(file, File.stdout()) catch |err| {
        self.any_file_error = true;
        try self.reportFileError(file_path, err);
        return;
    };
    }

    var file_buf: [1048576]u8 = undefined;
    const file_fd: usize = fd_of.get(file.handle);

    var stdout_writer = Out.init(fd_of.get(File.stdout().handle));

    var pending = Pending{};
    defer pending.deinit(self.allocator);

    while (true) {
        const bytes_read = try raw_io.read(file_fd, &file_buf);
        if (bytes_read == 0) break;
        try self.feed(&pending, &stdout_writer, file_buf[0..bytes_read], false);
    }

    try self.feed(&pending, &stdout_writer, "", true);
    try stdout_writer.flush();
}

fn processStdinJson(self: *Self, w: JsonWriter) !void {
    try w.writer.writeAll("{\"path\":\"-\",\"size\":null,\"lines\":[");

    var stdin_buf: [1048576]u8 = undefined;
    const stdin_fd: usize = fd_of.get(File.stdin().handle);

    var pending = Pending{};
    defer pending.deinit(self.allocator);

    var line_num: u64 = 1;
    var first_line = true;

    while (true) {
        const bytes_read = try raw_io.read(stdin_fd, &stdin_buf);
        if (bytes_read == 0) break;
        try self.feedJson(&pending, w, stdin_buf[0..bytes_read], false, &line_num, &first_line);
    }

    try self.feedJson(&pending, w, "", true, &line_num, &first_line);

    try w.writer.writeAll("]}");
}

fn writeErrorRecord(self: *Self, w: JsonWriter, file_path: []const u8, err: anyerror) !void {
    const msg = switch (err) {
        error.FileNotFound => "no such file or directory",
        error.AccessDenied => "permission denied",
        error.IsDir => "is a directory",
        else => "read failed",
    };
    try w.writer.writeAll("{\"path\":\"");
    try self.writeEscaped(w.writer, file_path);
    try w.writer.writeAll("\",\"error\":\"");
    try w.writer.writeAll(msg);
    try w.writer.writeAll("\"}");
}

fn writeEscaped(_: *Self, writer: *Out, bytes: []const u8) !void {
    const hex = "0123456789abcdef";
    var i: usize = 0;
    while (i < bytes.len) {
        var j = i;
        while (j < bytes.len and bytes[j] >= 0x20 and bytes[j] != '"' and bytes[j] != '\\') : (j += 1) {}
        if (j > i) try writer.writeAll(bytes[i..j]);
        i = j;
        if (i >= bytes.len) break;
        const b = bytes[i];
        i += 1;
        switch (b) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => {},
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                const esc = [_]u8{ '\\', 'u', '0', '0', hex[b >> 4], hex[b & 0xF] };
                try writer.writeAll(&esc);
            },
        }
    }
}

fn reportFileError(self: *Self, file_path: []const u8, err: anyerror) !void {
    const msg = switch (err) {
        error.FileNotFound => "no such file or directory",
        error.AccessDenied => "permission denied",
        error.IsDir => "is a directory",
        error.OutOfMemory => "out of memory",
        else => "read error",
    };
    const stderr = File.stderr();
    try stderr.writeStreamingAll(self.io, "ziggycat: ");
    try stderr.writeStreamingAll(self.io, file_path);
    try stderr.writeStreamingAll(self.io, ": ");
    try stderr.writeStreamingAll(self.io, msg);
    try stderr.writeStreamingAll(self.io, "\n");
}

inline fn processLine(
    self: *Self,
    writer: *Out,
    line: []const u8,
    has_newline: bool,
) !void {
    const is_blank = line.len == 0;

    if (self.args.squeeze_blank and is_blank and self.prev_was_blank) {
        return;
    }
    self.prev_was_blank = is_blank;

    if ((self.args.number or self.args.number_nonblank) and !is_blank) {
        try writeLineNum(writer, self.line_number);
        self.line_number += 1;
    } else if (self.args.number) {
        try writeLineNum(writer, self.line_number);
        self.line_number += 1;
    }

    if (self.args.show_tabs) {
        var ti: usize = 0;
        while (std.mem.indexOfScalarPos(u8, line, ti, '\t')) |t| {
            try writer.writeAll(line[ti..t]);
            try writer.writeAll("^I");
            ti = t + 1;
        }
        try writer.writeAll(line[ti..]);
    } else {
        try writer.writeAll(line);
    }
    if (has_newline) {
        if (self.args.show_ends) {
            try writer.writeAll("$\n");
        } else {
            try writer.writeByte('\n');
        }
    }
}

fn processFileJson(self: *Self, w: JsonWriter, file_path: []const u8) !void {
    var file = Dir.openFile(
        .cwd(), self.io, file_path,
        .{ .mode = .read_only },
    ) catch |err| {
        self.any_file_error = true;
        try self.writeErrorRecord(w, file_path, err);
        return;
    };
    defer file.close(self.io);

    const stat = file.stat(self.io) catch |err| {
        self.any_file_error = true;
        try self.writeErrorRecord(w, file_path, err);
        return;
    };

    if (stat.kind == .directory) {
        self.any_file_error = true;
        try self.writeErrorRecord(w, file_path, error.IsDir);
        return;
    }

    try w.writer.writeAll("{\"path\":\"");
    try self.writeEscaped(w.writer, file_path);
    try w.writer.writeAll("\",\"size\":");

    try writeU64(w.writer, stat.size);

    try w.writer.writeAll(",\"lines\":[");

    var file_buf: [1048576]u8 = undefined;
    const file_fd: usize = fd_of.get(file.handle);

    var pending = Pending{};
    defer pending.deinit(self.allocator);

    var line_num: u64 = 1;
    var first_line = true;

    while (true) {
        const bytes_read = try raw_io.read(file_fd, &file_buf);
        if (bytes_read == 0) break;
        try self.feedJson(&pending, w, file_buf[0..bytes_read], false, &line_num, &first_line);
    }

    try self.feedJson(&pending, w, "", true, &line_num, &first_line);

    try w.writer.writeAll("]}");
}