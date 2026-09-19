# zigswiss

[Disclaimer](#disclaimer) | [Requirements](#requirements) | [Build, run, test](#build-run-test) | [Subcommands](#subcommands) | [Examples](#examples) | [Project layout](#project-layout) | [Understanding build.zig](#understanding-buildzig) | [Zig 0.16 notes](#zig-016-notes) | [Recommended reading order](#recommended-reading-order) | [Is this idiomatic Zig?](#is-this-idiomatic-zig) | [Limitations](#limitations)

A Swiss army knife CLI written in Zig 0.16. It is the Zig sibling of
[mtool](https://github.com/jftuga/mtool) (Go) and
[swiftswiss](https://github.com/jftuga/swiftswiss) (Swift): one binary with a
set of small, useful subcommands, each chosen to exercise an important part of
the standard library.

The real purpose of the project is to be a readable Zig code base to learn
from. The code favors the plain and obvious way of doing things, and the
comments explain each Zig concept the first time it appears, written for
someone coming from Go.

It uses the Zig standard library plus exactly one third-party package,
[zig-clap](https://github.com/Hejsil/zig-clap) for argument parsing, which is
there to show how the package manager works.

## Disclaimer

This software was developed with the assistance of AI: Anthropic Claude Fable
5.1, running in Claude Code at the xhigh effort level. It is provided "as is",
without warranty of any kind. Use at your own risk. In particular, treat
`encrypt` and `decrypt` as a demonstration of `std.crypto` and not as an
audited security tool.

It is also not an authoritative guide to idiomatic Zig, and it has known gaps:
read [Is this idiomatic Zig?](#is-this-idiomatic-zig) and
[Limitations](#limitations) before relying on it for either.

## Requirements

Zig **0.16.0**. The version matters. Zig is pre-1.0 and every release breaks
source compatibility; 0.16 in particular moved all file, network, clock and
random APIs behind the new `std.Io` interface. This code will not compile with
0.15 or earlier, and will likely need changes for 0.17.

```bash
zig version   # must print 0.16.0
```

## Build, run, test

```bash
zig build                          # Debug build -> zig-out/bin/zigswiss
zig build -Doptimize=ReleaseSafe   # optimized, safety checks kept
zig build run -- hash build.zig    # build and run with arguments
zig build test --summary all       # run the ~45 unit tests
zig build -Dtarget=x86_64-linux    # cross-compile, no extra toolchain needed
```

The first build downloads zig-clap into `zig-pkg/`. After that, builds work
offline.

A `Makefile` wraps the same commands: `make`, `make release`, `make test`,
`make fmt`, `make cross`, `make dist`, `make install`. Run `make help` for the
full list.

## Subcommands

| Command | What it does | Standard library areas it demonstrates |
|---|---|---|
| `hash` | md5, sha1, sha256, sha512, sha3_256, blake3, crc32, optional HMAC | `std.crypto.hash`, `std.crypto.auth.hmac`, `std.hash`, streaming with `Io.Reader`, generics with `comptime` and `anytype` |
| `encode`, `decode` | base64, base64url, hex, url | `std.base64`, `std.fmt`, `std.Uri`, allocators, `errdefer` |
| `generate` | passwords, hex tokens, UUIDv4 | `std.Random`, `io.randomSecure`, enum methods, bit operations |
| `transform` | upper, lower, reverse, sort, uniq, count, replace, freq | `std.mem`, `std.ascii`, `std.unicode`, `std.ArrayList`, `std.StringHashMap`, sorting |
| `json` | pretty, compact, validate, dot-path query | `std.json`, tagged unions, optionals |
| `time` | now, epoch to ISO 8601 and back | `Io.Timestamp`, `std.time.epoch`, integer casts |
| `jwt` | decode a token (no verification) | reuse of other library files, `init`/`deinit` structs |
| `compress` | gzip and zlib both ways; zstd and xz decompress only | `std.compress.flate`, `zstd`, `xz`, chained readers and writers |
| `encrypt`, `decrypt` | AES-256-GCM with a PBKDF2 password key | `std.crypto.aead`, `std.crypto.pwhash`, arrays versus slices |
| `info` | OS, arch, CPU count, memory, hostname, environment; text or JSON | `builtin`, `std.process`, `std.Thread`, arenas, `std.json.Stringify`, compile-time `if` |
| `net` | check whether TCP ports are open | `std.Io.net`, handling errors with `if/else` |
| `fetch` | HTTP(S) request, a minimal curl | `std.http.Client`, `std.Uri` |
| `archive` | create, list, extract `.tar.gz` | `std.tar`, `Io.Dir.walk`, three-layer writer stacks, defining a tagged union |
| `bench` | concurrent HTTP benchmark with percentiles | `Io.Group`, `Io.Mutex`, `std.atomic`, float conversion |
| `version` | version, Zig version, build mode, target, repo URL | build options passed from `build.zig` |

Every command accepts `--help`. Commands that read input take a file argument,
or read stdin when the argument is `-` or missing.

## Examples

```bash
# Hashing
zigswiss hash build.zig src/main.zig
echo hello | zigswiss hash --algo blake3
zigswiss hash --algo sha256 --hmac "secret-key" build.zig

# Encoding
echo "hello world" | zigswiss encode
echo "aGVsbG8gd29ybGQK" | zigswiss decode
echo -n "a b&c" | zigswiss encode --format url

# Secrets
zigswiss generate --length 32 --charset full
zigswiss generate --mode token --length 16 --count 3
zigswiss generate --mode uuid

# Text
zigswiss transform --mode sort names.txt
zigswiss transform --mode freq README.md | head
cat notes.txt | zigswiss transform --mode replace --find cat --replace dog

# JSON
zigswiss json config.json
zigswiss json --mode compact config.json
zigswiss json --query servers.0.name config.json
echo '{"a":' | zigswiss json --mode validate

# Time
zigswiss time
zigswiss time --mode fromepoch 1000000000
zigswiss time --mode toepoch 2001-09-09T01:46:40Z

# JWT
zigswiss jwt eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0In0.c2ln

# Compression
zigswiss compress big.log --output big.log.gz
zigswiss compress --decompress big.log.gz
zstd -c big.log | zigswiss compress --decompress --format zstd

# Encryption (password from a flag or from ZIGSWISS_PASSWORD)
zigswiss encrypt --password hunter2 notes.txt --output notes.enc
ZIGSWISS_PASSWORD=hunter2 zigswiss decrypt notes.enc

# System
zigswiss info
zigswiss info --format json --env

# Network
zigswiss net example.com 80 443
zigswiss fetch --include https://example.com
zigswiss fetch --data '{"key":"val"}' https://httpbin.org/post
zigswiss bench --requests 200 --concurrency 20 https://example.com

# Archives
zigswiss archive --mode create --file backup.tar.gz src README.md
zigswiss archive --mode list --file backup.tar.gz
zigswiss archive --mode extract --file backup.tar.gz --directory restored
```

## Project layout

```
build.zig          build script (see UNDERSTANDING_BUILD_ZIG.md)
build.zig.zon      package manifest: name, version, dependencies
Makefile           convenience wrapper around zig build
src/
  main.zig         entry point: builds the Context, dispatches the subcommand
  cli.zig          Context struct, zig-clap wrapper, help and output helpers
  cmd/             one file per subcommand: declare flags, parse, call the library
  root.zig         root of the "zigswiss" library module; re-exports src/lib
  lib/             one file per subcommand: the actual logic plus its unit tests
    input.zig      shared "open a file or stdin" helpers
    test_server.zig  tiny HTTP server used only by the fetch and bench tests
```

This is the same split as mtool's `cmd_*.go` and `internal/*`. The project is
compiled as two modules:

- The **library module** `zigswiss` (`src/root.zig` and `src/lib/`). It knows
  nothing about command lines. Functions take what they need as parameters (an
  `Io`, an allocator, a writer) and are therefore easy to test.
- The **executable module** (`src/main.zig`, `src/cli.zig`, `src/cmd/`). It
  parses arguments with zig-clap and calls into the library.

## Understanding build.zig

See [UNDERSTANDING_BUILD_ZIG.md](UNDERSTANDING_BUILD_ZIG.md) for a step-by-step
walkthrough of `build.zig` and `build.zig.zon`: options, the zig-clap
dependency, modules and `@import`, and the install, run and test steps.

## Zig 0.16 notes

Things that were learned the hard way while writing this, and that most
tutorials written for earlier versions get wrong:

- **`main` receives `std.process.Init`.** Arguments, environment variables, a
  general purpose allocator, an arena and the `Io` instance all come from it.
  There are no global equivalents.
- **Everything that touches the outside world takes an `io: Io` parameter**:
  files, directories, sockets, clocks, sleeping, randomness, mutexes and tasks.
  `std.fs.cwd()` is now `std.Io.Dir.cwd()`, `std.time.timestamp()` is now
  `Io.Timestamp.now(io, .real)`, and `std.crypto.random` is now
  `io.randomSecure(buffer)`.
- **Readers and writers do not own buffers.** You declare a buffer, pass it
  in, and use the `.interface` field as the generic `*Io.Reader` or
  `*Io.Writer`. Forgetting `flush()` loses output.
- **`File.writer()` and `File.reader()` are positional.** They read and write
  at explicit offsets starting from 0. For stdout, stderr and stdin, use
  `writerStreaming()` and `readerStreaming()`. With the positional default,
  `zigswiss hash a >> log.txt` overwrote the beginning of `log.txt` (observed on macOS). The
  `zig init` template and zig-clap's `reportToFile` both have this problem,
  which is why `src/cli.zig` reports parse errors through its own writer.
- **Do not return a reader or writer chain from a helper.** Each layer holds a
  pointer to the previous one, so they must all live in the same stack frame.
  See `readArchive` in `src/lib/archive.zig`.
- **`std.ArrayList` is unmanaged.** It does not store an allocator; pass one to
  `append`, `deinit` and friends. Initialize with `.empty`.
- **Concurrency is part of `Io`.** `io.concurrent(func, args)` returns a
  future, `Io.Group` manages a set of tasks, and cancellation is an ordinary
  error (`error.Canceled`) that must be propagated.
- **TCP connect timeouts are not implemented** in 0.16.0. Setting one panics
  with "TODO implement netConnectIpPosix with timeout", so `zigswiss net` has no
  timeout flag and a filtered port waits for the OS default.
- **The standard library cannot write zstd or xz**, only read them.

## Recommended reading order

Foundation first, complexity last. Each file explains the concepts it
introduces, and later files assume the earlier ones.

1. `build.zig` and `build.zig.zon`, together with [UNDERSTANDING_BUILD_ZIG.md](UNDERSTANDING_BUILD_ZIG.md).
2. `src/root.zig`: modules, `pub`, `@import`, how tests are collected.
3. `src/lib/input.zig`: error unions, `try`, `defer`, files, buffers and readers.
4. `src/lib/codec.zig`: allocators, slices, `errdefer`, enums and `switch`, first tests.
5. `src/lib/generate.zig`: enum methods, mutating through pointers, arrays by value.
6. `src/lib/transform.zig`: `ArrayList`, `StringHashMap`, options structs, sorting.
7. `src/lib/hash.zig`: optionals, `comptime` generics, `anytype`, streaming.
8. `src/lib/json.zig`: tagged unions, returning `null` versus returning an error.
9. `src/lib/time.zig`: integer types and casts, `while` loops, the `Io` clock.
10. `src/lib/jwt.zig`: composing library files, structs with `init` and `deinit`.
11. `src/lib/compress.zig`: chaining readers and writers.
12. `src/lib/crypt.zig`: fixed-size arrays versus slices, `std.crypto`.
13. `src/lib/info.zig`: `builtin`, compile-time `if`, arenas, writing JSON.
14. `src/cli.zig`, then `src/cmd/hash.zig`: the third-party import and comptime-driven argument parsing. The other files in `src/cmd/` follow the same pattern.
15. `src/main.zig`: `std.process.Init`, stdout, dispatch, exit codes.
16. `src/lib/net.zig`: sockets, handling both branches of an error union.
17. `src/lib/fetch.zig` and `src/lib/test_server.zig`: HTTP client and server, a first concurrent task.
18. `src/lib/archive.zig`: directory walking, three-layer streams, defining a tagged union.
19. `src/lib/bench.zig`: task groups, mutexes and atomics.

## Is this idiomatic Zig?

Partly. See [IDIOMATIC_ZIG_ASSESSMENT.md](IDIOMATIC_ZIG_ASSESSMENT.md) for the
verbatim question and the AI author's own answer: where this code chose
simplicity over idiom, which Zig topics it does not cover, and what to read
alongside it.

## Limitations

- `net` has no connect timeout (see above).
- `compress`, `encrypt`, `decrypt`, `encode`, `decode`, `json` and `transform`
  load the whole input into memory. `hash` and `archive` stream.
- `time` works in UTC only. The standard library has no time zone database.
- `archive` never overwrites existing files on extract, skips symlinks when
  creating, and has only been exercised on POSIX path separators.
- `info` reports the hostname as "unknown" on Windows.
- `transform --mode replace` is a literal replace. The standard library has no
  regular expression engine.
