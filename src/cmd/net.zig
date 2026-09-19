//! cmd/net.zig is the front end of `zigswiss net`. It shows positional
//! arguments of two different types: a string host followed by numeric ports.

const std = @import("std");
const clap = @import("clap");
const zigswiss = @import("zigswiss");
const cli = @import("../cli.zig");

const params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\<HOST>      DNS name or IP address.
    \\<PORT>...   One or more TCP ports to check.
    \\
);

const parsers = .{
    .HOST = clap.parsers.string,
    // u16 is exactly the range of a TCP port, so 70000 is rejected for free.
    .PORT = clap.parsers.int(u16, 10),
};

pub fn run(ctx: *cli.Context) !void {
    var res = try cli.parse(ctx, &params, parsers);
    defer res.deinit();
    if (res.args.help != 0) return cli.printHelp(ctx, "net HOST PORT...", &params);

    // Positionals are a tuple: index 0 is `?[]const u8`, index 1 is `[]const u16`.
    const host = res.positionals[0] orelse return error.MissingHost;
    const ports = res.positionals[1];
    try zigswiss.net.run(ctx.io, ctx.out, host, ports);
}
