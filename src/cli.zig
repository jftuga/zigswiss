//! cli.zig holds what every subcommand's command-line front end shares: the
//! `Context` handed to each command, a wrapper around the zig-clap argument
//! parser, and helpers for printing help and writing results. It belongs to
//! the executable module, not to the "zigswiss" library module.

const std = @import("std");
// "clap" is not a file path. It is a module name that build.zig wired up from
// the third-party zig-clap package listed in build.zig.zon.
const clap = @import("clap");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Everything a subcommand needs from the outside world. Zig has no global
/// state for I/O or memory, so `main` builds this once and passes it down.
pub const Context = struct {
    /// The I/O implementation: files, network, clocks, randomness, tasks.
    io: Io,
    /// General purpose allocator. In Debug builds it reports leaks on exit.
    gpa: Allocator,
    /// Buffered stdout. `main` flushes it after the command returns.
    out: *Io.Writer,
    /// The remaining command-line arguments, positioned after the subcommand.
    args: *std.process.Args.Iterator,
    /// The process environment variables.
    environ_map: *std.process.Environ.Map,
};

/// Parses the rest of the command line for one subcommand.
///
/// `params` and `parsers` are `comptime` because zig-clap generates the result
/// type from them: a struct with one field per flag, typed according to the
/// parser chosen for it. That is why `res.args.length` can be a `?usize` for
/// one command while `res.args.algo` is a `?Algorithm` for another.
pub fn parse(ctx: *Context, comptime params: []const clap.Param(clap.Help), comptime parsers: anytype) !clap.ResultEx(clap.Help, params, parsers) {
    var diagnostic: clap.Diagnostic = .{};
    return clap.parseEx(clap.Help, params, parsers, ctx.args, .{
        .diagnostic = &diagnostic,
        .allocator = ctx.gpa,
    }) catch |err| {
        // Explain what was wrong with the arguments, then pass the error on.
        reportParseError(ctx.io, diagnostic, err);
        return err;
    };
}

/// Writes zig-clap's explanation of a parse error to stderr.
///
/// zig-clap offers `diagnostic.reportToFile`, but it writes positionally from
/// offset 0 (see the stdout comment in main.zig), which clobbers a log file
/// when stderr is redirected. So we hand it our own streaming writer instead.
pub fn reportParseError(io: Io, diagnostic: clap.Diagnostic, err: anyerror) void {
    var buffer: [1024]u8 = undefined;
    var stderr_writer = Io.File.stderr().writerStreaming(io, &buffer);
    // If stderr itself is broken there is nowhere left to complain to.
    diagnostic.report(&stderr_writer.interface, err) catch return;
    stderr_writer.interface.flush() catch return;
}

/// Prints a usage line followed by the flag descriptions.
pub fn printHelp(ctx: *Context, usage: []const u8, params: []const clap.Param(clap.Help)) !void {
    try ctx.out.print("Usage: zigswiss {s}\n\n", .{usage});
    try clap.help(ctx.out, clap.Help, params, .{
        .description_on_new_line = false,
        .spacing_between_parameters = 0,
    });
}

/// Writes `bytes` to the file at `path`, or to stdout when `path` is null.
pub fn writeOutput(ctx: *Context, path: ?[]const u8, bytes: []const u8) !void {
    if (path) |file_path| {
        try Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = file_path, .data = bytes });
    } else {
        try ctx.out.writeAll(bytes);
    }
}
