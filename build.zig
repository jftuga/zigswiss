// build.zig is the build script for zigswiss. It is ordinary Zig code that the
// `zig build` command compiles and runs. It does not build anything directly;
// instead it describes a graph of steps (compile, install, run, test) and the
// build runner executes whichever steps were requested on the command line.
// See UNDERSTANDING_BUILD_ZIG.md for a full walkthrough.

const std = @import("std");

pub fn build(b: *std.Build) void {
    // These two lines add the standard `-Dtarget=...` and `-Doptimize=...`
    // command line options. With no options given, the target is the machine
    // you are building on and the optimize mode is Debug.
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // A third-party package. The name "clap" must match the key used in the
    // `.dependencies` table of build.zig.zon. The package was added with:
    //   zig fetch --save https://github.com/Hejsil/zig-clap/archive/refs/tags/0.12.0.tar.gz
    const clap_dep = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });
    // A package can expose several modules. zig-clap exposes one, also named "clap".
    const clap_mod = clap_dep.module("clap");

    // Build options are how build.zig hands compile-time values to the
    // program. This generates a small module; main.zig reads the value with
    // `@import("build_options").version`. The version itself is read from
    // build.zig.zon so that it is written down in exactly one place. The
    // manifest has no field for a home page, so the repo URL is declared here.
    const zon = @import("build.zig.zon");
    const repo_url = "https://github.com/jftuga/zigswiss";
    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);
    options.addOption([]const u8, "repo_url", repo_url);

    // Our own library module. It contains the reusable logic for every
    // subcommand and knows nothing about command line parsing.
    const lib_mod = b.addModule("zigswiss", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The executable. Its root module is src/main.zig. The `.imports` list
    // decides which names work with `@import("...")` inside that module.
    const exe = b.addExecutable(.{
        .name = "zigswiss",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigswiss", .module = lib_mod },
                .{ .name = "clap", .module = clap_mod },
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });

    // Copy the compiled executable to zig-out/bin/ when `zig build` runs.
    b.installArtifact(exe);

    // `zig build run -- hash --algo md5 file.txt`
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run zigswiss (pass arguments after --)");
    run_step.dependOn(&run_cmd.step);

    // `zig build test` compiles a special executable that runs every `test`
    // block reachable from src/root.zig.
    const lib_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);
}
