//! TreeRenderer — composite renderer that walks a Node tree (§3.4, P3).
//! Extracted from the Manager so the mount interface is dogfooded: a tree
//! is just another Renderer with height() + draw().

const std = @import("std");
const state_mod = @import("../state.zig");
const template = @import("../template.zig");

pub const TreeRenderer = struct {
    root: *state_mod.Node,
    now_ns: u64 = 0,
    term_width: u16 = 80,

    pub fn init(root: *state_mod.Node) TreeRenderer {
        return .{ .root = root };
    }

    /// Visible line count: finished roots collapse their children.
    pub fn height(self: *TreeRenderer) u16 {
        return visibleCount(self.root);
    }

    pub fn draw(self: *TreeRenderer, w: *std.Io.Writer) void {
        drawNode(self.root, w, self.now_ns, self.term_width);
    }

    pub fn visibleCountStatic(node: *state_mod.Node) u16 {
        return visibleCount(node);
    }

    pub fn drawChildStatic(node: *state_mod.Node, w: *std.Io.Writer, now_ns: u64, term_width: u16) void {
        drawChild(node, w, now_ns, term_width);
    }

pub fn visibleCount(node: *state_mod.Node) u16 {
        if (node.finished and node.children.items.len > 0) return 1;
        var n: u16 = 1;
        for (node.children.items) |c| n += visibleCount(c);
        return n;
    }

    fn drawNode(node: *state_mod.Node, w: *std.Io.Writer, now_ns: u64, term_width: u16) void {
        var msg_buf: [256]u8 = undefined;
        var f = node.frame(now_ns, &msg_buf);
        if (node.finished) f.pos = f.len;

        if (node.finished and node.children.items.len > 0) {
            w.print("[done] {s} ({d} subtasks)\n", .{ node.label, node.children.items.len }) catch {};
            return;
        }

        const d = node.depth();
        if (d > 0) w.splatByteAll(' ', @as(usize, d) * 2) catch {};
        node.style.format(w, f, if (term_width > d * 2) term_width - d * 2 else term_width) catch {};
        w.print(" {s}\n", .{node.label}) catch {};

        for (node.children.items) |c| drawChild(c, w, now_ns, term_width);
    }

pub fn drawChild(node: *state_mod.Node, w: *std.Io.Writer, now_ns: u64, term_width: u16) void {
        var msg_buf: [256]u8 = undefined;
        var f = node.frame(now_ns, &msg_buf);
        if (node.finished) f.pos = f.len;

        if (node.finished) {
            const s: f64 = @as(f64, @floatFromInt(f.elapsed_ns)) / std.time.ns_per_s;
            w.print("  [done] {s} 100% {d:.1}s\n", .{ node.label, s }) catch {};
            return;
        }

        const d = node.depth();
        w.splatByteAll(' ', @as(usize, d) * 2) catch {};
        node.style.format(w, f, if (term_width > d * 2) term_width - d * 2 else term_width) catch {};
        w.print(" {s}\n", .{node.label}) catch {};

        for (node.children.items) |c| drawChild(c, w, now_ns, term_width);
    }
};