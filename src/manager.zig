//! Manager: owns terminal, schedules redraws, line-diffs frames (§3.5).
//! P2: multi-mount + tree rendering, per-line diff emit, reflow, and the
//! io.async background driver isolated in driveRefresh() (§5).

const std = @import("std");
const terminal_mod = @import("terminal.zig");
const frame_mod = @import("frame.zig");
const state_mod = @import("state.zig");
const template = @import("template.zig");
const signal = @import("signal.zig");

pub const TickResult = enum { ok, interrupted };

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    terminal: terminal_mod.Terminal,

    /// Mounted renderers, in draw order (§3.5). P1's single root is now
    /// mounts[0]; trees are mounted as a MountKind.tree root node.
    mounts: std.ArrayListUnmanaged(Mount) = .empty,
    /// Tree roots created via addTree (owned by the manager).
    roots: std.ArrayListUnmanaged(*state_mod.Node) = .empty,

    frame_a: frame_mod.FrameBuffer,
    frame_b: frame_mod.FrameBuffer,
    lines_drawn: u16 = 0,
    tick_count: u64 = 0,
    plain_emitted: bool = false,

    /// Background refresh via std.Io.async, not std.Thread (§10).
    refresh_task: ?std.Io.Future(void) = null,
    refresh_interval_ns: u64 = 100 * std.time.ns_per_ms,
    stop_refresh: std.atomic.Value(u8) = .init(0),

    /// Guards mounts & cursor state. Node pos updates do NOT take this.
    /// The refresh task uses tryLock; public API uses lock (§3.5).
    lock: std.Io.Mutex = std.Io.Mutex.init,
    now_override_ns: ?u64 = null,

    pub const Mount = union(enum) {
        bar: *state_mod.Node,
        spinner: *state_mod.Node,
        custom: Custom,
    };

    pub const Custom = struct {
        ptr: *anyopaque,
        heightFn: *const fn (*anyopaque) u16,
        drawFn: *const fn (*anyopaque, *std.Io.Writer, DrawContext) anyerror!void,
        /// Optional: called each tick before draw (LogLineRenderer drains).
        drainFn: ?*const fn (*anyopaque) void = null,
    };

    pub const DrawContext = struct {
        terminal_width: u16,
        tick: u64,
        mode: terminal_mod.Mode,
    };

    pub fn init(io: std.Io, allocator: std.mem.Allocator, out: *std.Io.Writer) !Manager {
        return .{
            .allocator = allocator,
            .io = io,
            .out = out,
            .terminal = terminal_mod.Terminal.init(out, .{}),
            .frame_a = try frame_mod.FrameBuffer.init(allocator, 8 * 1024),
            .frame_b = try frame_mod.FrameBuffer.init(allocator, 8 * 1024),
        };
    }

    /// Attach the terminal file for TTY detection and width query (§3.2).
    pub fn attachTerminalFile(self: *Manager, file: std.Io.File) void {
        self.terminal.io = self.io;
        self.terminal.file = file;
        const tty = file.isTty(self.io) catch false;
        self.terminal.mode = if (tty) .tty else .plain;
    }

    /// Create a tree root. Ownership transfers to the Manager.
    pub fn addTree(self: *Manager, opts: struct {
        label: []const u8,
        style: template.Style,
        /// 0 = pure grouping node (no own progress). >0 = plain-mode
        /// aggregation emits this line on finish (§6).
        len: u32 = 0,
    }) !*state_mod.Node {
        const n = try self.allocator.create(state_mod.Node);
        errdefer self.allocator.destroy(n);
        n.* = try state_mod.Node.init(self.allocator, opts.len, opts.label, opts.style);
        try self.roots.append(self.allocator, n);
        return n;
    }

    /// Mount a bar node in draw order.
    pub fn mountBar(self: *Manager, n: *state_mod.Node) !void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        try self.mounts.append(self.allocator, .{ .bar = n });
    }

    /// Mount any renderer (height + draw). Does NOT take ownership (§3.4).
    pub fn mount(self: *Manager, custom: Custom) !void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        try self.mounts.append(self.allocator, .{ .custom = custom });
    }

    /// Deferred unmount (§3.4): takes the lock, removes the mount.
    pub fn unmountAll(self: *Manager) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.mounts.clearRetainingCapacity();
    }

    /// Start the background refresh driver (§5 seam: everything std.Io-
    /// specific about the redraw loop lives here and in refreshLoop).
    pub fn startRefresh(self: *Manager) !void {
        if (self.refresh_task != null) return;
        self.refresh_task = try std.Io.async(self.io, refreshLoop, .{self});
    }

    fn refreshLoop(self: *Manager) void {
        while (self.stop_refresh.load(.acquire) == 0) {
            if (self.lock.tryLock()) {
                defer self.lock.unlock(self.io);
                _ = self.tickLocked();
            }
            std.Io.sleep(.{ .nanoseconds = @intCast(self.refresh_interval_ns) }, .awake, self.io) catch return;
        }
    }

    pub fn deinit(self: *Manager) void {
        // Task/refresh lifecycle (§4): stop, cancel, join, then restore.
        if (self.refresh_task) |*f| {
            self.stop_refresh.store(1, .release);
            _ = f.cancel(self.io);
            _ = f.await(self.io);
            self.refresh_task = null;
        }
        self.restore();
        self.deinitTrees();
        self.mounts.deinit(self.allocator);
        self.roots.deinit(self.allocator);
        self.frame_a.deinit(self.allocator);
        self.frame_b.deinit(self.allocator);
    }

    fn deinitTrees(self: *Manager) void {
        for (self.roots.items) |root| deinitTree(self.allocator, root);
    }

    fn deinitTree(allocator: std.mem.Allocator, node: *state_mod.Node) void {
        for (node.children.items) |c| deinitTree(allocator, c);
        node.deinit(allocator);
        allocator.destroy(node);
    }

    /// Explicit redraw (sync mode). Public API path: takes the lock.
    pub fn tick(self: *Manager) TickResult {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        return self.tickLocked();
    }

    /// The entire redraw path. Caller holds self.lock.
    fn tickLocked(self: *Manager) TickResult {
        signal.drain(); // clear self-pipe (no-op on Windows / uninstalled)
        if (signal.interrupted()) {
            self.restoreLocked();
            return .interrupted;
        }

        const now_ns: u64 = self.now_override_ns orelse blk: {
            const t = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
            break :blk @intCast(@max(0, t));
        };

        // Re-query width each tick; changed width -> reflow (§3.4/§6).
        const term_width = self.terminal.width();

        if (self.terminal.mode != .tty) {
            self.plainModeLocked(now_ns);
            return .ok;
        }

        self.frame_a.reset();
        self.frame_a.ensureAvailable(self.allocator, 4096) catch return .ok;
        var w = self.frame_a.writer();

        var new_lines: u16 = 0;
        for (self.mounts.items) |m| {
            switch (m) {
                .bar => |n| {
                    new_lines += writeNodeLine(&w, n, now_ns, term_width);
                },
                .spinner => |n| {
                    new_lines += writeNodeLine(&w, n, now_ns, term_width);
                },
                .custom => |c| {
                    if (c.drainFn) |d| d(c.ptr);
                    c.drawFn(c.ptr, &w, .{
                        .terminal_width = term_width,
                        .tick = self.tick_count,
                        .mode = self.terminal.mode,
                    }) catch {};
                    new_lines += c.heightFn(c.ptr);
                },
            }
        }

        // Tree roots: walk and render (collapse-on-finish, §3.3).
        // Roots that are themselves mounted bars render via the mount
        // loop; their children still render here.
        for (self.roots.items) |root| {
            if (!self.isMounted(root)) {
                new_lines += self.writeTree(&w, root, now_ns, term_width);
            } else if (root.children.items.len > 0) {
                // Render only the children of a mounted root.
                for (root.children.items) |child| {
                    new_lines += writeTreeChild(&w, child, now_ns, term_width);
                }
            }
        }

        self.frame_a.commit(&w);
        const cur_count: u16 = @intCast(countLines(self.frame_a.written()));

        // Cursor back up to the block start; emitDiff decides between
        // in-place per-line diff and suffix reflow (§3.4).
        if (self.lines_drawn > 0) {
            self.terminal.moveUp(self.lines_drawn) catch {};
        }
        self.emitDiffLocked(cur_count);
        self.lines_drawn = cur_count;

        self.out.flush() catch {};
        std.mem.swap(frame_mod.FrameBuffer, &self.frame_a, &self.frame_b);
        self.tick_count += 1;
        return .ok;
    }

    /// Emit only changed lines vs frame_b (§3.5). Caller has moved the
    /// cursor to the block start (moveUp over lines_drawn).
    ///
    /// Same geometry: rewrite changed lines in place, skip unchanged
    /// with a cursor-down.
    ///
    /// Height change: suffix reflow (§3.4) — cursor down to the FIRST
    /// changed line, clearBelow, rewrite that line and everything below.
    /// Content above the first change stays untouched on screen.
    fn emitDiffLocked(self: *Manager, cur_count: u16) void {
        const cur = self.frame_a.written();
        const prev = self.frame_b.written();
        const first_frame = self.tick_count == 0;
        const prev_count: u16 = if (first_frame) 0 else @intCast(countLines(prev));
        const height_changed = !first_frame and cur_count != prev_count;

        if (first_frame) {
            self.out.writeAll(cur) catch {};
            return;
        }

        if (height_changed) {
            // Suffix reflow (§3.4): first CHANGED line starts the suffix;
            // everything above it is untouched on screen.
            var it_c = std.mem.splitScalar(u8, cur, '\n');
            var it_p = std.mem.splitScalar(u8, prev, '\n');
            var first_diff: u16 = 0;
            const scan_max = @min(cur_count, prev_count);
            var i: u16 = 0;
            while (i < scan_max) : (i += 1) {
                if (!std.mem.eql(u8, it_c.next().?, it_p.next().?)) {
                    first_diff = i;
                    break;
                }
            }
            // Identical prefix (pure append): suffix starts at the first
            // NEW line.
            if (i == scan_max) first_diff = scan_max;
            if (first_diff > 0) self.terminal.moveDown(first_diff) catch {};
            self.terminal.clearBelow() catch {};
            var it = std.mem.splitScalar(u8, cur, '\n');
            var skip = first_diff;
            while (skip > 0) : (skip -= 1) _ = it.next();
            var remaining = cur_count - first_diff;
            while (remaining > 0) : (remaining -= 1) {
                self.out.writeAll(it.next().?) catch {};
                self.out.writeAll("\r\n") catch {};
            }
            return;
        }

        // Same geometry: per-line in-place emit.
        var it_cur = std.mem.splitScalar(u8, cur, '\n');
        var it_prev = std.mem.splitScalar(u8, prev, '\n');
        var line_no: u16 = 0;
        while (line_no < cur_count) : (line_no += 1) {
            const lc = it_cur.next().?;
            const lp = it_prev.next().?;
            if (std.mem.eql(u8, lc, lp)) {
                self.terminal.moveDown(1) catch {};
                continue;
            }
            self.terminal.clearLine() catch {};
            self.out.writeAll(lc) catch {};
            self.out.writeAll("\r\n") catch {};
        }
        // Cursor now parks on the line after the block.
    }

    fn isMounted(self: *Manager, n: *state_mod.Node) bool {
        for (self.mounts.items) |m| switch (m) {
            .bar, .spinner => |mn| if (mn == n) return true,
            .custom => {},
        };
        return false;
    }

    fn writeNodeLine(w: *std.Io.Writer, n: *state_mod.Node, now_ns: u64, term_width: u16) u16 {
        var msg_buf: [256]u8 = undefined;
        var f = n.frame(now_ns, &msg_buf);
        if (n.finished) f.pos = f.len; // final frame at completion
        n.style.format(w, f, term_width) catch {};
        w.writeAll("\n") catch {};
        return 1;
    }

    /// Walk a node subtree. Finished children collapse to one compact
    /// line (§3.3); unfinished render with their style.
    fn writeTree(self: *Manager, w: *std.Io.Writer, node: *state_mod.Node, now_ns: u64, term_width: u16) u16 {
        _ = self;
        var lines: u16 = 0;
        var msg_buf: [256]u8 = undefined;
        var f = node.frame(now_ns, &msg_buf);
        if (node.finished) f.pos = f.len;

        if (node.finished and node.children.items.len > 0) {
            // Collapsed: label + summary + child count.
            w.print("[done] {s} ({d} subtasks)\n", .{ node.label, node.children.items.len }) catch {};
            return 1;
        }

        const d = node.depth();
        if (d > 0) {
            w.splatByteAll(' ', @as(usize, d) * 2) catch {};
        }
        node.style.format(w, f, if (term_width > d * 2) term_width - d * 2 else term_width) catch {};
        w.print(" {s}", .{node.label}) catch {};
        w.writeAll("\n") catch {};
        lines += 1;

        for (node.children.items) |child| {
            lines += writeTreeChild(w, child, now_ns, term_width);
        }
        return lines;
    }

    fn writeTreeChild(w: *std.Io.Writer, node: *state_mod.Node, now_ns: u64, term_width: u16) u16 {
        var msg_buf: [256]u8 = undefined;
        var f = node.frame(now_ns, &msg_buf);
        if (node.finished) f.pos = f.len;

        if (node.finished) {
            // Collapsed line: label + 100% + elapsed (§3.3).
            const s: f64 = @as(f64, @floatFromInt(f.elapsed_ns)) / std.time.ns_per_s;
            w.print("  [done] {s} 100% {d:.1}s\n", .{ node.label, s }) catch {};
            return 1;
        }

        const d = node.depth();
        w.splatByteAll(' ', @as(usize, d) * 2) catch {};
        node.style.format(w, f, if (term_width > d * 2) term_width - d * 2 else term_width) catch {};
        w.print(" {s}", .{node.label}) catch {};
        w.writeAll("\n") catch {};

        var lines: u16 = 1;
        for (node.children.items) |child| {
            lines += writeTreeChild(w, child, now_ns, term_width);
        }
        return lines;
    }

    /// Plain mode (§6): manager aggregates — each root's finish emits its
    /// line; deinit emits still-unfinished roots with their final %.
    fn plainModeLocked(self: *Manager, now_ns: u64) void {
        for (self.roots.items) |root| {
            if (self.plain_emitted) break;
            if (root.len == 0 and root.children.items.len > 0) {
                // Grouping root (len 0): aggregate children (§6).
                if (treeDone(root)) {
                    var total: u64 = 0;
                    var done: u64 = 0;
                    sumTree(root, &total, &done);
                    self.plainEmitLine(root.label, done, total);
                }
            } else if (root.finished or (root.len > 0 and root.getPos() >= root.len)) {
                self.plainEmitLine(root.label, root.len, root.len);
            }
        }
        for (self.mounts.items) |m| {
            switch (m) {
                .bar, .spinner => |n| {
                    if (!n.finished and n.parent != null and n.len > 0 and n.getPos() >= n.len) {
                        n.finished = true;
                        self.out.print("{d}/{d} 100%\n", .{ n.len, n.len }) catch {};
                    }
                },
                .custom => {},
            }
        }
        _ = now_ns;
        self.out.flush() catch {};
    }

    fn plainEmitLine(self: *Manager, label: []const u8, done: u64, total: u64) void {
        if (label.len > 0)
            self.out.print("{s}: {d}/{d} 100%\n", .{ label, done, total }) catch {}
        else
            self.out.print("{d}/{d} 100%\n", .{ done, total }) catch {};
        self.plain_emitted = true;
    }

    /// Finish a node (§3.3): pos = len, idempotent, manager-locked.
    pub fn finish(self: *Manager, n: *state_mod.Node) void {
        n.setPos(n.len);
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        n.finished = true;
        if (n.parent == null) {
            // Root finished: plain-mode emits its line on next tick.
        }
    }

    /// Show cursor, clear manager region. Safe from any thread.
    /// Does NOT take the lock (§ signal contract).
    pub fn restore(self: *Manager) void {
        self.restoreLocked();
    }

    fn restoreLocked(self: *Manager) void {
        if (self.terminal.mode != .tty) return;
        if (self.lines_drawn > 0) {
            self.terminal.moveUp(self.lines_drawn) catch {};
            self.terminal.clearBelow() catch {};
            self.lines_drawn = 0;
        }
        self.terminal.showCursor() catch {};
        self.out.flush() catch {};
    }
};

fn countLines(data: []const u8) usize {
    var n: usize = 0;
    for (data) |c| {
        if (c == '\n') n += 1;
    }
    if (data.len > 0 and data[data.len - 1] != '\n') n += 1;
    return n;
}

fn treeDone(node: *state_mod.Node) bool {
    for (node.children.items) |c| {
        if (!(c.finished or (c.len > 0 and c.getPos() >= c.len))) return false;
    }
    return node.children.items.len > 0;
}

fn sumTree(node: *state_mod.Node, total: *u64, done: *u64) void {
    for (node.children.items) |c| {
        if (c.children.items.len > 0) {
            sumTree(c, total, done);
        } else {
            total.* += c.len;
            done.* += @min(c.getPos(), c.len);
        }
    }
}

test "height change: suffix reflow from first changed line (§3.4)" {
    const allocator = std.testing.allocator;
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var mgr = try Manager.init(std.Io.failing, allocator, &w);
    mgr.terminal.mode = .tty;
    mgr.terminal.width_override = 40;
    mgr.now_override_ns = 0;
    defer mgr.deinit();

    const root = try mgr.addTree(.{ .label = "", .len = 10, .style = comptime template.Style.parse("{percent}R") });
    try mgr.mountBar(root);

    root.setPos(5);
    _ = mgr.tick(); // 1 line: "50%R"
    const stable = w.buffered();

    // Grow the tree: new child -> 2 lines. Line 0 unchanged ("50%R"),
    // so reflow must NOT re-emit line 0's content.
    w = std.Io.Writer.fixed(&buf);
    const child = try root.addChild(allocator, .{ .len = 5, .label = "", .style = comptime template.Style.parse("{percent}C") });
    child.setPos(1);
    _ = mgr.tick();

    const grown = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, grown, "20%C") != null);
    // Line 0 skipped by cursor-down (suffix starts at line 1), not rewritten:
    try std.testing.expect(std.mem.indexOf(u8, grown, "50%R") == null);
    try std.testing.expect(std.mem.indexOf(u8, grown, "\x1b[1B") != null);
    // The clearBelow for the suffix is present:
    try std.testing.expect(std.mem.indexOf(u8, grown, "\x1b[J") != null);
    _ = stable;
}

test "width change reflows frames (§3.4)" {
    const allocator = std.testing.allocator;
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var mgr = try Manager.init(std.Io.failing, allocator, &w);
    mgr.terminal.mode = .tty;
    mgr.now_override_ns = 0;
    defer mgr.deinit();

    const root = try mgr.addTree(.{ .label = "", .len = 100, .style = comptime template.Style.parse("[{bar:40}]") });
    try mgr.mountBar(root);
    root.setPos(50);

    mgr.terminal.width_override = 50;
    _ = mgr.tick();
    var rendered = w.buffered();
    const b1 = barCells(rendered);
    try std.testing.expectEqual(@as(usize, 40), b1.len); // 40 <= 48 avail: no shrink
    try std.testing.expectEqual(@as(usize, 20), std.mem.count(u8, b1, "#"));

    // Resize: next tick re-queries width and re-formats (reflow).
    mgr.terminal.width_override = 30;
    w = std.Io.Writer.fixed(&buf); // keep only the second frame
    _ = mgr.tick();
    rendered = w.buffered();    const b2 = barCells(rendered);
    try std.testing.expectEqual(@as(usize, 28), b2.len);
    try std.testing.expectEqual(@as(usize, 14), std.mem.count(u8, b2, "#"));
    try std.testing.expectEqual(@as(u16, 1), mgr.lines_drawn);
}

/// Returns the bar cell region of the first "[...]" in the frame.
fn barCells(rendered: []const u8) []const u8 {
    const start = std.mem.indexOf(u8, rendered, "[#") orelse return "";
    const end = std.mem.indexOfScalarPos(u8, rendered, start, ']') orelse return "";
    return rendered[start + 1 .. end];
}

test "manager multi-mount plain mode" {
    const allocator = std.testing.allocator;
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var mgr = try Manager.init(std.Io.failing, allocator, &w);
    mgr.terminal.mode = .plain;
    defer mgr.deinit();

    const a = try mgr.addTree(.{ .label = "build", .len = 59, .style = comptime template.Style.parse("{percent}") });
    try mgr.mountBar(a);

    mgr.now_override_ns = 0;
    _ = mgr.tick(); // unfinished: nothing yet
    try std.testing.expectEqual(@as(usize, 0), w.end);
    a.setPos(59);
    _ = mgr.tick();
    try std.testing.expectEqualStrings("build: 59/59 100%\n", w.buffered());
}

test "TreeRenderer standalone (P3 extraction)" {
    const allocator = std.testing.allocator;
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var mgr = try Manager.init(std.Io.failing, allocator, &w);
    mgr.now_override_ns = 0;
    defer mgr.deinit();

    const root = try mgr.addTree(.{ .label = "build", .len = 4, .style = comptime template.Style.parse("[{bar:5}]") });
    const c = try root.addChild(allocator, .{ .len = 2, .label = "pkg", .style = comptime template.Style.parse("[{bar:5}]") });
    c.setPos(2);
    mgr.finish(c);

    const tree_mod = @import("render/tree.zig");
    var tr = tree_mod.TreeRenderer.init(root);
    tr.now_ns = 0;
    tr.term_width = 40;
    try std.testing.expectEqual(@as(u16, 2), tr.height());
    tr.draw(&w);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "[done] pkg 100% 0.0s") != null);
}
test "diff emit skips unchanged lines (�3.5)" {
    const allocator = std.testing.allocator;
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var mgr = try Manager.init(std.Io.failing, allocator, &w);
    mgr.terminal.mode = .tty;
    mgr.terminal.width_override = 40;
    mgr.now_override_ns = 0;
    defer mgr.deinit();

    const a = try mgr.addTree(.{ .label = "", .len = 10, .style = comptime template.Style.parse("{percent}A") });
    const b = try mgr.addTree(.{ .label = "", .len = 10, .style = comptime template.Style.parse("{percent}B") });
    try mgr.mountBar(a);
    try mgr.mountBar(b);

    a.setPos(5);
    b.setPos(5);
    _ = mgr.tick();
    const f1 = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, f1, "50%A") != null);
    try std.testing.expect(std.mem.indexOf(u8, f1, "50%B") != null);

    w = std.Io.Writer.fixed(&buf);
    a.setPos(6);
    _ = mgr.tick();
    const f2 = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, f2, "60%A") != null);
    try std.testing.expect(std.mem.indexOf(u8, f2, "50%B") == null);
    try std.testing.expect(std.mem.indexOf(u8, f2, "\x1b[1B") != null);
}

test "log line renderer mount + drain (P3)" {
    const allocator = std.testing.allocator;
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var mgr = try Manager.init(std.Io.failing, allocator, &w);
    mgr.terminal.mode = .tty;
    mgr.terminal.width_override = 40;
    mgr.now_override_ns = 0;
    defer mgr.deinit();

    var log = try @import("log_line.zig").LogLineRenderer.init(allocator, 4);
    defer log.deinit();

    log.push("line one");
    log.push("line two");

    try mgr.mount(.{
        .ptr = @ptrCast(&log),
        .heightFn = (struct {
            fn h(p: *anyopaque) u16 {
                const r: *@import("log_line.zig").LogLineRenderer = @ptrCast(@alignCast(p));
                return r.height();
            }
        }).h,
        .drawFn = (struct {
            fn d(p: *anyopaque, writer: *std.Io.Writer, _: Manager.DrawContext) anyerror!void {
                const r: *@import("log_line.zig").LogLineRenderer = @ptrCast(@alignCast(p));
                r.draw(writer);
            }
        }).d,
        .drainFn = (struct {
            fn dr(p: *anyopaque) void {
                const r: *@import("log_line.zig").LogLineRenderer = @ptrCast(@alignCast(p));
                r.drain();
            }
        }).dr,
    });

    _ = mgr.tick();
    const rendered = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "line one") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "line two") != null);
    try std.testing.expectEqual(@as(u16, 2), mgr.lines_drawn);
}
