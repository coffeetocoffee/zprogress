//! Progress state: node tree + monotonic atomic pos (§3.3, P2).
//! Workers only touch pos/message; the manager samples everything else.

const std = @import("std");
const template = @import("template.zig");

/// Node-owned message storage (§3.1/§4). setMessage copies into this;
/// the manager reads it only during its tick. Guard is a small spinlock:
/// the critical section is a ≤256-byte memcpy; workers never hold it
/// across I/O. (std.Io.Mutex needs an io handle workers don't carry.)
pub const MessageSlot = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,
    guard: std.atomic.Value(u8) = .init(0),

    fn acquire(self: *MessageSlot) void {
        while (self.guard.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn release(self: *MessageSlot) void {
        self.guard.store(0, .release);
    }

    pub fn set(self: *MessageSlot, src: []const u8) void {
        self.acquire();
        defer self.release();
        const n = @min(src.len, self.buf.len);
        @memcpy(self.buf[0..n], src[0..n]);
        self.len = n;
    }

    /// Read into `out`; returns the copied slice.
    pub fn get(self: *MessageSlot, out: []u8) []const u8 {
        self.acquire();
        defer self.release();
        const n = @min(self.len, out.len);
        @memcpy(out[0..n], self.buf[0..n]);
        return out[0..n];
    }
};

pub const Node = struct {
    pos: std.atomic.Value(u32) = .init(0),
    len: u32, // immutable after creation

    finished: bool = false, // manager-written, manager-read (§3.3)

    // Tree. Ownership: root belongs to the Manager; addChild transfers
    // to the parent. No removeNode in this phase (§3.3).
    children: std.ArrayListUnmanaged(*Node) = .empty,
    parent: ?*Node = null,

    label: []const u8, // COPIED into node-owned storage; freed in deinitTree

    style: template.Style,
    message: MessageSlot = .{},

    started_at_ns: u64 = 0, // manager-set on first tick

    pub fn init(allocator: std.mem.Allocator, len: u32, label: []const u8, style: template.Style) !Node {
        const owned = try allocator.dupe(u8, label);
        return .{ .len = len, .label = owned, .style = style };
    }

    /// Frees label + children list. Nodes are freed by Manager.deinitTree.
    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        self.children.deinit(allocator);
        allocator.free(self.label);
    }

    /// Lock-free, any thread. Monotonic: a smaller value is ignored
    /// (API misuse guard, §3.3).
    pub fn setPos(self: *Node, n: u32) void {
        var cur = self.pos.load(.monotonic);
        while (n > cur) {
            cur = self.pos.cmpxchgWeak(cur, n, .monotonic, .monotonic) orelse return;
        }
    }

    pub fn getPos(self: *const Node) u32 {
        return self.pos.load(.monotonic);
    }

    /// Set the borrowed/copied message from any thread. One copy per
    /// message, not per frame (§3.1).
    pub fn setMessage(self: *Node, src: []const u8) void {
        self.message.set(src);
    }

    /// Appends a child. Ownership transfers to `self`. Returns the child.
    /// NOT thread-safe: tree shape is mutated before concurrent workers
    /// start, or from the manager thread.
    pub fn addChild(self: *Node, allocator: std.mem.Allocator, opts: struct {
        len: u32,
        label: []const u8,
        style: template.Style,
    }) !*Node {
        const child = try allocator.create(Node);
        errdefer allocator.destroy(child);
        child.* = try Node.init(allocator, opts.len, opts.label, opts.style);
        child.parent = self;
        try self.children.append(allocator, child);
        return child;
    }

    /// Depth in the tree (root = 0). Used for tree indent.
    pub fn depth(self: *const Node) u16 {
        var d: u16 = 0;
        var p = self.parent;
        while (p) |parent| : (p = parent.parent) d += 1;
        return d;
    }

    /// Build a frame for rendering. The message is copied into
    /// `msg_buf` (caller-owned stack storage, alive through format()).
    /// First call stamps `started_at_ns`, which is what elapsed/eta/speed
    /// measure from.
    pub fn frame(self: *Node, now_ns: u64, msg_buf: []u8) template.Frame {
        if (self.started_at_ns == 0) self.started_at_ns = now_ns;
        return .{
            .pos = self.pos.load(.monotonic),
            .len = self.len,
            .elapsed_ns = if (self.started_at_ns == 0) 0 else now_ns - self.started_at_ns,
            .spinner_tick = now_ns / std.time.ns_per_ms / 100,
            .message = self.message.get(msg_buf),
        };
    }
};

test "monotonic setPos" {
    var n: Node = .{ .len = 100, .label = "", .style = undefined };
    n.setPos(50);
    n.setPos(30); // ignored: backwards
    try std.testing.expectEqual(@as(u64, 50), n.getPos());
    n.setPos(75);
    try std.testing.expectEqual(@as(u64, 75), n.getPos());
}

test "frame stamps started_at on first sample" {
    var n: Node = .{ .len = 10, .label = "", .style = undefined };
    var buf: [8]u8 = undefined;
    const first = n.frame(1 * std.time.ns_per_s, &buf);
    try std.testing.expectEqual(@as(u64, 0), first.elapsed_ns);
    const later = n.frame(3 * std.time.ns_per_s, &buf);
    try std.testing.expectEqual(@as(u64, 2 * std.time.ns_per_s), later.elapsed_ns);
}

test "message slot" {
    var n: Node = .{ .len = 10, .label = "", .style = undefined };
    n.setMessage("hello");
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hello", n.message.get(&buf));
    n.setMessage("a much longer message that fits");
    try std.testing.expectEqualStrings("a much longer message that fits", n.message.get(&buf));
}

test "tree addChild ownership" {
    const allocator = std.testing.allocator;
    var root = try Node.init(allocator, 59, "build", undefined);
    defer {
        for (root.children.items) |c| {
            for (c.children.items) |gc| {
                gc.deinit(allocator);
                allocator.destroy(gc);
            }
            c.deinit(allocator);
            allocator.destroy(c);
        }
        root.deinit(allocator);
    }

    const a = try root.addChild(allocator, .{ .len = 42, .label = "pkg-a", .style = undefined });
    const b = try root.addChild(allocator, .{ .len = 17, .label = "pkg-b", .style = undefined });
    try std.testing.expectEqual(@as(usize, 2), root.children.items.len);
    try std.testing.expectEqual(@as(u16, 1), a.depth());
    try std.testing.expectEqualStrings("pkg-b", b.label);
    try std.testing.expect(root.children.items[0] == a);
}
