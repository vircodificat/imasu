const std = @import("std");

pub fn build(b: *std.Build) void {
    // executable step
    const exe = b.addExecutable(.{
        .name = "imasu64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/imasu.zig"),
            .target = b.standardTargetOptions(.{}),
            .optimize = b.standardOptimizeOption(.{}),
            .single_threaded = false,
        }),
    });

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the emulator");
    run_step.dependOn(&run_cmd.step);
}
