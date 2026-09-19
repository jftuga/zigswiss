//! cmd/hash.zig is the command-line front end of `zigswiss hash`. Like every
//! file in src/cmd it does three things: declare the flags, parse them, and
//! call into the library module. The hashing itself lives in src/lib/hash.zig.

const std = @import("std");
const clap = @import("clap");
// "zigswiss" is our own library module (src/root.zig), imported by the name
// that build.zig gave it, exactly like a third-party module.
const zigswiss = @import("zigswiss");
// A relative path imports a file from the same module.
const cli = @import("../cli.zig");

// zig-clap reads this help text at compile time and turns it into the list of
// accepted flags. `\\` starts a line of a multiline string literal. A name in
// angle brackets means the flag takes a value, and `...` means "repeatable".
const params = clap.parseParamsComptime(
    \\-h, --help         Display this help and exit.
    \\-a, --algo <ALGO>  md5, sha1, sha256 (default), sha512, sha3_256, blake3, crc32
    \\    --hmac <KEY>   Compute an HMAC with this key instead of a plain hash.
    \\<FILE>...          Files to hash. Use "-" or no file for stdin.
    \\
);

// Maps each value name used above to the function that converts its text.
// `enumeration` accepts exactly the member names of the enum.
const parsers = .{
    .ALGO = clap.parsers.enumeration(zigswiss.hash.Algorithm),
    .KEY = clap.parsers.string,
    .FILE = clap.parsers.string,
};

pub fn run(ctx: *cli.Context) !void {
    var res = try cli.parse(ctx, &params, parsers);
    defer res.deinit();
    // Flags without a value are counters: how many times they were given.
    if (res.args.help != 0) return cli.printHelp(ctx, "hash [options] [FILE]...", &params);

    // Flags with a value are optionals, so `orelse` supplies the default.
    const algorithm = res.args.algo orelse .sha256;
    const files = res.positionals[0];

    if (files.len == 0) {
        return zigswiss.hash.hashFile(ctx.io, zigswiss.input.stdin_path, algorithm, res.args.hmac, ctx.out);
    }
    for (files) |file| {
        try zigswiss.hash.hashFile(ctx.io, file, algorithm, res.args.hmac, ctx.out);
    }
}
