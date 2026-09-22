const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const File = std.Io.File;
const Dir = std.Io.Dir;
const config_mod = @import("config.zig");

pub fn getHomeDir(environ: *std.process.Environ.Map) []const u8 {
    return config_mod.getHomeDir(environ);
}

pub fn getCredentialsPath(allocator: Allocator, environ: *std.process.Environ.Map) ![]const u8 {
    if (environ.get("XDG_DATA_HOME")) |xdg_data| {
        return try std.fmt.allocPrint(allocator, "{s}/ask/credentials", .{xdg_data});
    }
    const home = getHomeDir(environ);
    return try std.fmt.allocPrint(allocator, "{s}/.local/share/ask/credentials", .{home});
}

pub fn getApiKey(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
) ?[]const u8 {
    // 1. Check GEMINI_API_KEY environment variable
    if (environ.get("GEMINI_API_KEY")) |k| {
        const trimmed = std.mem.trim(u8, k, " \t\r\n");
        if (trimmed.len > 0) return allocator.dupe(u8, trimmed) catch null;
    }

    // 2. Check GOOGLE_API_KEY environment variable
    if (environ.get("GOOGLE_API_KEY")) |k| {
        const trimmed = std.mem.trim(u8, k, " \t\r\n");
        if (trimmed.len > 0) return allocator.dupe(u8, trimmed) catch null;
    }

    // 3. Check persistent secure credentials file (~/.local/share/ask/credentials)
    const cred_path = getCredentialsPath(allocator, environ) catch return null;
    defer allocator.free(cred_path);

    const file = Dir.openFileAbsolute(io, cred_path, .{}) catch |err| {
        if (err != error.FileNotFound) {
            const stderr = File.stderr();
            if (std.fmt.allocPrint(allocator, "Warning: Could not read credentials file: {s}\n", .{@errorName(err)})) |warn| {
                _ = stderr.writeStreamingAll(io, warn) catch {};
                allocator.free(warn);
            } else |_| {}
        }
        return null;
    };
    defer file.close(io);

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    var buf: [1024]u8 = undefined;
    var iov = [_][]u8{&buf};
    while (true) {
        const amt = file.readStreaming(io, &iov) catch break;
        if (amt == 0) break;
        list.appendSlice(allocator, buf[0..amt]) catch break;
    }

    if (list.items.len == 0) {
        const stderr = File.stderr();
        const warn = "Warning: Credentials file is empty\n";
        _ = stderr.writeStreamingAll(io, warn) catch {};
        return null;
    }

    var lines = std.mem.splitScalar(u8, list.items, '\n');
    if (lines.next()) |first_line| {
        const trimmed = std.mem.trim(u8, first_line, " \t\r\n");
        if (trimmed.len > 0) {
            return allocator.dupe(u8, trimmed) catch null;
        }
    }

    return null;
}

pub fn saveApiKey(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    key: []const u8,
) ![]const u8 {
    const trimmed_key = std.mem.trim(u8, key, " \t\r\n");
    if (trimmed_key.len == 0) return error.EmptyApiKey;

    const cred_path = try getCredentialsPath(allocator, environ);
    errdefer allocator.free(cred_path);

    if (std.fs.path.dirname(cred_path)) |dir_path| {
        Dir.createDirAbsolute(io, dir_path, File.Permissions.fromMode(0o700)) catch {};
    }

    const file = try Dir.createFileAbsolute(io, cred_path, .{});
    defer file.close(io);

    // Set secure file permissions (0600: read/write owner only)
    file.setPermissions(io, File.Permissions.fromMode(0o600)) catch {};

    try file.writeStreamingAll(io, trimmed_key);
    try file.writeStreamingAll(io, "\n");

    return cred_path;
}

pub fn clearAll(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
) void {
    // 1. Delete credentials file
    if (getCredentialsPath(allocator, environ)) |cred_path| {
        defer allocator.free(cred_path);
        Dir.deleteFileAbsolute(io, cred_path) catch {};
    } else |_| {}

    // 2. Delete config file
    if (config_mod.getConfigPath(allocator, environ)) |cfg_path| {
        defer allocator.free(cfg_path);
        Dir.deleteFileAbsolute(io, cfg_path) catch {};
    } else |_| {}
}
