//! loaders.zig — first real consumer of zprogress (P1/P2 validation, §12 R2).
//! Tree-shaped loading: a root with per-resource children, workers via
//! io.async, manager ticks render/collapse; plain mode when piped.

const std = @import("std");
const zprogress = @import("zprogress");

const resources = [_][]const u8{
    "config", "assets", "textures", "shaders", "audio", "fonts", "meshes", "scenes",
};

fn worker(node: *zprogress.Node, steps: u64, io: std.Io) void {
    for (0..steps) |_| {
        node.setPos(node.getPos() + 1);
        io.sleep(.{ .nanoseconds = 8 * std.time.ns_per_ms }, .awake) catch return;
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var uninstaller = try zprogress.signal.install();
    defer uninstaller.deinit();

    var mgr = try zprogress.Manager.init(io, init.gpa, out);
    defer mgr.deinit();
    mgr.attachTerminalFile(std.Io.File.stdout());

    const root = try mgr.addTree(.{
        .label = "loading",
        .style = comptime zprogress.Style.parse("{spinner} {bar:20} {percent}"),
    });
    try mgr.mountBar(root);

    var futures: [resources.len]std.Io.Future(void) = undefined;

    for (resources, 0..) |name, i| {
        const child = try root.addChild(init.gpa, .{
            .len = 25,
            .label = name,
            .style = comptime zprogress.Style.parse("{bar:12} {percent}"),
        });
        futures[i] = std.Io.async(io, worker, .{ child, 25, io });
    }

    // Manager loop: render + collapse until every child finished.
    while (true) {
        if (zprogress.signal.interrupted()) return;
        var all_done = true;
        for (root.children.items) |c| {
            if (c.getPos() >= c.len) {
                mgr.finish(c);
            } else all_done = false;
        }
        if (all_done) break;
        _ = mgr.tick();
        try io.sleep(.{ .nanoseconds = 40 * std.time.ns_per_ms }, .awake);
    }
    for (&futures) |*f| _ = f.await(io);
    mgr.finish(root);
    _ = mgr.tick();
}
