//! Terminal ANSI primitives. Knows nothing about progress.
//! Never installs signal handlers (§3.2); provides restore primitives only.
//! All OS queries flow through io: std.Io — no direct syscalls here.

const std = @import("std");
const builtin = @import("builtin");

pub const Mode = enum { tty, plain, silent };

/// NO_COLOR / TERM=dumb (§3.2): colors stripped, structure kept.
/// Set by the application before the first tick (it owns environ);
/// not re-checked mid-run. The template's writeColor consults this.
pub var color_disabled: bool = false;

pub const Options = struct {
    /// Override TTY detection (tests inject this).
    force_plain: bool = false,
};

pub const Terminal = struct {
    out: *std.Io.Writer,
    mode: Mode,
    /// Set via initTty / Manager.attachTerminalFile. Null -> width()
    /// falls back to 80 and mode detection is caller's business.
    io: ?std.Io = null,
    file: ?std.Io.File = null,
    /// Test hook (§7): injected width, never set in production.
    width_override: ?u16 = null,

    /// Bare init: no io, no TTY detection. Mode must be assigned by the
    /// caller. Used by tests with a fixed writer.
    pub fn init(out: *std.Io.Writer, opts: Options) Terminal {
        return .{ .out = out, .mode = if (opts.force_plain) .plain else .tty };
    }

    /// Io-native init: detects TTY via the io backend (§3.2 rev 2).
    pub fn initTty(io: std.Io, file: std.Io.File, out: *std.Io.Writer, opts: Options) Terminal {
        var t = init(out, opts);
        t.io = io;
        t.file = file;
        if (!opts.force_plain) {
            const tty = file.isTty(io) catch false;
            t.mode = if (tty) .tty else .plain;
        }
        return t;
    }

    pub fn moveUp(self: *Terminal, n: u16) !void {
        if (self.mode != .tty) return;
        try self.out.print("\x1b[{d}A", .{n});
    }

    pub fn moveDown(self: *Terminal, n: u16) !void {
        if (self.mode != .tty) return;
        if (n == 0) return;
        try self.out.print("\x1b[{d}B", .{n});
    }

    pub fn clearLine(self: *Terminal) !void {
        if (self.mode != .tty) return;
        try self.out.writeAll("\x1b[2K");
    }

    pub fn clearBelow(self: *Terminal) !void {
        if (self.mode != .tty) return;
        try self.out.writeAll("\x1b[J");
    }

    pub fn hideCursor(self: *Terminal) !void {
        if (self.mode != .tty) return;
        try self.out.writeAll("\x1b[?25l");
    }

    pub fn showCursor(self: *Terminal) !void {
        if (self.mode != .tty) return;
        try self.out.writeAll("\x1b[?25h");
    }

    /// Terminal width, or 80 when unknown. Never fails: the fallback
    /// policy lives here, not in every renderer (§3.2).
    pub fn width(self: *Terminal) u16 {
        if (self.width_override) |w| return w;
        const io = self.io orelse return 80;
        const file = self.file orelse return 80;
        switch (builtin.os.tag) {
            .windows => return widthWindows(io, file),
            .freestanding, .wasi, .emscripten => return 80,
            else => return widthPosix(io, file),
        }
    }
};

fn widthWindows(io: std.Io, file: std.Io.File) u16 {
    var get_console_info = std.os.windows.CONSOLE.USER_IO.GET_SCREEN_BUFFER_INFO;
    const result = get_console_info.operate(io, file) catch return 80;
    switch (result) {
        .SUCCESS => return @intCast(@max(1, get_console_info.Data.dwWindowSize.X)),
        else => return 80,
    }
}

fn widthPosix(io: std.Io, file: std.Io.File) u16 {
    var winsize: std.posix.winsize = .{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };
    const result = io.operate(.{ .device_io_control = .{
        .file = file,
        .code = std.posix.T.IOCGWINSZ,
        .arg = &winsize,
    } }) catch return 80;
    if (result.device_io_control >= 0)
        return @intCast(@max(1, winsize.col));
    return 80;
}

test "plain mode emits no ANSI" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var t = Terminal.init(&w, .{ .force_plain = true });
    try t.hideCursor();
    try t.clearLine();
    try t.moveUp(1);
    try std.testing.expectEqual(@as(usize, 0), w.end);
}

test "width fallback without io" {
    var buf: [8]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var t = Terminal.init(&w, .{});
    try std.testing.expectEqual(@as(u16, 80), t.width());
    t.width_override = 120;
    try std.testing.expectEqual(@as(u16, 120), t.width());
}
