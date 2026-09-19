//! cmd/transform.zig is the front end of `zigswiss transform`.

const std = @import("std");
const clap = @import("clap");
const zigswiss = @import("zigswiss");
const cli = @import("../cli.zig");

const params = clap.parseParamsComptime(
    \\-h, --help            Display this help and exit.
    \\-m, --mode <MODE>     upper, lower, reverse, sort, uniq, count, replace, freq
    \\    --find <TEXT>     Text to search for (mode replace).
    \\    --replace <TEXT>  Replacement text (mode replace, default empty).
    \\<FILE>                Input file. Use "-" or no file for stdin.
    \\
);

const parsers = .{
    .MODE = clap.parsers.enumeration(zigswiss.transform.Mode),
    .TEXT = clap.parsers.string,
    .FILE = clap.parsers.string,
};

pub fn run(ctx: *cli.Context) !void {
    var res = try cli.parse(ctx, &params, parsers);
    defer res.deinit();
    if (res.args.help != 0) return cli.printHelp(ctx, "transform --mode MODE [options] [FILE]", &params);

    const mode = res.args.mode orelse return error.MissingMode;
    const path = res.positionals[0] orelse zigswiss.input.stdin_path;

    const text = try zigswiss.input.readAll(ctx.io, ctx.gpa, path);
    defer ctx.gpa.free(text);

    const result = try zigswiss.transform.run(ctx.gpa, text, .{
        .mode = mode,
        .find = res.args.find,
        .replacement = res.args.replace orelse "",
    });
    defer ctx.gpa.free(result);
    try ctx.out.writeAll(result);
}
