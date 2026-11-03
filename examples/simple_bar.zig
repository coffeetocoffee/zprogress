const std = @import("std");
const zprogress = @import("zprogress");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var bar = try zprogress.Bar.init(init.gpa, io, out, .{
        .len = 100,
        .style = comptime zprogress.Style.parse("{bar:40} {pos}/{len} {percent} {eta}"),
        .terminal_file = std.Io.File.stdout(),
    });
    defer bar.deinit();

    var uninstaller = try zprogress.signal.install();
    defer uninstaller.deinit();

    for (0..101) |i| {
        if (zprogress.signal.interrupted()) return; // clean exit; restore in deinit
        bar.setPos(i);
        _ = bar.tick();
        try io.sleep(.{ .nanoseconds = 30 * std.time.ns_per_ms }, .awake);
    }
    bar.finish();
}
