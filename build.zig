const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main module for projects to use.
    const io_module = b.addModule("io", .{ .root_source_file = b.path("src/io.zig") });

    // Library unit tests.
    const main_tests = b.addTest(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_main_tests = b.addRunArtifact(main_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);

    // sample web server.
    const server_exe = b.addExecutable(.{
        .name = "sample_web_server",
        .root_source_file = b.path("src/sample_web_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    server_exe.root_module.addImport("io", io_module);

    const run_server = b.addRunArtifact(server_exe);
    const server_step = b.step("sample_web_server", "Run sample web server.");
    server_step.dependOn(&run_server.step);
}
