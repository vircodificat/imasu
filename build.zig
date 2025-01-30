const std = @import("std");

pub fn build(b: *std.Build) void {
    // executable step
    const exe = b.addExecutable(.{
        .name = "imasu64",
        .root_source_file = b.path("src/imasu.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .single_threaded = false,
    });

    // compile devicetree blob to embed in emulator
    const devicetree_cmd = b.addSystemCommand(&.{"dtc"});
    devicetree_cmd.addFileArg(b.path("src/devicetree/imasu64.dts"));
    devicetree_cmd.addArgs(&.{ "-O", "dtb", "-o" });
    devicetree_cmd.addFileArg(b.path("src/devicetree/imasu64.dtb"));
    exe.step.dependOn(&devicetree_cmd.step);

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the emulator");
    run_step.dependOn(&run_cmd.step);
}
