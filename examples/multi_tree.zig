const std = @import("std");
const zprogress = @import("zprogress");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var mgr = try zprogress.Manager.init(io, init.gpa, out);
    defer mgr.deinit();
    mgr.attachTerminalFile(std.Io.File.stdout());

    var uninstaller = try zprogress.signal.install();
    defer uninstaller.deinit();

    // Tree (P2): root + two children; setPos from "workers" is lock-free.
    const root = try mgr.addTree(.{
        .label = "build",
        .style = comptime zprogress.Style.parse("[{bar:20}] {percent}"),
    });
    const pkg_a = try root.addChild(init.gpa, .{
        .len = 42,
        .label = "pkg-a",
        .style = comptime zprogress.Style.parse("[{bar:20}] {percent}"),
    });
    const pkg_b = try root.addChild(init.gpa, .{
        .len = 17,
        .label = "pkg-b",
        .style = comptime zprogress.Style.parse("[{bar:20}] {percent}"),
    });
    try mgr.mountBar(root);

    // Drive both children concurrently via io.async (§4: workers only
    // touch pos). The manager samples on its tick.
    const worker = struct {
        fn run(node: *zprogress.Node, steps: u64, io2: std.Io) void {
            for (0..steps) |_| {
                node.setPos(node.getPos() + 1);
                io2.sleep(.{ .nanoseconds = 20 * std.time.ns_per_ms }, .awake) catch return;
            }
        }
    }.run;

    var fa = std.Io.async(io, worker, .{ pkg_a, 42, io });
    var fb = std.Io.async(io, worker, .{ pkg_b, 17, io });
    defer {
        _ = fa.await(io);
        _ = fb.await(io);
    }

    // Redraw loop: sync ticks here; stop when both children are done.
    while (!(pkg_a.finished and pkg_b.finished) and pkg_a.getPos() + pkg_b.getPos() < 59) {
        if (zprogress.signal.interrupted()) return;
        if (pkg_a.getPos() >= 42) mgr.finish(pkg_a);
        if (pkg_b.getPos() >= 17) mgr.finish(pkg_b);
        _ = mgr.tick();
        try io.sleep(.{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake);
    }
    mgr.finish(pkg_a);
    mgr.finish(pkg_b);
    mgr.finish(root);
    _ = mgr.tick();
}
