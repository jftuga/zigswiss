//! input.zig holds the helpers that open and read input for every subcommand.
//! By convention the path "-" means standard input, which lets any command be
//! used at the end of a shell pipeline.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The path that means "read from standard input".
pub const stdin_path = "-";

/// Opens `path` for reading, or returns the stdin handle when `path` is "-".
///
/// The return type `Io.File.OpenError!Io.File` is an "error union": the
/// function returns either an error from the `OpenError` set or a `File`.
pub fn open(io: Io, path: []const u8) Io.File.OpenError!Io.File {
    if (std.mem.eql(u8, path, stdin_path)) return Io.File.stdin();
    return Io.Dir.cwd().openFile(io, path, .{});
}

/// Closes a file returned by `open`. Stdin is left open because we do not own it.
pub fn close(io: Io, file: Io.File) void {
    if (file.handle == Io.File.stdin().handle) return;
    file.close(io);
}

/// Reads all of `path` (or stdin) into memory. The caller owns the returned
/// slice and must release it with `gpa.free(...)`.
pub fn readAll(io: Io, gpa: Allocator, path: []const u8) ![]u8 {
    const file = try open(io, path);
    // `defer` runs the statement when the enclosing block exits, whether the
    // exit is a normal return or an error. It is how Zig does cleanup.
    defer close(io, file);
    return readFile(io, gpa, file);
}

/// Reads everything remaining in an already-open file. The caller owns the
/// returned slice.
pub fn readFile(io: Io, gpa: Allocator, file: Io.File) ![]u8 {
    // Zig 0.16 readers do not allocate their own buffer; the caller supplies
    // one. `undefined` means "do not bother initializing this memory".
    //
    // `readerStreaming` reads from the file's current position, which is what
    // stdin needs. The plain `reader` reads at explicit offsets from 0.
    var buffer: [4096]u8 = undefined;
    var file_reader = file.readerStreaming(io, &buffer);

    // `file_reader` is the concrete type that knows about files. Its
    // `interface` field is the generic `Io.Reader` that all reading code uses.
    return file_reader.interface.allocRemaining(gpa, .unlimited);
}

test "readFile returns the contents of a file" {
    // The test runner provides an Io implementation and an allocator that
    // fails the test if any allocation is leaked.
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "sample.txt", .data = "hello" });

    const file = try tmp.dir.openFile(io, "sample.txt", .{});
    defer file.close(io);
    const contents = try readFile(io, gpa, file);
    defer gpa.free(contents);

    try std.testing.expectEqualStrings("hello", contents);
}
