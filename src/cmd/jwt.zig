//! cmd/jwt.zig is the front end of `zigswiss jwt`. The token is taken from the
//! command line or, when no argument is given, read from stdin.

const std = @import("std");
const clap = @import("clap");
const zigswiss = @import("zigswiss");
const cli = @import("../cli.zig");

const params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\<TOKEN>     The token to decode. Read from stdin when omitted.
    \\
);

const parsers = .{
    .TOKEN = clap.parsers.string,
};

pub fn run(ctx: *cli.Context) !void {
    var res = try cli.parse(ctx, &params, parsers);
    defer res.deinit();
    if (res.args.help != 0) return cli.printHelp(ctx, "jwt [TOKEN]", &params);

    const now_seconds = std.Io.Timestamp.now(ctx.io, .real).toSeconds();

    if (res.positionals[0]) |token| {
        return zigswiss.jwt.decode(ctx.gpa, token, now_seconds, ctx.out);
    }
    const token = try zigswiss.input.readAll(ctx.io, ctx.gpa, zigswiss.input.stdin_path);
    defer ctx.gpa.free(token);
    try zigswiss.jwt.decode(ctx.gpa, token, now_seconds, ctx.out);
}
