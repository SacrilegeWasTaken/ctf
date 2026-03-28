const std = @import("std");
const config = @import("config.zig");
const runner = @import("runner.zig");

const green = "\x1b[32m";
const reset = "\x1b[0m";

const Command = enum { run, list };

const Opts = struct {
    command: Command,
    module: []const u8 = "",
    config_file: []const u8 = "ctf.toml",
    run_opts: runner.RunOpts = .{},
    // track what was explicitly set via CLI (vs coming from config)
    cli_fix: bool = false,
    cli_dry_run: bool = false,
    cli_filter: bool = false,
    cli_jobs: bool = false,
};

/// Matches "--flag" or "--flag=value".
/// Returns null if arg doesn't start with name.
/// Returns ?[]const u8: null means no "=", slice means value after "=".
fn parseFlag(arg: []const u8, name: []const u8) ??[]const u8 {
    if (std.mem.eql(u8, arg, name)) return @as(?[]const u8, null);
    if (std.mem.startsWith(u8, arg, name) and arg.len > name.len and arg[name.len] == '=')
        return @as(?[]const u8, arg[name.len + 1 ..]);
    return null;
}

fn parseArgs(args: []const []const u8) !Opts {
    if (args.len < 2) return error.NotEnoughArgs;

    const command = std.meta.stringToEnum(Command, args[1]) orelse
        return error.UnknownCommand;

    if (command == .list) {
        var config_file: []const u8 = "ctf.toml";
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (parseFlag(args[i], "--file")) |val| {
                config_file = val orelse blk: {
                    i += 1;
                    if (i >= args.len) return error.MissingValue;
                    break :blk args[i];
                };
            } else {
                std.debug.print("unknown flag: {s}\n", .{args[i]});
                return error.UnknownFlag;
            }
        }
        return .{ .command = .list, .config_file = config_file };
    }

    // run command
    if (args.len < 3) return error.NotEnoughArgs;
    const module = args[2];

    var config_file: []const u8 = "ctf.toml";
    var run_opts = runner.RunOpts{};
    var cli_fix = false;
    var cli_dry_run = false;
    var cli_filter = false;
    var cli_jobs = false;

    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (parseFlag(arg, "--file")) |val| {
            config_file = val orelse blk: {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                break :blk args[i];
            };
        } else if (parseFlag(arg, "--flags")) |val| {
            run_opts.cli_flags = val orelse blk: {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                break :blk args[i];
            };
        } else if (parseFlag(arg, "--filter")) |val| {
            run_opts.filter = val orelse blk: {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                break :blk args[i];
            };
            cli_filter = true;
        } else if (parseFlag(arg, "--jobs")) |val| {
            const s = val orelse blk: {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                break :blk args[i];
            };
            run_opts.jobs = std.fmt.parseInt(usize, s, 10) catch return error.InvalidJobs;
            if (run_opts.jobs == 0) return error.InvalidJobs;
            cli_jobs = true;
        } else if (std.mem.eql(u8, arg, "--fix")) {
            run_opts.fix = true;
            cli_fix = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            run_opts.dry_run = true;
            cli_dry_run = true;
        } else {
            std.debug.print("unknown flag: {s}\n", .{arg});
            return error.UnknownFlag;
        }
    }

    return .{
        .command = .run,
        .module = module,
        .config_file = config_file,
        .run_opts = run_opts,
        .cli_fix = cli_fix,
        .cli_dry_run = cli_dry_run,
        .cli_filter = cli_filter,
        .cli_jobs = cli_jobs,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const raw = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, raw);

    const opts = parseArgs(raw) catch |err| {
        std.debug.print(
            \\usage:
            \\  ctf list [--file ctf.toml]
            \\  ctf run <module|all> [--file ctf.toml] [--flags "..."] [--filter pattern]
            \\             [--jobs N] [--fix] [--dry-run]
            \\error: {s}
            \\
        , .{@errorName(err)});
        std.process.exit(1);
    };

    var cfg = config.parseFile(allocator, opts.config_file) catch |err| {
        std.debug.print("error: cannot read '{s}': {s}\n", .{ opts.config_file, @errorName(err) });
        std.process.exit(1);
    };
    defer cfg.deinit();

    // Merge: CLI flag takes priority over ctf.toml value
    var run_opts = opts.run_opts;
    if (!opts.cli_fix) run_opts.fix = cfg.fix;
    if (!opts.cli_dry_run) run_opts.dry_run = cfg.dry_run;
    if (!opts.cli_filter) run_opts.filter = cfg.filter;
    if (!opts.cli_jobs) run_opts.jobs = cfg.jobs;

    switch (opts.command) {
        .list => {
            for (cfg.modules) |mod| {
                std.debug.print(green ++ "[{s}]" ++ reset ++ "\n", .{mod.name});
                for (mod.paths) |p| std.debug.print("  path: {s}\n", .{p});
                std.debug.print("  files: {s}\n", .{mod.files});
                if (mod.clang_tidy_flags.len > 0)
                    std.debug.print("  flags: {s}\n", .{mod.clang_tidy_flags});
            }
        },
        .run => {
            const all = std.mem.eql(u8, opts.module, "all");
            const modules: []const config.Module = if (all) cfg.modules else blk: {
                const mod = cfg.findModule(opts.module) orelse {
                    std.debug.print("error: module '{s}' not found in {s}\n", .{ opts.module, opts.config_file });
                    std.process.exit(1);
                };
                // stable single-element slice on the stack
                var buf = [1]config.Module{mod};
                break :blk &buf;
            };

            var all_passed = true;
            for (modules) |mod| {
                const passed = try runner.run(
                    allocator,
                    cfg.clang_tidy,
                    cfg.clang_tidy_flags,
                    cfg.compile_commands,
                    run_opts,
                    mod,
                );
                if (!passed) all_passed = false;
            }
            if (!all_passed) std.process.exit(1);
        },
    }
}

// --- tests ---

test "parseFlag: exact match returns null value" {
    const result = parseFlag("--file", "--file");
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == null);
}

test "parseFlag: --flag=value returns value" {
    const result = parseFlag("--file=path/to/file", "--file");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("path/to/file", result.?.?);
}

test "parseFlag: --flag= empty value" {
    const result = parseFlag("--file=", "--file");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("", result.?.?);
}

test "parseFlag: different flag returns null" {
    try std.testing.expect(parseFlag("--other", "--file") == null);
    try std.testing.expect(parseFlag("--fileextra", "--file") == null);
    try std.testing.expect(parseFlag("", "--file") == null);
    try std.testing.expect(parseFlag("-file", "--file") == null);
}

test "parseArgs: too few args" {
    try std.testing.expectError(error.NotEnoughArgs, parseArgs(&.{"ctf"}));
    try std.testing.expectError(error.NotEnoughArgs, parseArgs(&.{ "ctf", "run" }));
}

test "parseArgs: unknown command" {
    try std.testing.expectError(error.UnknownCommand, parseArgs(&.{ "ctf", "launch", "ACd" }));
    try std.testing.expectError(error.UnknownCommand, parseArgs(&.{ "ctf", "", "ACd" }));
}

test "parseArgs: basic run" {
    const opts = try parseArgs(&.{ "ctf", "run", "ACd" });
    try std.testing.expectEqual(Command.run, opts.command);
    try std.testing.expectEqualStrings("ACd", opts.module);
    try std.testing.expectEqualStrings("ctf.toml", opts.config_file);
    try std.testing.expect(opts.run_opts.cli_flags == null);
    try std.testing.expect(!opts.run_opts.fix);
    try std.testing.expect(!opts.run_opts.dry_run);
}

test "parseArgs: run all" {
    const opts = try parseArgs(&.{ "ctf", "run", "all" });
    try std.testing.expectEqualStrings("all", opts.module);
}

test "parseArgs: list command" {
    const opts = try parseArgs(&.{ "ctf", "list" });
    try std.testing.expectEqual(Command.list, opts.command);
    try std.testing.expectEqualStrings("ctf.toml", opts.config_file);
}

test "parseArgs: list with --file" {
    const opts = try parseArgs(&.{ "ctf", "list", "--file=custom.toml" });
    try std.testing.expectEqualStrings("custom.toml", opts.config_file);
}

test "parseArgs: --file space separated" {
    const opts = try parseArgs(&.{ "ctf", "run", "ACd", "--file", "custom.toml" });
    try std.testing.expectEqualStrings("custom.toml", opts.config_file);
}

test "parseArgs: --file=value" {
    const opts = try parseArgs(&.{ "ctf", "run", "ACd", "--file=custom.toml" });
    try std.testing.expectEqualStrings("custom.toml", opts.config_file);
}

test "parseArgs: --flags=value" {
    const opts = try parseArgs(&.{ "ctf", "run", "ACd", "--flags=--checks=* --warnings-as-errors=*" });
    try std.testing.expectEqualStrings("--checks=* --warnings-as-errors=*", opts.run_opts.cli_flags.?);
}

test "parseArgs: --fix and --dry-run" {
    const opts = try parseArgs(&.{ "ctf", "run", "ACd", "--fix", "--dry-run" });
    try std.testing.expect(opts.run_opts.fix);
    try std.testing.expect(opts.run_opts.dry_run);
}


test "parseArgs: --filter=pattern" {
    const opts = try parseArgs(&.{ "ctf", "run", "ACd", "--filter=*.cpp" });
    try std.testing.expectEqualStrings("*.cpp", opts.run_opts.filter.?);
}

test "parseArgs: --file missing value" {
    try std.testing.expectError(error.MissingValue, parseArgs(&.{ "ctf", "run", "ACd", "--file" }));
}

test "parseArgs: --flags missing value" {
    try std.testing.expectError(error.MissingValue, parseArgs(&.{ "ctf", "run", "ACd", "--flags" }));
}


test "parseArgs: unknown flag" {
    try std.testing.expectError(error.UnknownFlag, parseArgs(&.{ "ctf", "run", "ACd", "--unknown" }));
    try std.testing.expectError(error.UnknownFlag, parseArgs(&.{ "ctf", "run", "ACd", "bareword" }));
}

test "parseArgs: all flags combined" {
    const opts = try parseArgs(&.{
        "ctf", "run", "MyMod",
        "--file=a.toml",
        "--flags=--checks=*",
        "--filter=*.cpp",
        "--fix",
        "--dry-run",
    });
    try std.testing.expectEqualStrings("MyMod", opts.module);
    try std.testing.expectEqualStrings("a.toml", opts.config_file);
    try std.testing.expectEqualStrings("--checks=*", opts.run_opts.cli_flags.?);
    try std.testing.expectEqualStrings("*.cpp", opts.run_opts.filter.?);
    try std.testing.expect(opts.run_opts.fix);
    try std.testing.expect(opts.run_opts.dry_run);
}
