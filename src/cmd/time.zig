//! cmd/time.zig is the front end of `zigswiss time`.

const std = @import("std");
const clap = @import("clap");
const zigswiss = @import("zigswiss");
const cli = @import("../cli.zig");

const params = clap.parseParamsComptime(
    \\-h, --help         Display this help and exit.
    \\-m, --mode <MODE>  now (default), fromepoch, toepoch
    \\<VALUE>            Epoch seconds for fromepoch, or a timestamp such as 2026-01-31T12:00:00Z for toepoch.
    \\
);

const parsers = .{
    .MODE = clap.parsers.enumeration(zigswiss.time.Mode),
    .VALUE = clap.parsers.string,
};

pub fn run(ctx: *cli.Context) !void {
    var res = try cli.parse(ctx, &params, parsers);
    defer res.deinit();
    if (res.args.help != 0) return cli.printHelp(ctx, "time [options] [VALUE]", &params);

    const mode = res.args.mode orelse .now;
    try zigswiss.time.run(ctx.io, ctx.out, mode, res.positionals[0]);
}
