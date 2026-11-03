# zprogress

**Progress bars for Zig that don't redraw what you already saw.**

`zprogress` is a small, dependency-free progress library for terminal programs. Templates are validated at compile time, the hot path allocates nothing after setup, and every frame is diffed line-by-line so only the parts that actually changed get sent to the terminal.

```
⠹ [████████████████░░░░░░░░░░░░░░░░░░░░░░] 42% loading shaders
```

- **Compile-time templates.** `{bar:40.cyan}` isn't parsed at runtime — a bad field, width, or color name is a compile error, not a broken frame at 3am.
- **Zero-alloc steady state.** Frames render into a manager-owned buffer. Two allocations happen once, at init, and never again.
- **Only the diffs.** Frame N is compared to frame N−1 and only changed lines are emitted. Cursor-down over a static line, rewrite a moving one.
- **Lock-free progress updates.** Workers call `node.setPos()`; an atomic CAS makes progress monotonic and needs no lock. The manager samples on its own thread.
- **Trees, not just bars.** Multi-task work collapses into a tidy summary as subtasks finish, instead of scrolling rows of completed bars off your screen.
- **Degrades properly.** No TTY → one plain line per task. `NO_COLOR` or `TERM=dumb` → colors stripped, layout intact.

Requires **Zig 0.17.0**. No dependencies.

---

## Install

```sh
zig fetch --save git+https://github.com/coffeetocoffee/zprogress#v1.0.0
```

Then wire it into your executable:

```zig
// build.zig
const zprogress = b.dependency("zprogress", .{
    .target = target,
    .optimize = optimize,
}).module("zprogress");

exe.root_module.addImport("zprogress", zprogress);
```

## Quick start

```zig
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
        .terminal_file = std.Io.File.stdout(), // enables TTY detection
    });
    defer bar.deinit();

    for (0..101) |i| {
        bar.setPos(@intCast(i));
        _ = bar.tick();
        try io.sleep(.{ .nanoseconds = 30 * std.time.ns_per_ms }, .awake);
    }
    bar.finish(); // final frame at 100%, then restore the terminal
}
```

`Bar` is a thin wrapper over `Manager` with one node mounted. `tick()` returns `.ok` or `.interrupted`, so a signal can break your loop without leaving the terminal in a weird state.

## Templates

Write a template, pass it through `comptime Style.parse(...)`, and you have a renderer with no runtime parsing:

```zig
const style = comptime zprogress.Style.parse("{spinner} [{bar:30.yellow}] {percent} {elapsed} {msg}");
```

| Field | Renders | Default width |
| --- | --- | --- |
| `{bar}` | `[####----]` ASCII bar | 20 |
| `{wide_bar}` | `[████░░░░]` block-glyph bar | 20 |
| `{spinner}` | 10-frame braille spinner, 100 ms cadence | 1 |
| `{pos}` / `{len}` | current / total units | — |
| `{percent}` | integer percentage, `50%` | — |
| `{elapsed}` | seconds since the node's first tick, `1.4s` | — |
| `{eta}` | linear extrapolation from elapsed, `2.8s` | — |
| `{speed}` | units per second, `34.2/s` | — |
| `{msg}` | the node's last `setMessage()` text | message length |

Widths are upper bounds, not guarantees: `{bar:40}` shrinks when the terminal is narrower than 40 columns plus the literals. Literals are never truncated. A width is meaningful for `bar`, `wide_bar`, and `msg`; every other field sizes itself.

Colors go after a width, or alone:

```zig
"{percent.green}"      // green percentage
"{bar:40.cyan}"        // cyan bar
"{bar:40.cyan/blue}"   // fg/bg pair (see the caveat below)
```

The palette is the eight classic ANSI names: `black`, `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`, `white`.

## Trees and worker threads

Real work is rarely one bar. Mount a root, add children, and hand each child to whatever does the work:

```zig
var mgr = try zprogress.Manager.init(io, init.gpa, out);
defer mgr.deinit();
mgr.attachTerminalFile(std.Io.File.stdout());

const root = try mgr.addTree(.{
    .label = "build",
    .style = comptime zprogress.Style.parse("[{bar:20}] {percent}"),
});
try mgr.mountBar(root);

const pkg = try root.addChild(init.gpa, .{
    .len = 42,
    .label = "pkg-a",
    .style = comptime zprogress.Style.parse("[{bar:12}] {percent}"),
});

// From a worker; no lock, no allocator, no terminal access:
pkg.setPos(pkg.getPos() + 1);

// From the manager thread, when the work is done:
mgr.finish(pkg);
_ = mgr.tick();
```

Finished children collapse to a single line — `[done] pkg-a 100% 1.2s` — and a finished root collapses to `[done] build (2 subtasks)`. Progress only ever moves forward: `setPos` ignores a smaller value, so a confused worker can't make your bar moonwalk.

## Modes

| Mode | When | Output |
| --- | --- | --- |
| `tty` | stdout is a terminal | Live, in-place redraw with cursor movement |
| `plain` | piped or redirected | One line per finished task: `build: 59/59 100%` |
| `silent` | you set it | Nothing |

Color output is suppressed when `NO_COLOR` is set or `TERM=dumb`. Layout is preserved — you lose color, not structure.

## Custom renderers

Anything with a height and a draw method can live in the same block as your bars. Mounting takes three function pointers:

```zig
try mgr.mount(.{
    .ptr = @ptrCast(&logs),
    .heightFn = heightOf,
    .drawFn = drawOf,
    .drainFn = drainOf, // optional, called before each draw
});
```

`LogLineRenderer` is a working example: a bounded append-only log that producers push to through a single-producer ring. Producers never touch the terminal; the manager drains the ring during its tick and folds the lines into the frame. `src/render/tree.zig` does the same for node trees.

## Signals

The library never installs signal handlers behind your back. You opt in:

```zig
var uninstaller = try zprogress.signal.install();
defer uninstaller.deinit();

while (working) {
    if (zprogress.signal.interrupted()) return; // deinit restores the terminal
    ...
}
```

POSIX gets `SIGINT`/`SIGTERM` plus a self-pipe, so a blocked tick wakes up. Windows gets `SetConsoleCtrlHandler` flag-only, because Windows has its own opinions about console control events. Handlers do the signal-safe minimum: one atomic store, one byte on a pipe.

## Background redraws

Prefer not to tick by hand? Start the built-in driver, which runs `std.Io.async` at a 100 ms cadence:

```zig
try mgr.startRefresh();
```

Your workers keep calling `setPos`; the refresh task takes the lock only long enough to draw.

## WASM and freestanding

Sync mode works with no OS at all — no threads, no signals, no syscalls. See `examples/wasm.zig`, which drives a `Manager` over a `FixedBufferAllocator` on `wasm32-freestanding`:

```sh
zig build wasm
```

## Build and test

| Command | What it does |
| --- | --- |
| `zig build test` | Unit tests, plus compile-failure tests for bad templates |
| `zig build simple_bar` | Single progress bar, live |
| `zig build multi_tree` | Root with two concurrent children |
| `zig build loaders` | Tree of 8 resources, async workers, collapsing rows |
| `zig build wasm` | Builds the freestanding smoke example |

The negative tests are worth a look: `tests/comptime_negative/` holds templates that must *fail* to compile — unknown field, bad width, unknown color, unterminated `{`. `zig build test` fails if any of them starts compiling.

## Status

Version 1.0.0, and honest about its edges:

- Background colors (`cyan/blue`) are parsed and validated, but only the foreground is emitted today.
- Tree shape is fixed once rendering starts — there is no node removal.
- One producer thread per `LogLineRenderer`; it's an SPSC ring.
- Eight ANSI colors, no 256-color or truecolor palettes yet.
- The spinner is time-driven, not progress-driven: it animates even if work stalls, which is either reassuring or a lie, depending on your build.

## License

Not yet specified.
