//! Compile-time template engine.
//!
//! Style.parse comptime-validates a template string into a segment array.
//! Runtime cost for a valid template: a loop over segments, zero parsing.
//!
//! Widths are upper bounds: the formatter shrinks to fit terminal width
//! (§3.1 of the architecture doc).

const std = @import("std");

const terminal_mod = @import("terminal.zig");

pub const Field = enum {
    bar,
    spinner,
    pos,
    len,
    percent,
    elapsed,
    eta,
    speed,
    msg,
    wide_bar,
};

pub const Segment = union(enum) {
    literal: []const u8,
    field: FieldSpec,
};

pub const FieldSpec = struct {
    field: Field,
    width: ?u16 = null,
    color: ?ColorPair = null,
};

pub const ColorPair = struct {
    fg: u8,
    bg: ?u8 = null,
};

pub const Frame = struct {
    pos: u32 = 0,
    len: u32 = 0,
    elapsed_ns: u64 = 0,
    spinner_tick: u64 = 0,
    message: []const u8 = "",
};

pub const Style = struct {
    segments: []const Segment,

    /// Parse a template at comptime. Invalid templates are compile errors.
    /// Supported field syntax: `{name}`, `{name:width}`, `{bar:40.cyan}`.
    pub fn parse(comptime src: []const u8) Style {
        comptime {
            @setEvalBranchQuota(100000);
            var segments: []const Segment = &.{};
            var i: usize = 0;
            var lit_start: usize = 0;

            while (i < src.len) {
                if (src[i] != '{') {
                    i += 1;
                    continue;
                }
                if (i > lit_start) {
                    segments = segments ++ [_]Segment{.{ .literal = src[lit_start..i] }};
                }
                const close = std.mem.indexOfScalarPos(u8, src, i, '}') orelse
                    @compileError("zprogress: unterminated '{' in template \"" ++ src ++ "\"");
                const inner = src[i + 1 .. close];
                if (inner.len == 0)
                    @compileError("zprogress: empty field in template \"" ++ src ++ "\"");

                var name_end: usize = 0;
                while (name_end < inner.len and inner[name_end] != ':' and inner[name_end] != '.') : (name_end += 1) {}
                const name = inner[0..name_end];

                const field = std.meta.stringToEnum(Field, name) orelse {
                    @compileError("zprogress: unknown field '{" ++ name ++ "}' in template \"" ++ src ++ "\"");
                };
                var spec = FieldSpec{ .field = field };

                if (name_end < inner.len and inner[name_end] == ':') {
                    var rest: []const u8 = inner[name_end + 1 ..];
                    var width_end: usize = 0;
                    while (width_end < rest.len and rest[width_end] != '.') : (width_end += 1) {}
                    if (width_end == 0)
                        @compileError("zprogress: empty width in template \"" ++ src ++ "\"");
                    spec.width = std.fmt.parseInt(u16, rest[0..width_end], 10) catch
                        @compileError("zprogress: bad width in template \"" ++ src ++ "\"");
                    rest = rest[width_end..];
                    if (rest.len > 0 and rest[0] == '.') {
                        var color_part: []const u8 = rest[1..];
                        if (std.mem.indexOfScalar(u8, color_part, '/')) |slash| {
                            // fg/bg pair "cyan/blue": bg validation deferred (P2).
                            color_part = color_part[0..slash];
                        }
                        spec.color = .{ .fg = @intFromEnum(std.meta.stringToEnum(NamedColor, color_part) orelse
                            @compileError("zprogress: unknown color '." ++ color_part ++ "' in template \"" ++ src ++ "\"")) };
                    }
                } else if (name_end < inner.len and inner[name_end] == '.') {
                    const color_name = inner[name_end + 1 ..];
                    spec.color = std.meta.stringToEnum(NamedColor, color_name) orelse
                        @compileError("zprogress: unknown color '." ++ color_name ++ "' in template \"" ++ src ++ "\"");
                }

                segments = segments ++ [_]Segment{.{ .field = spec }};
                i = close + 1;
                lit_start = i;
            }
            if (i > lit_start) {
                segments = segments ++ [_]Segment{.{ .literal = src[lit_start..i] }};
            }
            return .{ .segments = segments };
        }
    }

    /// Render into a fixed buffer. No allocation. Shrinks bar then msg to
    /// fit `terminal_width`; literals are never truncated.
    pub fn format(self: Style, writer: *std.Io.Writer, frame: Frame, terminal_width: u16) std.Io.Writer.Error!void {
        // Pass 1: measure non-shrinkable width; find bar/msg field budget.
        var fixed_width: usize = 0;
        for (self.segments) |seg| switch (seg) {
            .literal => |l| fixed_width += l.len,
            .field => |f| {
                if (f.field != .bar and f.field != .wide_bar and f.field != .msg)
                    fixed_width += estimateFixed(f.field);
            },
        };
        const avail: usize = if (terminal_width > fixed_width) terminal_width - fixed_width else 0;

        for (self.segments) |seg| switch (seg) {
            .literal => |l| try writer.writeAll(l),
            .field => |f| try self.writeField(writer, f, frame, avail),
        };
    }

    fn writeField(self: Style, writer: *std.Io.Writer, spec: FieldSpec, frame: Frame, avail: usize) !void {
        try self.writeColor(writer, spec.color);
        defer self.writeColor(writer, null) catch {};
        switch (spec.field) {
            .bar, .wide_bar => {
                var width: usize = spec.width orelse 20;
                if (width > avail) width = avail;
                try writeBar(writer, frame, width, spec.field == .wide_bar);
            },
            .msg => {
                var width: usize = frame.message.len;
                if (spec.width) |w| width = @min(width, w);
                if (width > avail) width = avail;
                try writer.writeAll(frame.message[0..width]);
            },
            .spinner => {
                const c = spinnerChars[@intCast(frame.spinner_tick % spinnerChars.len)];
                try writer.writeAll(c);
            },
            .pos => try writer.print("{d}", .{frame.pos}),
            .len => try writer.print("{d}", .{frame.len}),
            .percent => try writer.print("{d}%", .{percentOf(frame)}),
            .elapsed => try writer.print("{d:.1}s", .{@as(f64, @floatFromInt(frame.elapsed_ns)) / std.time.ns_per_s}),
            .eta => try writer.print("{d:.1}s", .{etaOf(frame)}),
            .speed => {
                const s = @as(f64, @floatFromInt(frame.elapsed_ns)) / std.time.ns_per_s;
                if (s > 0) try writer.print("{d:.1}/s", .{@as(f64, @floatFromInt(frame.pos)) / s});
            },
        }
    }

    fn writeColor(_: Style, writer: *std.Io.Writer, color: ?ColorPair) !void {
        if (color) |c| {
            // NO_COLOR / TERM=dumb (§3.2): structure kept, colors stripped.
            if (terminal_mod.color_disabled) return;
            try writer.print("\x1b[{d}m", .{30 + c.fg});
        }
    }
};

pub const NamedColor = enum(u8) {
    black = 0,
    red = 1,
    green = 2,
    yellow = 3,
    blue = 4,
    magenta = 5,
    cyan = 6,
    white = 7,
};

const spinnerChars = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

fn percentOf(frame: Frame) u64 {
    if (frame.len == 0) return 0;
    return frame.pos * 100 / frame.len;
}

fn etaOf(frame: Frame) f64 {
    const pct = percentOf(frame);
    if (pct == 0) return 0;
    const s: f64 = @as(f64, @floatFromInt(frame.elapsed_ns)) / std.time.ns_per_s;
    return s * (100.0 - @as(f64, @floatFromInt(pct))) / @as(f64, @floatFromInt(pct));
}

fn estimateFixed(field: Field) usize {
    return switch (field) {
        .bar, .wide_bar, .msg => 0,
        .spinner => 1,
        .pos, .len => 10, // u64 max digits
        .percent => 5,
        .elapsed, .eta => 8,
        .speed => 12,
    };
}

fn writeBar(writer: *std.Io.Writer, frame: Frame, width: usize, wide: bool) !void {
    const pct: f64 = if (frame.len == 0)
        0
    else
        @as(f64, @floatFromInt(frame.pos)) / @as(f64, @floatFromInt(frame.len));
    const filled: usize = @intFromFloat(@min(pct, 1.0) * @as(f64, @floatFromInt(width)));
    try writer.writeAll("[");
    if (wide) {
        for (0..filled) |_| try writer.writeAll("█");
        for (filled..width) |_| try writer.writeAll("░");
    } else {
        try writer.splatByteAll('#', filled);
        try writer.splatByteAll('-', width - filled);
    }
    try writer.writeAll("]");
}

test "parse valid template" {
    const style = comptime Style.parse("{bar:40.cyan/blue} {pos}/{len} {eta}");
    try std.testing.expectEqual(@as(usize, 7), style.segments.len);
}

test "format bar" {
    const style = comptime Style.parse("{bar:10} {percent}");
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try style.format(&w, .{ .pos = 50, .len = 100 }, 80);
    try std.testing.expectEqualStrings("[#####-----] 50%", w.buffered());
}

test "NO_COLOR strips colors, keeps structure (§3.2)" {
    const style = comptime Style.parse("{bar:5.red} {percent}");
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    terminal_mod.color_disabled = false;
    try style.format(&w, .{ .pos = 50, .len = 100 }, 80);
    const colored = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[") != null);

    w = std.Io.Writer.fixed(&buf);
    terminal_mod.color_disabled = true;
    defer terminal_mod.color_disabled = false;
    try style.format(&w, .{ .pos = 50, .len = 100 }, 80);
    try std.testing.expectEqualStrings("[##---] 50%", w.buffered());
}
