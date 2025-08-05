const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Disable AVX since some users have CPUs which don't support it (Pentium G4560).
    var target_patch = target;
    target_patch.result.cpu.model = std.Target.Cpu.Model.baseline(
        target.result.cpu.arch,
        target.result.os,
    );

    const strip = b.option(bool, "strip", "strip debug information");
    const unwind_tables: ?std.builtin.UnwindTables = if (optimize != .Debug) .none else null;
    const exe = b.addExecutable(.{
        .name = "dtkit-patch",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target_patch,
            .optimize = optimize,
            .single_threaded = true,
            .unwind_tables = unwind_tables,
            .strip = strip,
        }),
    });

    const version = b.option([]const u8, "version", "semvar version string");
    const options = b.addOptions();
    options.addOption(?[]const u8, "version", version);
    exe.root_module.addOptions("config", options);

    if (target.result.os.tag == .windows) {
        exe.linkSystemLibrary("user32");
        exe.linkSystemLibrary("advapi32");
        exe.linkSystemLibrary("shell32");
    }

    exe.bundle_ubsan_rt = if (strip) |strip_| !strip_ else null;

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
