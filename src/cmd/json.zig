//! cmd/json.zig is the front end of `zigswiss json`.

const std = @import("std");
const clap = @import("clap");
const zigswiss = @import("zigswiss");
const cli = @import("../cli.zig");

const params = clap.parseParamsComptime(
    \\-h, --help          Display this help and exit.
    \\-m, --mode <MODE>   pretty (default), compact, validate, query
    \\-q, --query <PATH>  Dot path such as "servers.0.name". Implies --mode query.
    \\<FILE>              Input file. Use "-" or no file for stdin.
    \\
);

const parsers = .{
    .MODE = clap.parsers.enumeration(zigswiss.json.Mode),
    .PATH = clap.parsers.string,
    .FILE = clap.parsers.string,
};

pub fn run(ctx: *cli.Context) !void {
    var res = try cli.parse(ctx, &params, parsers);
    defer res.deinit();
    if (res.args.help != 0) return cli.printHelp(ctx, "json [options] [FILE]", &params);

    const default_mode: zigswiss.json.Mode = if (res.args.query != null) .query else .pretty;
    const mode = res.args.mode orelse default_mode;
    const path = res.positionals[0] orelse zigswiss.input.stdin_path;

    const text = try zigswiss.input.readAll(ctx.io, ctx.gpa, path);
    defer ctx.gpa.free(text);

    const result = try zigswiss.json.run(ctx.gpa, text, mode, res.args.query);
    defer ctx.gpa.free(result);
    try ctx.out.writeAll(result);
}
