//! cmd/info.zig is the front end of `zigswiss info`.

const std = @import("std");
const clap = @import("clap");
const zigswiss = @import("zigswiss");
const cli = @import("../cli.zig");

const params = clap.parseParamsComptime(
    \\-h, --help             Display this help and exit.
    \\-f, --format <FORMAT>  text (default), json
    \\-e, --env              Include the environment variables.
    \\
);

const parsers = .{
    .FORMAT = clap.parsers.enumeration(zigswiss.info.Format),
};

pub fn run(ctx: *cli.Context) !void {
    var res = try cli.parse(ctx, &params, parsers);
    defer res.deinit();
    if (res.args.help != 0) return cli.printHelp(ctx, "info [options]", &params);

    const format = res.args.format orelse .text;
    const environ = if (res.args.env != 0) ctx.environ_map else null;
    try zigswiss.info.run(ctx.io, ctx.gpa, ctx.out, format, environ);
}
