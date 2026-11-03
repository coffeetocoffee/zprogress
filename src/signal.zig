//! Signal lifecycle: flag + self-pipe + deferred restore (§3.5).
//! Handlers do ONLY signal-safe things: store the flag, write one byte
//! to the self-pipe. No I/O beyond write(2), no mutex, no restore from
//! signal context.

const std = @import("std");
const builtin = @import("builtin");

var flag: std.atomic.Value(u8) = .init(0);

// POSIX self-pipe. -1 = not installed. Written from the signal handler
// (write is async-signal-safe), drained by the manager on a normal thread.
var pipe_fds: [2]std.c.fd_t = .{ -1, -1 };

/// True once SIGINT/SIGTERM (or a Windows ctrl event) fired.
/// Public so the application may poll it in its own loop (§3.5).
pub fn interrupted() bool {
    return flag.load(.acquire) != 0;
}

/// Drains the self-pipe. The manager's tick calls this before checking
/// the flag; keeps the pipe from filling under signal storms.
pub fn drain() void {
    if (builtin.os.tag == .windows or builtin.os.tag == .freestanding or builtin.os.tag == .wasi or builtin.os.tag == .emscripten) return;
    if (pipe_fds[0] < 0) return;
    var buf: [64]u8 = undefined;
    while (true) {
        const n = std.c.read(pipe_fds[0], &buf, buf.len);
        if (n <= 0) break; // empty (EAGAIN) or closed
    }
}

/// Test hook: simulate a signal without a real one (§7).
pub fn _setForTest() void {
    flag.store(1, .release);
}

pub fn reset() void {
    flag.store(0, .release);
}

/// Install platform handler. POSIX: SIGINT/SIGTERM -> flag + self-pipe
/// write. Windows: SetConsoleCtrlHandler -> flag. Returns an uninstaller.
/// The APPLICATION opts in; the library never calls this (§10).
pub fn install() !Uninstaller {
    switch (builtin.os.tag) {
        .windows => {
            if (SetConsoleCtrlHandler(onCtrl, windows.BOOL.fromBool(true)) == windows.BOOL.FALSE)
                return error.ConsoleCtrlHandlerFailed;
            return .{};
        },
        .freestanding, .wasi, .emscripten => {
            // No signal support: flag-only, install is a no-op (§10 non-goal).
            return .{};
        },
        else => {
            // Self-pipe, non-blocking so drain() never blocks the tick.
            if (std.c.pipe2(&pipe_fds, .{ .NONBLOCK = true }) != 0) {
                pipe_fds = .{ -1, -1 }; // degrade: flag-only, still correct
            }
            const act = std.posix.Sigaction{
                .handler = .{ .handler = onSignal },
                .mask = std.posix.empty_sigset,
                .flags = 0,
            };
            try std.posix.sigaction(std.posix.SIG.INT, &act, null);
            try std.posix.sigaction(std.posix.SIG.TERM, &act, null);
            return .{};
        },
    }
}

pub const Uninstaller = struct {
    pub fn deinit(self: Uninstaller) void {
        _ = self;
        switch (builtin.os.tag) {
            .windows => {
                _ = SetConsoleCtrlHandler(onCtrl, windows.BOOL.fromBool(false));
            },
            else => {
                const act = std.posix.Sigaction{
                    .handler = .{ .handler = std.posix.SIG.SIG_DFL },
                    .mask = std.posix.empty_sigset,
                    .flags = 0,
                };
                std.posix.sigaction(std.posix.SIG.INT, &act, null) catch {};
                std.posix.sigaction(std.posix.SIG.TERM, &act, null) catch {};
                if (pipe_fds[0] >= 0) {
                    _ = std.c.close(pipe_fds[0]);
                    _ = std.c.close(pipe_fds[1]);
                    pipe_fds = .{ -1, -1 };
                }
            },
        }
        reset();
    }
};

const windows = std.os.windows;

extern "kernel32" fn SetConsoleCtrlHandler(
    handler: ?*const fn (ctrl_type: windows.DWORD) callconv(.winapi) windows.BOOL,
    add: windows.BOOL,
) windows.BOOL;

fn onCtrl(ctrl_type: windows.DWORD) callconv(.winapi) windows.BOOL {
    _ = ctrl_type;
    // Runs on its own thread -- safe to set the flag, nothing else (§3.5).
    flag.store(1, .release);
    return windows.BOOL.fromBool(true); // handled: no default termination
}

fn onSignal(sig: c_int) callconv(.c) void {
    // Async-signal-safe ONLY: one store + one write() (§3.5).
    flag.store(1, .release);
    if (pipe_fds[1] >= 0) {
        const byte = [1]u8{'i'};
        _ = std.c.write(pipe_fds[1], &byte, 1);
    }
    _ = sig;
}

test "flag roundtrip" {
    reset();
    try std.testing.expect(!interrupted());
    _setForTest();
    try std.testing.expect(interrupted());
    reset();
}

test "drain without install is a no-op" {
    drain(); // must not crash or block
}
