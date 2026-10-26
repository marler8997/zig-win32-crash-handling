const builtin = @import("builtin");
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{ .os_tag = .windows },
    });
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode (default: ReleaseSafe)",
    ) orelse std.builtin.OptimizeMode.ReleaseSafe;
    const exe = b.addExecutable(.{
        .name = "crashdemo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            // Linking libc brings in the mingw CRT and the exception filter it installs.
            .link_libc = true,
            .imports = &.{
                .{ .name = "win32", .module = b.dependency("win32", .{}).module("win32") },
            },
        }),
    });
    exe.subsystem = if (builtin.zig_version.minor >= 17) .windows else .Windows;
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Run crashdemo").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    b.step("test", "Run the tests").dependOn(&b.addRunArtifact(tests).step);
}
