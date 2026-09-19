//! cmd/generate.zig is the front end of `zigswiss generate`. It creates one
//! cryptographically secure random generator and uses it for every value.

const std = @import("std");
const clap = @import("clap");
const zigswiss = @import("zigswiss");
const cli = @import("../cli.zig");

const params = clap.parseParamsComptime(
    \\-h, --help               Display this help and exit.
    \\-m, --mode <MODE>        password (default), token, uuid
    \\-l, --length <N>         Password characters or token bytes (default 24).
    \\-c, --count <N>          How many values to generate (default 1).
    \\    --charset <CHARSET>  For passwords: alnum (default), alpha, digits, full
    \\
);

const parsers = .{
    .MODE = clap.parsers.enumeration(zigswiss.generate.Mode),
    // `int(usize, 10)` parses a base-10 number and rejects anything else.
    .N = clap.parsers.int(usize, 10),
    .CHARSET = clap.parsers.enumeration(zigswiss.generate.Charset),
};

pub fn run(ctx: *cli.Context) !void {
    var res = try cli.parse(ctx, &params, parsers);
    defer res.deinit();
    if (res.args.help != 0) return cli.printHelp(ctx, "generate [options]", &params);

    const mode = res.args.mode orelse .password;
    const length = res.args.length orelse 24;
    const count = res.args.count orelse 1;
    const charset = res.args.charset orelse .alnum;

    // `generator` must be `var`: producing random numbers changes its state.
    var generator = try zigswiss.generate.secureGenerator(ctx.io);
    const random = generator.random();

    // `for (0..count)` loops over a range. `_` discards the loop index.
    for (0..count) |_| {
        switch (mode) {
            .password => {
                const password = try zigswiss.generate.password(ctx.gpa, random, length, charset);
                defer ctx.gpa.free(password);
                try ctx.out.print("{s}\n", .{password});
            },
            .token => {
                const token = try zigswiss.generate.token(ctx.gpa, random, length);
                defer ctx.gpa.free(token);
                try ctx.out.print("{s}\n", .{token});
            },
            // The UUID is an array returned by value, so there is nothing to
            // free. `&` turns the array into a slice for the `{s}` format.
            .uuid => try ctx.out.print("{s}\n", .{&zigswiss.generate.uuid(random)}),
        }
    }
}
