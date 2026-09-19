//! cmd/crypt.zig is the front end of `zigswiss encrypt` and `zigswiss decrypt`.
//! The password comes from --password or, so that it stays out of the shell
//! history and the process list, from the ZIGSWISS_PASSWORD environment variable.

const std = @import("std");
const clap = @import("clap");
const zigswiss = @import("zigswiss");
const cli = @import("../cli.zig");

const password_variable = "ZIGSWISS_PASSWORD";

const params = clap.parseParamsComptime(
    \\-h, --help                 Display this help and exit.
    \\-p, --password <PASSWORD>  Password. Defaults to the ZIGSWISS_PASSWORD environment variable.
    \\-o, --output <PATH>        Write the result to a file instead of stdout.
    \\<FILE>                     Input file. Use "-" or no file for stdin.
    \\
);

const parsers = .{
    .PASSWORD = clap.parsers.string,
    .PATH = clap.parsers.string,
    .FILE = clap.parsers.string,
};

const Direction = enum { encrypt, decrypt };

pub fn runEncrypt(ctx: *cli.Context) !void {
    return runCrypt(ctx, .encrypt);
}

pub fn runDecrypt(ctx: *cli.Context) !void {
    return runCrypt(ctx, .decrypt);
}

fn runCrypt(ctx: *cli.Context, direction: Direction) !void {
    var res = try cli.parse(ctx, &params, parsers);
    defer res.deinit();
    if (res.args.help != 0) {
        const usage = switch (direction) {
            .encrypt => "encrypt [options] [FILE]",
            .decrypt => "decrypt [options] [FILE]",
        };
        return cli.printHelp(ctx, usage, &params);
    }

    // `orelse` chains: first the flag, then the environment, then give up.
    const password = res.args.password orelse
        ctx.environ_map.get(password_variable) orelse
        return error.MissingPassword;
    const path = res.positionals[0] orelse zigswiss.input.stdin_path;

    const data = try zigswiss.input.readAll(ctx.io, ctx.gpa, path);
    defer ctx.gpa.free(data);

    const result = switch (direction) {
        .encrypt => try zigswiss.crypt.encrypt(ctx.gpa, ctx.io, password, data),
        .decrypt => try zigswiss.crypt.decrypt(ctx.gpa, password, data),
    };
    defer ctx.gpa.free(result);

    try cli.writeOutput(ctx, res.args.output, result);
}
