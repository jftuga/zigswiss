//! cmd/bench.zig is the front end of `zigswiss bench`.

const std = @import("std");
const clap = @import("clap");
const zigswiss = @import("zigswiss");
const cli = @import("../cli.zig");

const params = clap.parseParamsComptime(
    \\-h, --help             Display this help and exit.
    \\-n, --requests <N>     Total number of requests (default 100).
    \\-c, --concurrency <N>  Number of concurrent workers (default 10).
    \\<URL>                  The http:// or https:// URL to request.
    \\
);

const parsers = .{
    .N = clap.parsers.int(usize, 10),
    .URL = clap.parsers.string,
};

pub fn run(ctx: *cli.Context) !void {
    var res = try cli.parse(ctx, &params, parsers);
    defer res.deinit();
    if (res.args.help != 0) return cli.printHelp(ctx, "bench [options] URL", &params);

    const url = res.positionals[0] orelse return error.MissingUrl;
    try zigswiss.bench.run(ctx.io, ctx.gpa, ctx.out, .{
        .url = url,
        .requests = res.args.requests orelse 100,
        .concurrency = res.args.concurrency orelse 10,
    });
}
