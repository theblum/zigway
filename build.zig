const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe_options = b.addOptions();
    exe_options.addOption([:0]const u8, "program_name", if (mode == .Debug) "zigway_debug" else "zigway");

    const exe = b.addExecutable("zigway", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.addOptions("build_options", exe_options);
    exe.addCSourceFile("src/c/xdg-shell.c", &[_][]const u8{
        "-Wall",
        "-Wextra",
        "-Werror",
    });
    exe.addIncludeDir("src/c");
    exe.linkSystemLibrary("wayland-client");
    exe.linkLibC();
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
