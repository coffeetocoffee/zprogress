//! LogLineRenderer — append-only line renderer with a bounded SPSC ring
//! (§3.4, P3). Producers push complete lines; the manager drains the
//! ring during its tick and incorporates them into the frame. Producers
//! never write to the terminal.

const std = @import("std");

pub const LogLineRenderer = struct {
    allocator: std.mem.Allocator,
    /// Reserved rows: the renderer never exceeds this many visible lines;
    /// oldest lines are dropped when it does (§3.4).
    capacity: u16,

    // --- SPSC ring (producer side) ---
    ring_cap: usize,
    ring: []?[]const u8,
    head: std.atomic.Value(usize) = .init(0),
    tail: std.atomic.Value(usize) = .init(0),

    // --- Manager-thread-only retained lines ---
    lines: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, capacity: u16) !LogLineRenderer {
        const cap: usize = @max(capacity, 1);
        const ring = try allocator.alloc(?[]const u8, cap + 1);
        for (ring) |*s| s.* = null;
        return .{
            .allocator = allocator,
            .capacity = capacity,
            .ring_cap = cap + 1,
            .ring = ring,
        };
    }

    pub fn deinit(self: *LogLineRenderer) void {
        // Drain anything still in the ring.
        self.drain();
        for (self.lines.items) |l| self.allocator.free(l);
        self.lines.deinit(self.allocator);
        self.allocator.free(self.ring);
    }

    /// Producer-side push. SPSC: a single producer thread per renderer.
    /// If the ring is full, the oldest pending line is dropped. The
    /// pushed line is copied (one allocation per log line — setup-class,
    /// not the frame hot path). Never touches the terminal.
    pub fn push(self: *LogLineRenderer, line: []const u8) void {
        const owned = self.allocator.dupe(u8, line) catch return;
        const h = self.head.load(.monotonic);
        const next = (h + 1) % self.ring_cap;
        if (next == self.tail.load(.acquire)) {
            // Ring full: drop the oldest pending slot.
            if (self.ring[self.tail.load(.monotonic)]) |old| {
                self.allocator.free(old);
                self.ring[self.tail.load(.monotonic)] = null;
            }
            _ = self.tail.fetchAdd(1, .release);
        }
        self.ring[h] = owned;
        self.head.store(next, .release);
    }

    /// Manager-side drain. Moves pending lines into the retained deque,
    /// dropping the oldest visible lines when capacity is exceeded.
    pub fn drain(self: *LogLineRenderer) void {
        var t = self.tail.load(.acquire);
        const h = self.head.load(.acquire);
        while (t != h) {
            const line = self.ring[t].?;
            if (self.lines.items.len >= self.capacity) {
                const old = self.lines.orderedRemove(0);
                self.allocator.free(old);
            }
            self.lines.append(self.allocator, line) catch {
                self.allocator.free(line);
                break;
            };
            self.ring[t] = null;
            t = (t + 1) % self.ring_cap;
        }
        self.tail.store(t, .release);
    }

    /// Renderer interface.
    pub fn height(self: *LogLineRenderer) u16 {
        return @intCast(self.lines.items.len);
    }

    pub fn draw(self: *LogLineRenderer, w: *std.Io.Writer) void {
        for (self.lines.items) |line| {
            w.writeAll(line) catch {};
            w.writeAll("\n") catch {};
        }
    }

    /// Drop every retained line. Useful on clear.
    pub fn clear(self: *LogLineRenderer) void {
        for (self.lines.items) |l| self.allocator.free(l);
        self.lines.clearRetainingCapacity();
    }
};

test "ring drops oldest when full" {
    const allocator = std.testing.allocator;
    var r = try LogLineRenderer.init(allocator, 2);
    defer r.deinit();
    r.push("a");
    r.push("b");
    r.push("c"); // drops "a"
    r.drain();
    try std.testing.expectEqual(@as(usize, 2), r.lines.items.len);
    try std.testing.expectEqualStrings("b", r.lines.items[0]);
    try std.testing.expectEqualStrings("c", r.lines.items[1]);
}

test "visible capacity drops oldest" {
    const allocator = std.testing.allocator;
    var r = try LogLineRenderer.init(allocator, 2);
    defer r.deinit();
    r.push("a");
    r.push("b");
    r.push("c");
    r.push("d");
    r.drain();
    try std.testing.expectEqual(@as(usize, 2), r.lines.items.len);
    try std.testing.expectEqualStrings("c", r.lines.items[0]);
    try std.testing.expectEqualStrings("d", r.lines.items[1]);
}
