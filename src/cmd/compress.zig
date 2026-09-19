//! cmd/compress.zig is the front end of `zigswiss compress`. One command handles
//! both directions; the --decompress flag switches it, in the style of gzip -d.

const std = @import("std");
const clap = @import("clap");
const zigswiss = @import("zigswiss");
const cli = @import("../cli.zig");

const params = clap.parseParamsComptime(
    \\-h, --help             Display this help and exit.
    \\-d, --decompress       Decompress instead of compress.
    \\-f, --format <FORMAT>  gzip (default), zlib, zstd, xz. zstd and xz can only be decompressed.
    \\-o, --output <PATH>    Write the result to a file instead of stdout.
    \\<FILE>                 Input file. Use "-" or no file for stdin.
    \\
);

const parsers = .{
    .FORMAT = clap.parsers.enumeration(zigswiss.compress.Format),
    .PATH = clap.parsers.string,
    .FILE = clap.parsers.string,
};

pub fn run(ctx: *cli.Context) !void {
    var res = try cli.parse(ctx, &params, parsers);
    defer res.deinit();
    if (res.args.help != 0) return cli.printHelp(ctx, "compress [options] [FILE]", &params);

    const format = res.args.format orelse .gzip;
    const path = res.positionals[0] orelse zigswiss.input.stdin_path;

    const data = try zigswiss.input.readAll(ctx.io, ctx.gpa, path);
    defer ctx.gpa.free(data);

    // `if` is an expression in Zig, so it can pick which function's result to use.
    const result = if (res.args.decompress != 0)
        try zigswiss.compress.decompress(ctx.gpa, format, data)
    else
        try zigswiss.compress.compress(ctx.gpa, format, data);
    defer ctx.gpa.free(result);

    try cli.writeOutput(ctx, res.args.output, result);
}
