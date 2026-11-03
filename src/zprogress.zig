//! zprogress public API re-exports.

pub const template = @import("template.zig");
pub const terminal = @import("terminal.zig");
pub const state = @import("state.zig");
pub const manager = @import("manager.zig");
pub const signal = @import("signal.zig");
pub const log_line = @import("log_line.zig");
pub const LogLineRenderer = log_line.LogLineRenderer;

pub const Manager = manager.Manager;
pub const Node = state.Node;
pub const Style = template.Style;
pub const TickResult = manager.TickResult;

const std = @import("std");

/// Ergonomic single-bar wrapper (§3.6). Sync mode: caller drives tick().
/// With the new Manager this is a one-root tree mounted as a bar.
pub const Bar = struct {
    mgr: Manager,
    node: *Node,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, opts: struct {
        len: u32,
        style: Style,
        /// Set for TTY detection + width query (§3.2). Must come before
        /// the first tick so the frame respects the detected mode.
        terminal_file: ?std.Io.File = null,
        label: []const u8 = "",
    }) !Bar {
        var mgr = try Manager.init(io, allocator, out);
        errdefer mgr.deinit();
        if (opts.terminal_file) |f| mgr.attachTerminalFile(f);
        const node = try mgr.addTree(.{ .label = opts.label, .len = opts.len, .style = opts.style });
        try mgr.mountBar(node);
        return .{ .mgr = mgr, .node = node };
    }

    pub fn deinit(self: *Bar) void {
        self.mgr.deinit();
    }

    pub fn setPos(self: *Bar, n: u64) void {
        self.node.setPos(n);
    }

    pub fn tick(self: *Bar) TickResult {
        return self.mgr.tick();
    }

    /// Final frame at pos == len, then restore terminal.
    pub fn finish(self: *Bar) void {
        self.mgr.finish(self.node);
        _ = self.mgr.tick();
        self.mgr.restore();
    }
};

test {
    std.testing.refAllDecls(@This());
}
