//! cmd/codec.zig is the front end of `zigswiss encode` and `zigswiss decode`. The
//! two commands take the same flags, so they share one implementation that is
//! told which direction to run.

const std = @import("std");
const clap = @import("clap");
const zigswiss = @import("zigswiss");
const cli = @import("../cli.zig");

const params = clap.parseParamsComptime(
    \\-h, --help             Display this help and exit.
    \\-f, --format <FORMAT>  base64 (default), base64url, hex, url
    \\-o, --output <PATH>    Write the result to a file instead of stdout.
    \\<FILE>                 Input file. Use "-" or no file for stdin.
    \\
);

const parsers = .{
    .FORMAT = clap.parsers.enumeration(zigswiss.codec.Format),
    .PATH = clap.parsers.string,
    .FILE = clap.parsers.string,
};

const Direction = enum { encode, decode };

pub fn runEncode(ctx: *cli.Context) !void {
    return runCodec(ctx, .encode);
}

pub fn runDecode(ctx: *cli.Context) !void {
    return runCodec(ctx, .decode);
}

fn runCodec(ctx: *cli.Context, direction: Direction) !void {
    var res = try cli.parse(ctx, &params, parsers);
    defer res.deinit();
    if (res.args.help != 0) {
        // `@tagName(direction)` is "encode" or "decode". `++` only works on
        // compile-time values, so the usage line is built with a switch.
        const usage = switch (direction) {
            .encode => "encode [options] [FILE]",
            .decode => "decode [options] [FILE]",
        };
        return cli.printHelp(ctx, usage, &params);
    }

    const format = res.args.format orelse .base64;
    const path = res.positionals[0] orelse zigswiss.input.stdin_path;

    const data = try zigswiss.input.readAll(ctx.io, ctx.gpa, path);
    defer ctx.gpa.free(data);

    const result = switch (direction) {
        .encode => try zigswiss.codec.encode(ctx.gpa, format, data),
        .decode => try zigswiss.codec.decode(ctx.gpa, format, data),
    };
    defer ctx.gpa.free(result);

    try cli.writeOutput(ctx, res.args.output, result);
    // Encoded text gets a trailing newline. Decoded bytes are written as-is.
    if (direction == .encode and res.args.output == null) try ctx.out.writeByte('\n');
}
