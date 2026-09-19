//! cmd/fetch.zig is the front end of `zigswiss fetch`, a minimal curl. It prints
//! the response body, and with --include also the status line and headers.

const std = @import("std");
const clap = @import("clap");
const zigswiss = @import("zigswiss");
const cli = @import("../cli.zig");

const params = clap.parseParamsComptime(
    \\-h, --help             Display this help and exit.
    \\-X, --method <METHOD>  GET (default), HEAD, POST, PUT, DELETE, PATCH, OPTIONS
    \\-d, --data <BODY>      Request body. Implies POST unless --method is given.
    \\-i, --include          Print the status line and response headers first.
    \\-o, --output <PATH>    Write the body to a file instead of stdout.
    \\<URL>                  The http:// or https:// URL to request.
    \\
);

const parsers = .{
    // The enum comes straight from the standard library.
    .METHOD = clap.parsers.enumeration(std.http.Method),
    .BODY = clap.parsers.string,
    .PATH = clap.parsers.string,
    .URL = clap.parsers.string,
};

pub fn run(ctx: *cli.Context) !void {
    var res = try cli.parse(ctx, &params, parsers);
    defer res.deinit();
    if (res.args.help != 0) return cli.printHelp(ctx, "fetch [options] URL", &params);

    const url = res.positionals[0] orelse return error.MissingUrl;
    const default_method: std.http.Method = if (res.args.data != null) .POST else .GET;

    var response = try zigswiss.fetch.fetch(ctx.io, ctx.gpa, url, .{
        .method = res.args.method orelse default_method,
        .body = res.args.data,
    });
    defer response.deinit(ctx.gpa);

    if (res.args.include != 0) {
        // `@intFromEnum` gives the numeric value behind an enum, here 200, 404...
        // `phrase()` returns an optional because not every code has a name.
        try ctx.out.print("{d} {s}\n", .{ @intFromEnum(response.status), response.status.phrase() orelse "" });
        try ctx.out.print("{s}\n", .{response.headers});
    }
    try cli.writeOutput(ctx, res.args.output, response.body);
}
