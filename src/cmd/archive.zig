//! cmd/archive.zig is the front end of `zigswiss archive`.

const std = @import("std");
const clap = @import("clap");
const zigswiss = @import("zigswiss");
const cli = @import("../cli.zig");

const params = clap.parseParamsComptime(
    \\-h, --help             Display this help and exit.
    \\-m, --mode <MODE>      create, list, extract
    \\-f, --file <ARCHIVE>   The .tar.gz file to create or read.
    \\-C, --directory <DIR>  Where to extract to (default: current directory).
    \\<PATH>...              Files and directories to add (mode create).
    \\
);

const parsers = .{
    .MODE = clap.parsers.enumeration(zigswiss.archive.Mode),
    .ARCHIVE = clap.parsers.string,
    .DIR = clap.parsers.string,
    .PATH = clap.parsers.string,
};

pub fn run(ctx: *cli.Context) !void {
    var res = try cli.parse(ctx, &params, parsers);
    defer res.deinit();
    if (res.args.help != 0) return cli.printHelp(ctx, "archive --mode MODE --file ARCHIVE [options] [PATH]...", &params);

    const mode = res.args.mode orelse return error.MissingMode;
    const archive_path = res.args.file orelse return error.MissingArchiveFile;
    // The library works relative to a directory handle. The CLI uses the
    // current directory; the unit tests pass a temporary one.
    const cwd = std.Io.Dir.cwd();

    switch (mode) {
        .create => try zigswiss.archive.create(ctx.io, ctx.gpa, cwd, archive_path, res.positionals[0]),
        .list => try zigswiss.archive.list(ctx.io, ctx.gpa, cwd, archive_path, ctx.out),
        .extract => try zigswiss.archive.extract(ctx.io, ctx.gpa, cwd, archive_path, res.args.directory orelse "."),
    }
}
