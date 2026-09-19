# Understanding build.zig

A walkthrough of zigswiss's [build.zig](build.zig) and
[build.zig.zon](build.zig.zon), written for someone who has not used the Zig
build system before. Back to the [README](README.md).

Zig has no separate build language. `build.zig` is a Zig program, and
`zig build` compiles and runs it. The important idea is that the `build`
function does not build anything itself. It **describes a graph of steps**, and
once it returns, the build runner executes the steps that were asked for, in
parallel where possible, skipping any whose inputs are unchanged.

```zig
pub fn build(b: *std.Build) void {
```

`b` is the builder. Every call on it adds a node to the graph or declares a
command-line option.

## 1. Standard options

```zig
const target = b.standardTargetOptions(.{});
const optimize = b.standardOptimizeOption(.{});
```

These two lines are what make `-Dtarget=x86_64-linux` and
`-Doptimize=ReleaseSafe` work. With no flags, the target is the machine you are
on and the mode is `Debug`. The four modes are:

| Mode | Optimized | Safety checks (bounds, overflow, `unreachable`) |
|---|---|---|
| `Debug` | no | yes, plus leak detection in the default allocator |
| `ReleaseSafe` | yes | yes |
| `ReleaseFast` | yes | no |
| `ReleaseSmall` | for size | no |

## 2. The third-party dependency

```zig
const clap_dep = b.dependency("clap", .{ .target = target, .optimize = optimize });
const clap_mod = clap_dep.module("clap");
```

`b.dependency("clap", ...)` looks up the key `clap` in the `.dependencies`
table of `build.zig.zon`. That entry was not written by hand. It was created by:

```bash
zig fetch --save https://github.com/Hejsil/zig-clap/archive/refs/tags/0.12.0.tar.gz
```

which downloads the package, computes its content hash, and writes both the
URL and the hash into `build.zig.zon`. The hash is the source of truth: if the
URL ever serves different bytes, the build fails instead of silently using
them. There is no lock file and no central registry; any URL to a tarball or
git repository works.

A package can export several modules, so the second line picks the one named
`clap`. That name comes from zig-clap's own `build.zig`
(`b.addModule("clap", ...)`), and is not necessarily the same as the
dependency key.

Before adding a dependency, check that it supports your Zig version. For this
project, zig-clap's `master` branch already required 0.17-dev, so the `0.12.0`
tag, whose release notes name Zig 0.16.0, was pinned instead.

## 3. Build options: passing values into the program

```zig
const zon = @import("build.zig.zon");
const repo_url = "https://github.com/jftuga/zigswiss";
const options = b.addOptions();
options.addOption([]const u8, "version", zon.version);
options.addOption([]const u8, "repo_url", repo_url);
```

`b.addOptions()` generates a tiny Zig source file containing
`pub const version = "0.1.0";` and `pub const repo_url = "...";`, and exposes
it as a module. `src/main.zig` reads them with
`@import("build_options").version` and `.repo_url`. This is the standard way
to get compile-time values such as versions, feature flags or git hashes into
a program. Importing `build.zig.zon` keeps the version number in a single
place. The manifest has no field for a home page, so the URL is an ordinary
constant declared next to it.

## 4. Modules

```zig
const lib_mod = b.addModule("zigswiss", .{
    .root_source_file = b.path("src/root.zig"),
    .target = target,
    .optimize = optimize,
});
```

A module is a root source file plus everything it reaches through relative
`@import("file.zig")` calls, together with compile settings. There are two
ways to make one:

- `b.addModule(name, ...)` creates a module and also **exports** it, so that
  other packages that depend on zigswiss could import it by that name.
- `b.createModule(...)` creates a private one. It is used for the executable's
  root module below.

## 5. The executable and its imports

```zig
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
```

The `.imports` list is the key to understanding `@import`. It is the complete
list of module names that code in this module may import. If a name is not
listed here, `@import("that_name")` is a compile error, even if the package
was downloaded. The `.name` is what you write in source code and may differ
from the module's original name, which is how naming collisions are solved.

Note that the library module has no imports list at all. It can only use
`std`, which is the point: the library cannot accidentally depend on the
command-line parser.

This gives four kinds of `@import` in the project:

| Form | Example | Resolved by |
|---|---|---|
| Standard library | `@import("std")` | always available |
| Compiler-provided | `@import("builtin")` | always available; describes the target |
| Named module | `@import("clap")`, `@import("zigswiss")`, `@import("build_options")` | the `.imports` list in `build.zig` |
| Relative file | `@import("../cli.zig")`, `@import("lib/hash.zig")` | the file system, within the same module |

## 6. Install, run and test steps

```zig
b.installArtifact(exe);
```

Adds the executable to the default `install` step, which is what plain
`zig build` runs. The output goes to `zig-out/bin/`; `-p some/dir` (or
`--prefix`) changes `zig-out` to something else, which is how `make cross`
builds several targets side by side.

```zig
const run_cmd = b.addRunArtifact(exe);
run_cmd.step.dependOn(b.getInstallStep());
if (b.args) |args| run_cmd.addArgs(args);
const run_step = b.step("run", "Run zigswiss (pass arguments after --)");
run_step.dependOn(&run_cmd.step);
```

`b.step(name, description)` creates a named, user-visible step: this is what
makes `zig build run` exist. A named step does nothing by itself; it only has
dependencies. Here `run` depends on a step that executes the binary, which in
turn depends on the install step. `b.args` holds whatever follows `--` on the
command line.

```zig
const lib_tests = b.addTest(.{ .root_module = lib_mod });
const run_lib_tests = b.addRunArtifact(lib_tests);
const test_step = b.step("test", "Run unit tests");
test_step.dependOn(&run_lib_tests.step);
```

`b.addTest` compiles a module into a special executable whose `main` runs
every `test "..." { }` block. Tests live next to the code they test, in the
same file. Zig only compiles what is referenced, so `src/root.zig` contains
`std.testing.refAllDecls(@This())` to make sure every library file, and
therefore every test, is reached.

The resulting graph:

```
zig build        -> install -> compile zigswiss -> (clap, zigswiss lib, build_options)
zig build run    -> run zigswiss -> install -> ...
zig build test   -> run tests -> compile test binary -> zigswiss lib
```

`zig build --help` lists every step and every `-D` option that a `build.zig`
defines, for any project. It is the first thing to run in an unfamiliar Zig
repository.

## build.zig.zon

The manifest is written in ZON (Zig Object Notation), which is Zig's
anonymous struct literal syntax used as a data format. The fields:

- `.name` and `.version`: the package identity.
- `.fingerprint`: generated once by `zig init`. Do not edit it.
- `.minimum_zig_version`: documentation of the supported compiler.
- `.dependencies`: managed by `zig fetch --save`.
- `.paths`: which files belong to the package when someone else depends on it.
