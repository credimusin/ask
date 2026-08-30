const std = @import("std");
const Io = std.Io;
const File = std.Io.File;
const Dir = std.Io.Dir;

pub const Config = struct {
    model: []const u8 = "gemini-3.5-flash-lite",
    system_instruction: []const u8 = "You are a lightning-fast CLI assistant. Provide ultra-concise, direct answers. Give immediate commands or code without preamble, conversational filler, or greetings.",
    temperature: f64 = 0.2,
    thinking_budget: ?i32 = 0,
    theme: []const u8 = "catppuccin",
    stream: bool = false,
    fallback: bool = true,
};

pub fn getHomeDir(environ: *std.process.Environ.Map) []const u8 {
    if (environ.get("HOME")) |home| {
        return home;
    }
    return "/tmp";
}

pub fn getConfigPath(allocator: std.mem.Allocator, environ: *std.process.Environ.Map) ![]const u8 {
    if (environ.get("XDG_CONFIG_HOME")) |xdg_config| {
        return try std.fmt.allocPrint(allocator, "{s}/ask/config.json", .{xdg_config});
    }
    const home = getHomeDir(environ);
    return try std.fmt.allocPrint(allocator, "{s}/.config/ask/config.json", .{home});
}

pub fn load(allocator: std.mem.Allocator, io: Io, environ: *std.process.Environ.Map) Config {
    const default_cfg = Config{};
    const config_path = getConfigPath(allocator, environ) catch return default_cfg;

    const file = Dir.openFileAbsolute(io, config_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            saveDefault(io, config_path) catch {};
        }
        return default_cfg;
    };
    defer file.close(io);

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    var buf: [4096]u8 = undefined;
    var iov = [_][]u8{&buf};
    while (true) {
        const amt = file.readStreaming(io, &iov) catch break;
        if (amt == 0) break;
        list.appendSlice(allocator, buf[0..amt]) catch break;
    }

    if (list.items.len == 0) return default_cfg;

    const parsed = std.json.parseFromSlice(Config, allocator, list.items, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return default_cfg;

    return parsed.value;
}

pub fn saveDefault(io: Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir_path| {
        Dir.createDirAbsolute(io, dir_path, File.Permissions.default_dir) catch {};
    }
    const file = try Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);

    const default_json =
        \\{
        \\  "model": "gemini-3.5-flash-lite",
        \\  "system_instruction": "You are a lightning-fast CLI assistant. Provide ultra-concise, direct answers. Give immediate commands or code without preamble, conversational filler, or greetings.",
        \\  "temperature": 0.2,
        \\  "thinking_budget": 0,
        \\  "theme": "catppuccin",
        \\  "stream": false,
        \\  "fallback": true
        \\}
        \\
    ;
    try file.writeStreamingAll(io, default_json);
}
