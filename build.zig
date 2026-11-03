const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zprogress", .{
        .root_source_file = b.path("src/zprogress.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "zprogress",
        .root_module = mod,
    });
    b.installArtifact(lib);

    const test_step = b.step("test", "Run tests");
    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);

    // Comptime-failure testing (§7): known-bad templates compiled as
    // separate objects, each expected to FAIL. std.testing has no
    // expectCompileError, so negative cases are build steps asserting
    // a non-zero zig exit code.
    const negative_step = b.step("negative", "Compile known-bad templates, expect failure");
    test_step.dependOn(negative_step);
    const bad_templates = [_][]const u8{
        "unknown_field", "bad_width", "unknown_color", "unterminated",
    };
    for (bad_templates) |name| {
        var argv = std.ArrayListUnmanaged([]const u8){ .items = &.{}, .capacity = 0, .pointer_stability = .{} };
        defer argv.deinit(b.allocator);
        argv.appendSlice(b.allocator, &.{
            b.graph.zig_exe,
            "build-obj",
            "-fno-emit-bin",
            "--dep",
            "zprogress",
            b.fmt("-Mroot=tests/comptime_negative/{s}.zig", .{name}),
            "-Mzprogress=src/zprogress.zig",
        }) catch @panic("OOM");
        const run_bad = b.addSystemCommand(argv.items);
        run_bad.expectExitCode(1);
        negative_step.dependOn(&run_bad.step);
    }

    // WASM/freestanding smoke (§9): sync mode, no threads, no signals.
    const wasm = b.addExecutable(.{
        .name = "wasm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/wasm.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = optimize,
            .imports = &.{.{ .name = "zprogress", .module = mod }},
        }),
    });
    wasm.entry = .disabled;
    const wasm_step = b.step("wasm", "Build the WASM/freestanding smoke example");
    wasm_step.dependOn(&wasm.step);

    const examples = [_][]const u8{ "simple_bar", "multi_tree" };
    for (examples) |name| {
        const ex = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zprogress", .module = mod }},
            }),
        });
        const run_ex = b.addRunArtifact(ex);
        const step = b.step(name, b.fmt("Run {s} example", .{name}));
        step.dependOn(&run_ex.step);
    }

    // First real consumer (§12 R2): piped to a real usage site.
    const consumer = b.addExecutable(.{
        .name = "loaders",
        .root_module = b.createModule(.{
            .root_source_file = b.path("consumer/loaders.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zprogress", .module = mod }},
        }),
    });
    const run_consumer = b.addRunArtifact(consumer);
    const consumer_step = b.step("loaders", "Run the loaders.zig consumer");
    consumer_step.dependOn(&run_consumer.step);
}
