const std = @import("std");

const default_version = "0.1.0";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Version: -Dversion= override for CI, otherwise default_version
    const version = b.option([]const u8, "version", "Override version string") orelse default_version;

    // Get ghostty dependency
    const ghostty_dep = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    });

    // Build options module to pass version to source code
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    // Create root module for the executable
    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_mod.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "termscope",
        .root_module = root_mod,
    });

    // Link against libghostty-vt static library
    exe.linkLibrary(ghostty_dep.artifact("ghostty-vt-static"));

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run termscope");
    run_step.dependOn(&run_cmd.step);

    // Test step
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addOptions("build_options", options);

    const exe_unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    exe_unit_tests.linkLibrary(ghostty_dep.artifact("ghostty-vt-static"));

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
