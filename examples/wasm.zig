//! wasm.zig — P3 WASM/freestanding smoke test (§9). Sync mode only:
//! no signal handlers, no io.async, no std.Thread. Exercises the
//! zero-alloc hot path on a target with no OS.

const std = @import("std");
const zprogress = @import("zprogress");

pub fn main() void {
    var backing: [64 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    const alloc = fba.allocator();
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const io = std.Io.failing;

    var mgr = zprogress.Manager.init(io, alloc, &w) catch return;
    defer mgr.deinit();

    const n = mgr.addTree(.{ .label = "wasm", .len = 5, .style = comptime zprogress.Style.parse("{bar:10} {percent}") }) catch return;
    mgr.mountBar(n) catch return;

    var i: u32 = 0;
    while (i <= 5) : (i += 1) {
        n.setPos(i);
        _ = mgr.tick();
    }
    mgr.finish(n);
    _ = mgr.tick();
}
