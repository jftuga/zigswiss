//! archive.zig creates, lists and extracts gzip-compressed tar archives by
//! chaining `std.tar` with `std.compress.flate`. Nothing is held in memory:
//! bytes stream from file to tar to gzip to file. Every function takes a base
//! `Io.Dir` that paths are relative to, which lets the tests use a temp dir.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

/// What the archive command should do.
pub const Mode = enum {
    create,
    list,
    extract,
};

/// Creates the tar.gz file `archive_path` containing `paths`. Each path may be
/// a file or a directory; directories are added recursively.
pub fn create(io: Io, gpa: Allocator, base: Io.Dir, archive_path: []const u8, paths: []const []const u8) !void {
    if (paths.len == 0) return error.NothingToArchive;

    const archive_file = try base.createFile(io, archive_path, .{});
    defer archive_file.close(io);

    // Three writers are stacked here. Bytes written to the tar writer pass
    // through the gzip compressor and then into the buffered file writer:
    //   tar_writer -> compressor.writer -> file_writer.interface -> disk
    var file_buffer: [8192]u8 = undefined;
    var file_writer = archive_file.writer(io, &file_buffer);

    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var compressor = try flate.Compress.init(&file_writer.interface, window, .gzip, .default);

    var tar_writer: std.tar.Writer = .{ .underlying_writer = &compressor.writer };

    for (paths) |raw_path| {
        // "src/" and "src" should behave the same.
        const path = std.mem.trimEnd(u8, raw_path, "/");
        const stat = try base.statFile(io, path, .{});
        switch (stat.kind) {
            .directory => try addDirectory(io, gpa, base, &tar_writer, path),
            .file => try addFile(io, base, &tar_writer, path, path),
            else => return error.UnsupportedFileType,
        }
    }

    // Finish each layer from the inside out, so that every layer's final
    // bytes reach the layer below it before that one is closed off.
    try tar_writer.finishPedantically();
    try compressor.finish();
    try file_writer.interface.flush();
}

/// Adds the directory `dir_path` and everything below it.
fn addDirectory(io: Io, gpa: Allocator, base: Io.Dir, tar_writer: *std.tar.Writer, dir_path: []const u8) !void {
    // A directory must be opened with `.iterate = true` to list its entries.
    var dir = try base.openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    // `setRoot` writes an entry for the directory itself and then prefixes
    // every later entry name with it. Reset the prefix when done.
    try tar_writer.setRoot(dir_path);
    defer tar_writer.prefix = "";

    // The walker visits the whole tree. It allocates because it keeps a stack
    // of open directories and builds each entry's relative path.
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => try tar_writer.writeDir(entry.path, .{}),
            // `entry.dir` is the already-open parent of the entry, so the file
            // can be opened by its base name. Tar entry names always use "/";
            // on Windows `entry.path` would need its separators converted.
            .file => try addFile(io, entry.dir, tar_writer, entry.basename, entry.path),
            // Symlinks, sockets, devices and so on are skipped.
            else => {},
        }
    }
}

/// Adds one file. `open_path` is how to open it relative to `dir`, and
/// `entry_name` is the name it gets inside the archive.
fn addFile(io: Io, dir: Io.Dir, tar_writer: *std.tar.Writer, open_path: []const u8, entry_name: []const u8) !void {
    const file = try dir.openFile(io, open_path, .{});
    defer file.close(io);
    var buffer: [8192]u8 = undefined;
    var file_reader = file.reader(io, &buffer);
    const stat = try file.stat(io);
    try tar_writer.writeFileTimestamp(entry_name, &file_reader, stat.mtime);
}

/// Writes one line per archive entry to `out`.
pub fn list(io: Io, gpa: Allocator, base: Io.Dir, archive_path: []const u8, out: *Io.Writer) !void {
    try readArchive(io, gpa, base, archive_path, .{ .list = out });
}

/// Extracts the archive into the directory `destination`, creating it if
/// needed. Existing files are never overwritten: `error.PathAlreadyExists` is
/// returned instead. `std.tar` rejects entry names that try to escape the
/// destination with "..".
pub fn extract(io: Io, gpa: Allocator, base: Io.Dir, archive_path: []const u8, destination: []const u8) !void {
    var destination_dir = try base.createDirPathOpen(io, destination, .{});
    defer destination_dir.close(io);
    try readArchive(io, gpa, base, archive_path, .{ .extract = destination_dir });
}

/// What to do with an archive once it is open. This is a tagged union: a value
/// is exactly one of the variants, and each variant carries its own payload.
const ReadAction = union(enum) {
    list: *Io.Writer,
    extract: Io.Dir,
};

/// Opens the archive and sets up the reader chain shared by list and extract:
///   disk -> file_reader.interface -> decompressor.reader -> tar
///
/// The chain cannot be built in a helper that returns it, because each layer
/// holds a pointer to the layer before it, and those layers are local
/// variables that would be gone after the helper returns. So the chain is built
/// here and the action to perform is passed in.
fn readArchive(io: Io, gpa: Allocator, base: Io.Dir, archive_path: []const u8, action: ReadAction) !void {
    const archive_file = try base.openFile(io, archive_path, .{});
    defer archive_file.close(io);
    var file_buffer: [8192]u8 = undefined;
    var file_reader = archive_file.reader(io, &file_buffer);

    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var decompressor = flate.Decompress.init(&file_reader.interface, .gzip, window);

    switch (action) {
        .list => |out| try listEntries(&decompressor.reader, out),
        .extract => |dir| try std.tar.extract(io, dir, &decompressor.reader, .{}),
    }
}

fn listEntries(tar_reader: *Io.Reader, out: *Io.Writer) !void {
    // The iterator needs scratch space for the names of the current entry.
    var name_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    var link_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    var iterator: std.tar.Iterator = .init(tar_reader, .{
        .file_name_buffer = &name_buffer,
        .link_name_buffer = &link_buffer,
    });
    while (try iterator.next()) |entry| {
        try out.print("{s:<9} {d:>10}  {s}\n", .{ @tagName(entry.kind), entry.size, entry.name });
    }
}

test "create, list and extract" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project/docs");
    try tmp.dir.writeFile(io, .{ .sub_path = "project/main.txt", .data = "main contents" });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/docs/guide.txt", .data = "guide contents" });
    try tmp.dir.writeFile(io, .{ .sub_path = "loose.txt", .data = "loose contents" });

    try create(io, gpa, tmp.dir, "out.tar.gz", &.{ "project/", "loose.txt" });

    var listing: Io.Writer.Allocating = .init(gpa);
    defer listing.deinit();
    try list(io, gpa, tmp.dir, "out.tar.gz", &listing.writer);
    try std.testing.expect(std.mem.indexOf(u8, listing.written(), "project/main.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, listing.written(), "project/docs/guide.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, listing.written(), "loose.txt") != null);

    try extract(io, gpa, tmp.dir, "out.tar.gz", "restored");
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("guide contents", try tmp.dir.readFile(io, "restored/project/docs/guide.txt", &buffer));
    try std.testing.expectEqualStrings("loose contents", try tmp.dir.readFile(io, "restored/loose.txt", &buffer));

    // Extracting a second time must refuse to overwrite.
    try std.testing.expectError(error.PathAlreadyExists, extract(io, gpa, tmp.dir, "out.tar.gz", "restored"));
}

test "create requires at least one path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectError(error.NothingToArchive, create(std.testing.io, std.testing.allocator, tmp.dir, "out.tar.gz", &.{}));
}
