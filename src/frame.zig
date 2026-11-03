//! Frame buffers + line diffing (§3.5). Manager-owned, retained across
//! ticks. Growth by doubling; never truncation.

const std = @import("std");

pub const FrameBuffer = struct {
    data: []u8,
    len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !FrameBuffer {
        return .{ .data = try allocator.alloc(u8, capacity) };
    }

    pub fn deinit(self: *FrameBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }

    pub fn reset(self: *FrameBuffer) void {
        self.len = 0;
    }

    pub fn written(self: *const FrameBuffer) []const u8 {
        return self.data[0..self.len];
    }

    pub fn grow(self: *FrameBuffer, allocator: std.mem.Allocator, needed: usize) !void {
        if (needed <= self.data.len) return;
        var cap = self.data.len;
        while (cap < needed) cap *= 2;
        self.data = try allocator.realloc(self.data, cap);
    }

    /// Fixed writer over the buffer's spare capacity. Caller must ensure
    /// capacity beforehand (ensureAvailable) — the writer cannot grow.
    pub fn writer(self: *FrameBuffer) std.Io.Writer {
        return .{
            .buffer = self.data[self.len..],
            .end = 0,
            .vtable = &sink_vtable,
        };
    }

    pub fn commit(self: *FrameBuffer, w: *const std.Io.Writer) void {
        self.len += w.end;
    }

    /// Grow until `extra` spare bytes exist. Returns false if the frame
    /// did not fit even after growth (caller gave up).
    pub fn ensureAvailable(self: *FrameBuffer, allocator: std.mem.Allocator, extra: usize) !void {
        try self.grow(allocator, self.len + extra);
    }

    const sink_vtable: std.Io.Writer.VTable = .{
        .drain = sinkDrain,
        .flush = sinkFlush,
        .rebase = sinkRebase,
        .sendFile = sinkSendFile,
    };

    fn sinkDrain(_: *std.Io.Writer, _: []const []const u8, _: usize) std.Io.Writer.Error!usize {
        return error.WriteFailed; // fixed sink: overflow must not be silently dropped
    }

    fn sinkFlush(_: *std.Io.Writer) std.Io.Writer.Error!void {}

    fn sinkRebase(w: *std.Io.Writer, preserved: usize, _: usize) std.Io.Writer.Error!void {
        w.end = preserved;
    }

    fn sinkSendFile(_: *std.Io.Writer, _: *std.Io.File.Reader, _: std.Io.Limit) std.Io.Writer.FileError!usize {
        return error.Unimplemented;
    }
};

/// Diff two frame buffers line-by-line; return true if any line changed.
/// Lines are \n-separated; final segment without \n counts as a line.
pub fn diffChanged(a: []const u8, b: []const u8) bool {
    var it_a = std.mem.splitScalar(u8, a, '\n');
    var it_b = std.mem.splitScalar(u8, b, '\n');
    while (true) {
        const la = it_a.next();
        const lb = it_b.next();
        if (la == null and lb == null) return false;
        if (la == null or lb == null) return true;
        if (!std.mem.eql(u8, la.?, lb.?)) return true;
    }
}

test "frame buffer roundtrip" {
    const allocator = std.testing.allocator;
    var fb = try FrameBuffer.init(allocator, 8);
    defer fb.deinit(allocator);

    try fb.ensureAvailable(allocator, 64);
    var w = fb.writer();
    try w.print("line {d}\n", .{1});
    fb.commit(&w);
    try std.testing.expectEqualStrings("line 1\n", fb.written());

    fb.reset();
    var w2 = fb.writer();
    try w2.print("longer line that exceeds initial {d} capacity\n", .{8});
    fb.commit(&w2);
    try std.testing.expectEqualStrings("longer line that exceeds initial 8 capacity\n", fb.written());
}

test "diff" {
    try std.testing.expect(diffChanged("a\nb", "a\nc"));
    try std.testing.expect(!diffChanged("a\nb", "a\nb"));
    try std.testing.expect(diffChanged("a\nb", "a\nb\nc"));
}
