const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const File = std.Io.File;

const config_mod = @import("config.zig");
const auth_mod = @import("auth.zig");
const api_mod = @import("api.zig");
const ui_mod = @import("ui.zig");
const runner_mod = @import("runner.zig");
const editor_mod = @import("editor.zig");

const VERSION = "0.1.0";

const StreamCtx = struct {
    io: Io,
    stdout: File,
    allocator: Allocator,
    should_style: bool,
    is_tui: bool = false,
    banner_printed: bool = false,
};

fn handleStart(ctx_ptr: *anyopaque, model_used: []const u8, is_fallback: bool) void {
    const ctx: *StreamCtx = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.should_style and !ctx.banner_printed) {
        if (ctx.is_tui) {
            ui_mod.printTuiResponseHeader(ctx.io, ctx.stdout, ctx.allocator, model_used, is_fallback);
        } else {
            ui_mod.printBanner(ctx.io, ctx.stdout, ctx.allocator, model_used, is_fallback);
        }
        ctx.stdout.writeStreamingAll(ctx.io, ui_mod.Colors.text) catch {};
        ctx.banner_printed = true;
    }
}

fn handleChunk(ctx_ptr: *anyopaque, chunk_text: []const u8) void {
    const ctx: *StreamCtx = @ptrCast(@alignCast(ctx_ptr));
    ctx.stdout.writeStreamingAll(ctx.io, chunk_text) catch {};
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const stdout = File.stdout();
    const stdin = File.stdin();

    const cfg = config_mod.load(allocator, io, init.environ_map);

    var model_override: ?[]const u8 = null;
    var save_key_val: ?[]const u8 = null;
    var do_clear = false;
    var raw_mode = false;
    var stream_mode: bool = cfg.stream;
    var fallback_mode: bool = cfg.fallback;
    var show_help = false;
    var show_version = false;
    var show_config = false;
    var force_tui = false;

    var prompt_parts: std.ArrayList([]const u8) = .empty;

    var args_it = init.minimal.args.iterate();
    _ = args_it.next(); // Skip executable path

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            show_help = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            show_version = true;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) {
            show_config = true;
        } else if (std.mem.eql(u8, arg, "--clear") or std.mem.eql(u8, arg, "--reset")) {
            do_clear = true;
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--raw")) {
            raw_mode = true;
        } else if (std.mem.eql(u8, arg, "--no-stream")) {
            stream_mode = false;
        } else if (std.mem.eql(u8, arg, "--stream") or std.mem.eql(u8, arg, "-s")) {
            stream_mode = true;
        } else if (std.mem.eql(u8, arg, "--tui") or std.mem.eql(u8, arg, "-t")) {
            force_tui = true;
        } else if (std.mem.eql(u8, arg, "--no-fallback")) {
            fallback_mode = false;
        } else if (std.mem.eql(u8, arg, "--fallback")) {
            fallback_mode = true;
        } else if (std.mem.eql(u8, arg, "-k") or std.mem.eql(u8, arg, "--key") or std.mem.eql(u8, arg, "--set-key")) {
            if (args_it.next()) |k| {
                save_key_val = k;
            }
        } else if (std.mem.startsWith(u8, arg, "--key=")) {
            save_key_val = arg["--key=".len..];
        } else if (std.mem.startsWith(u8, arg, "--set-key=")) {
            save_key_val = arg["--set-key=".len..];
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--model")) {
            if (args_it.next()) |m| {
                model_override = m;
            }
        } else if (std.mem.startsWith(u8, arg, "--model=")) {
            model_override = arg["--model=".len..];
        } else {
            try prompt_parts.append(allocator, arg);
        }
    }

    if (show_help) {
        ui_mod.printHelp(io, stdout, allocator);
        return;
    }

    if (show_version) {
        const v_str = try std.fmt.allocPrint(allocator, "ask {s} (Zig {s})\n", .{ VERSION, @import("builtin").zig_version_string });
        defer allocator.free(v_str);
        try stdout.writeStreamingAll(io, v_str);
        return;
    }

    if (do_clear) {
        auth_mod.clearAll(allocator, io, init.environ_map);
        ui_mod.printClearedSuccess(io, stdout, allocator);
        return;
    }

    if (save_key_val) |k| {
        const saved_path = auth_mod.saveApiKey(allocator, io, init.environ_map, k) catch |err| {
            const err_msg = try std.fmt.allocPrint(
                allocator,
                "\n{s}Error:{s} Failed to save API key ({})\n\n",
                .{ ui_mod.Colors.error_color ++ ui_mod.Colors.bold, ui_mod.Colors.reset, err },
            );
            defer allocator.free(err_msg);
            try stdout.writeStreamingAll(io, err_msg);
            return;
        };
        defer allocator.free(saved_path);
        ui_mod.printKeySavedSuccess(io, stdout, allocator, saved_path);
        return;
    }

    if (show_config) {
        const cfg_path = try config_mod.getConfigPath(allocator, init.environ_map);
        defer allocator.free(cfg_path);
        const cred_path = try auth_mod.getCredentialsPath(allocator, init.environ_map);
        defer allocator.free(cred_path);
        const has_key = auth_mod.getApiKey(allocator, io, init.environ_map) != null;

        const c_str = try std.fmt.allocPrint(
            allocator,
            \\Config path:     {s}
            \\Credentials:     {s} (status: {s})
            \\Model:           {s}
            \\Fallback:        {s} (pool: gemini-3.5-flash, gemini-3.5-flash-lite, gemini-2.5-flash, gemini-2.5-flash-lite, gemma-4-31b-it)
            \\Streaming:       {s} (default in config: {s})
            \\Temp:            {d:.2}
            \\Thinking Budget: {s}
            \\Theme:           {s}
            \\
        ,
            .{
                cfg_path,
                cred_path,
                if (has_key) "configured" else "missing",
                cfg.model,
                if (fallback_mode) "enabled" else "disabled",
                if (stream_mode) "enabled" else "disabled",
                if (cfg.stream) "enabled" else "disabled",
                cfg.temperature,
                if (cfg.thinking_budget) |b| try std.fmt.allocPrint(allocator, "{d}", .{b}) else "default",
                cfg.theme,
            },
        );
        defer allocator.free(c_str);
        try stdout.writeStreamingAll(io, c_str);
        return;
    }

    const model_to_use = model_override orelse cfg.model;

    // Check if stdin has piped data (not a TTY)
    const is_stdin_tty = stdin.isTty(io) catch true;
    var piped_input: ?[]const u8 = null;

    if (!is_stdin_tty) {
        var stdin_list: std.ArrayList(u8) = .empty;
        var buf: [4096]u8 = undefined;
        var iov = [_][]u8{&buf};
        while (true) {
            const amt = stdin.readStreaming(io, &iov) catch break;
            if (amt == 0) break;
            try stdin_list.appendSlice(allocator, buf[0..amt]);
        }
        if (stdin_list.items.len > 0) {
            piped_input = try stdin_list.toOwnedSlice(allocator);
        }
    }

    // Build final prompt
    var final_prompt: ?[]const u8 = null;

    if (prompt_parts.items.len > 0) {
        var joined_prompt: std.ArrayList(u8) = .empty;
        for (prompt_parts.items, 0..) |part, idx| {
            if (idx > 0) try joined_prompt.append(allocator, ' ');
            try joined_prompt.appendSlice(allocator, part);
        }
        const user_text = try joined_prompt.toOwnedSlice(allocator);

        if (piped_input) |piped| {
            final_prompt = try std.fmt.allocPrint(
                allocator,
                "Context / Input:\n```\n{s}\n```\n\nQuestion / Request: {s}",
                .{ piped, user_text },
            );
        } else {
            final_prompt = user_text;
        }
    } else if (piped_input) |piped| {
        final_prompt = piped;
    }

    // Check for API Key
    const api_key = auth_mod.getApiKey(allocator, io, init.environ_map);
    if (api_key == null) {
        ui_mod.printMissingKeyHelp(io, stdout, allocator);
        return;
    }

    // If no arguments (or --tui) and stdin is a TTY, run interactive TUI
    if ((final_prompt == null or force_tui) and is_stdin_tty) {
        try runInteractive(allocator, io, stdout, stdin, init.environ_map, api_key.?, model_to_use, cfg.system_instruction, cfg.temperature, cfg.thinking_budget, stream_mode, fallback_mode);
        return;
    }

    if (final_prompt == null) {
        ui_mod.printHelp(io, stdout, allocator);
        return;
    }

    // Single shot query
    const is_stdout_tty = stdout.isTty(io) catch true;
    const should_style = is_stdout_tty and !raw_mode;

    const t_start = Io.Timestamp.now(io, .awake);

    var spinner: ?ui_mod.Spinner = null;
    if (should_style and !stream_mode) {
        spinner = ui_mod.Spinner.start(allocator, "Thinking...") catch null;
    }

    var stream_ctx = StreamCtx{
        .io = io,
        .stdout = stdout,
        .allocator = allocator,
        .should_style = should_style and stream_mode,
    };
    var err_detail: ?api_mod.ApiErrorDetail = null;

    const response = api_mod.generateWithFallback(
        allocator,
        io,
        api_key.?,
        model_to_use,
        fallback_mode,
        final_prompt.?,
        cfg.system_instruction,
        cfg.temperature,
        cfg.thinking_budget,
        if (stream_mode) handleStart else null,
        if (stream_mode) handleChunk else null,
        if (stream_mode) @ptrCast(&stream_ctx) else null,
        &err_detail,
    ) catch |err| {
        if (spinner) |*sp| sp.stop(allocator);
        if (should_style) {
            if (err_detail) |ed| {
                ui_mod.printErrorBox(io, stdout, allocator, ed.title, ed.message, ed.suggestion);
            } else {
                const fallback_msg = try std.fmt.allocPrint(allocator, "Failed to get response from Gemini ({})", .{err});
                defer allocator.free(fallback_msg);
                ui_mod.printErrorBox(io, stdout, allocator, "Gemini Error", fallback_msg, null);
            }
        } else {
            if (err_detail) |ed| {
                const raw_err = try std.fmt.allocPrint(allocator, "\nError: {s}\n{s}\n", .{ ed.title, ed.message });
                defer allocator.free(raw_err);
                try stdout.writeStreamingAll(io, raw_err);
                if (ed.suggestion) |sug| {
                    const raw_sug = try std.fmt.allocPrint(allocator, "Suggestion: {s}\n\n", .{sug});
                    defer allocator.free(raw_sug);
                    try stdout.writeStreamingAll(io, raw_sug);
                }
            } else {
                const raw_err = try std.fmt.allocPrint(allocator, "\nError: Failed to get response from Gemini ({})\n\n", .{err});
                defer allocator.free(raw_err);
                try stdout.writeStreamingAll(io, raw_err);
            }
        }
        return;
    };

    if (spinner) |*sp| sp.stop(allocator);

    const t_end = Io.Timestamp.now(io, .awake);
    const elapsed: u64 = @intCast(@max(0, t_start.durationTo(t_end).toMilliseconds()));

    if (should_style) {
        if (!stream_mode) {
            ui_mod.printBanner(io, stdout, allocator, response.model, response.is_fallback);
            ui_mod.renderMarkdown(io, stdout, allocator, response.text);
        } else {
            try stdout.writeStreamingAll(io, ui_mod.Colors.reset);
            if (!std.mem.endsWith(u8, response.text, "\n")) {
                try stdout.writeStreamingAll(io, "\n");
            }
        }
        ui_mod.printFooter(io, stdout, allocator, elapsed, response.prompt_tokens, response.candidates_tokens, response.model);

        const snippets = runner_mod.extractCodeSnippets(allocator, response.text);
        if (snippets.len > 0) {
            runner_mod.promptAndExecute(allocator, io, stdout, stdin, init.environ_map, snippets);
        }
    } else {
        if (!stream_mode) {
            try stdout.writeStreamingAll(io, response.text);
        }
        if (!std.mem.endsWith(u8, response.text, "\n")) {
            try stdout.writeStreamingAll(io, "\n");
        }
    }
}

fn runInteractive(
    allocator: Allocator,
    io: Io,
    stdout: File,
    stdin: File,
    environ_map: *std.process.Environ.Map,
    api_key: []const u8,
    initial_model: []const u8,
    system_instruction: ?[]const u8,
    initial_temperature: f64,
    thinking_budget: ?i32,
    initial_stream_mode: bool,
    fallback_mode: bool,
) !void {
    var active_model: []const u8 = initial_model;
    var stream_mode: bool = initial_stream_mode;
    const temperature: f64 = initial_temperature;

    var history: std.ArrayList([]const u8) = .empty;
    defer {
        for (history.items) |h| allocator.free(h);
        history.deinit(allocator);
    }

    var last_response_text: ?[]const u8 = null;
    defer if (last_response_text) |t| allocator.free(t);

    var last_snippets: []const runner_mod.CodeSnippet = &[_]runner_mod.CodeSnippet{};
    defer {
        for (last_snippets) |s| {
            allocator.free(s.code);
            allocator.free(s.lang);
        }
        if (last_snippets.len > 0) allocator.free(last_snippets);
    }

    ui_mod.printTuiWelcome(io, stdout, allocator, active_model, stream_mode);

    while (true) {
        const prompt_marker = try std.fmt.allocPrint(
            allocator,
            "{s}ask ❯{s} ",
            .{ ui_mod.Colors.primary ++ ui_mod.Colors.bold, ui_mod.Colors.reset },
        );
        defer allocator.free(prompt_marker);

        const res = editor_mod.readInteractiveLine(allocator, io, stdin, stdout, prompt_marker, &history);
        switch (res) {
            .exit => break,
            .clear_screen => {
                stdout.writeStreamingAll(io, "\x1b[2J\x1b[H") catch {};
                ui_mod.printTuiWelcome(io, stdout, allocator, active_model, stream_mode);
                continue;
            },
            .line => |line_raw| {
                const line = std.mem.trim(u8, line_raw, " \t\r\n");
                if (line.len == 0) continue;

                // Add to history if not duplicate of last item
                if (history.items.len == 0 or !std.mem.eql(u8, history.items[history.items.len - 1], line)) {
                    if (allocator.dupe(u8, line)) |duped| {
                        history.append(allocator, duped) catch {};
                    } else |_| {}
                }

                // 1. Slash commands & exit checks
                if (std.mem.eql(u8, line, "exit") or std.mem.eql(u8, line, "quit") or std.mem.eql(u8, line, "q") or std.mem.eql(u8, line, "/exit") or std.mem.eql(u8, line, "/quit") or std.mem.eql(u8, line, "/q")) {
                    break;
                }

                if (std.mem.eql(u8, line, "/help") or std.mem.eql(u8, line, "/?") or std.mem.eql(u8, line, "help")) {
                    ui_mod.printTuiHelp(io, stdout, allocator);
                    continue;
                }

                if (std.mem.eql(u8, line, "/clear") or std.mem.eql(u8, line, "/cls") or std.mem.eql(u8, line, "clear") or std.mem.eql(u8, line, "cls")) {
                    stdout.writeStreamingAll(io, "\x1b[2J\x1b[H") catch {};
                    ui_mod.printTuiWelcome(io, stdout, allocator, active_model, stream_mode);
                    continue;
                }

                if (std.mem.eql(u8, line, "/stream")) {
                    stream_mode = !stream_mode;
                    const toast = try std.fmt.allocPrint(allocator, "✦ Streaming mode: {s}", .{if (stream_mode) "enabled" else "disabled"});
                    defer allocator.free(toast);
                    ui_mod.printTuiToast(io, stdout, allocator, toast);
                    continue;
                }

                if (std.mem.eql(u8, line, "/models")) {
                    ui_mod.printModelList(io, stdout, allocator, active_model);
                    continue;
                }

                if (std.mem.startsWith(u8, line, "/model") or std.mem.startsWith(u8, line, "/m ")) {
                    const prefix_len: usize = if (std.mem.startsWith(u8, line, "/model")) 6 else 3;
                    const raw_target = std.mem.trim(u8, line[prefix_len..], " \t=");
                    if (raw_target.len == 0) {
                        ui_mod.printModelList(io, stdout, allocator, active_model);
                    } else {
                        active_model = try allocator.dupe(u8, raw_target);
                        const toast = try std.fmt.allocPrint(allocator, "✦ Active model switched to: {s}", .{active_model});
                        defer allocator.free(toast);
                        ui_mod.printTuiToast(io, stdout, allocator, toast);
                    }
                    continue;
                }

                if (std.mem.eql(u8, line, "/history")) {
                    stdout.writeStreamingAll(io, "\n" ++ ui_mod.Colors.secondary ++ ui_mod.Colors.bold ++ "Session History:" ++ ui_mod.Colors.reset ++ "\n") catch {};
                    for (history.items, 0..) |h, idx| {
                        const h_line = try std.fmt.allocPrint(allocator, "  {d}. {s}{s}{s}\n", .{ idx + 1, ui_mod.Colors.text, h, ui_mod.Colors.reset });
                        defer allocator.free(h_line);
                        stdout.writeStreamingAll(io, h_line) catch {};
                    }
                    stdout.writeStreamingAll(io, "\n") catch {};
                    continue;
                }

                if (std.mem.eql(u8, line, "/copy") or std.mem.eql(u8, line, "/y") or std.mem.eql(u8, line, "copy")) {
                    if (last_response_text) |resp_text| {
                        runner_mod.copyToClipboard(io, stdout, allocator, resp_text);
                        ui_mod.printTuiToast(io, stdout, allocator, "✓ Copied full response to clipboard!");
                    } else {
                        ui_mod.printTuiToast(io, stdout, allocator, "⚠ No previous response to copy yet.");
                    }
                    continue;
                }

                if (std.mem.startsWith(u8, line, "/copy ") or std.mem.startsWith(u8, line, "/y ")) {
                    const space_idx = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
                    const key_arg = std.mem.trim(u8, line[space_idx + 1 ..], " \t");
                    if (key_arg.len > 0 and last_snippets.len > 0) {
                        const key_char = key_arg[0];
                        var found_snip: ?*const runner_mod.CodeSnippet = null;
                        for (last_snippets) |*s| {
                            if (s.key == key_char or (std.ascii.toLower(key_char) == s.key)) {
                                found_snip = s;
                                break;
                            }
                        }
                        if (found_snip == null and std.ascii.isDigit(key_char) and key_char >= '1') {
                            const idx: usize = key_char - '1';
                            if (idx < last_snippets.len) {
                                found_snip = &last_snippets[idx];
                            }
                        }
                        if (found_snip) |snip| {
                            runner_mod.copyToClipboard(io, stdout, allocator, snip.code);
                            const toast = try std.fmt.allocPrint(allocator, "✓ Copied snippet [{c}] to clipboard!", .{snip.key});
                            defer allocator.free(toast);
                            ui_mod.printTuiToast(io, stdout, allocator, toast);
                        } else {
                            ui_mod.printTuiToast(io, stdout, allocator, "⚠ Snippet key not found.");
                        }
                    } else {
                        ui_mod.printTuiToast(io, stdout, allocator, "⚠ No snippet available to copy.");
                    }
                    continue;
                }

                if (std.mem.startsWith(u8, line, "/run ") or std.mem.startsWith(u8, line, "/r ")) {
                    const space_idx = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
                    const key_arg = std.mem.trim(u8, line[space_idx + 1 ..], " \t");
                    if (key_arg.len > 0 and last_snippets.len > 0) {
                        const key_char = key_arg[0];
                        var found_snip: ?*const runner_mod.CodeSnippet = null;
                        for (last_snippets) |*s| {
                            if (s.key == key_char or (std.ascii.toLower(key_char) == s.key)) {
                                found_snip = s;
                                break;
                            }
                        }
                        if (found_snip == null and std.ascii.isDigit(key_char) and key_char >= '1') {
                            const idx: usize = key_char - '1';
                            if (idx < last_snippets.len) {
                                found_snip = &last_snippets[idx];
                            }
                        }
                        if (found_snip) |snip| {
                            const single_arr = [_]runner_mod.CodeSnippet{snip.*};
                            runner_mod.promptAndExecute(allocator, io, stdout, stdin, environ_map, &single_arr);
                        } else {
                            ui_mod.printTuiToast(io, stdout, allocator, "⚠ Snippet key not found.");
                        }
                    } else {
                        ui_mod.printTuiToast(io, stdout, allocator, "⚠ No snippet available to run.");
                    }
                    continue;
                }

                // 2. Query Gemini API
                var turn_arena = std.heap.ArenaAllocator.init(allocator);
                defer turn_arena.deinit();
                const turn_alloc = turn_arena.allocator();

                const t_start = Io.Timestamp.now(io, .awake);

                var spinner: ?ui_mod.Spinner = null;
                if (!stream_mode) {
                    spinner = ui_mod.Spinner.start(turn_alloc, "Thinking...") catch null;
                }

                var stream_ctx = StreamCtx{
                    .io = io,
                    .stdout = stdout,
                    .allocator = turn_alloc,
                    .should_style = stream_mode,
                    .is_tui = true,
                };
                var err_detail: ?api_mod.ApiErrorDetail = null;

                const response = api_mod.generateWithFallback(
                    turn_alloc,
                    io,
                    api_key,
                    active_model,
                    fallback_mode,
                    line,
                    system_instruction,
                    temperature,
                    thinking_budget,
                    if (stream_mode) handleStart else null,
                    if (stream_mode) handleChunk else null,
                    if (stream_mode) @ptrCast(&stream_ctx) else null,
                    &err_detail,
                ) catch |err| {
                    if (spinner) |*sp| sp.stop(turn_alloc);
                    if (err_detail) |ed| {
                        ui_mod.printErrorBox(io, stdout, turn_alloc, ed.title, ed.message, ed.suggestion);
                    } else {
                        const fallback_msg = try std.fmt.allocPrint(turn_alloc, "Failed to get response from Gemini ({})", .{err});
                        ui_mod.printErrorBox(io, stdout, turn_alloc, "Gemini Error", fallback_msg, null);
                    }
                    continue;
                };

                if (spinner) |*sp| sp.stop(turn_alloc);

                const t_end = Io.Timestamp.now(io, .awake);
                const elapsed: u64 = @intCast(@max(0, t_start.durationTo(t_end).toMilliseconds()));

                if (!stream_mode) {
                    ui_mod.printTuiResponseHeader(io, stdout, turn_alloc, response.model, response.is_fallback);
                    ui_mod.renderMarkdown(io, stdout, turn_alloc, response.text);
                } else {
                    try stdout.writeStreamingAll(io, ui_mod.Colors.reset);
                    if (!std.mem.endsWith(u8, response.text, "\n")) {
                        try stdout.writeStreamingAll(io, "\n");
                    }
                }
                ui_mod.printFooter(io, stdout, turn_alloc, elapsed, response.prompt_tokens, response.candidates_tokens, response.model);

                // Save last response and extract snippets
                if (last_response_text) |old| allocator.free(old);
                last_response_text = allocator.dupe(u8, response.text) catch null;

                for (last_snippets) |s| {
                    allocator.free(s.code);
                    allocator.free(s.lang);
                }
                if (last_snippets.len > 0) allocator.free(last_snippets);
                last_snippets = runner_mod.extractCodeSnippets(allocator, response.text);

                if (last_snippets.len > 0) {
                    ui_mod.printSnippetHint(io, stdout, allocator, last_snippets.len);
                }
            },
        }
    }
}
