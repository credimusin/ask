const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const File = std.Io.File;
const http = std.http;

var original_netLookup: *const fn(
    ?*anyopaque,
    Io.net.HostName,
    *Io.Queue(Io.net.HostName.LookupResult),
    Io.net.HostName.LookupOptions
) Io.net.HostName.LookupError!void = undefined;
var custom_vtable: Io.VTable = undefined;
var vtable_initialized: bool = false;

fn forceIp4NetLookup(
    userdata: ?*anyopaque,
    host_name: Io.net.HostName,
    resolved: *Io.Queue(Io.net.HostName.LookupResult),
    options: Io.net.HostName.LookupOptions,
) Io.net.HostName.LookupError!void {
    var new_options = options;
    new_options.family = .ip4;
    return original_netLookup(userdata, host_name, resolved, new_options);
}

pub const ApiResponse = struct {
    text: []const u8,
    model: []const u8,
    prompt_tokens: ?i64 = null,
    candidates_tokens: ?i64 = null,
    is_fallback: bool = false,
};

pub const ApiErrorDetail = struct {
    status_code: ?u16 = null,
    title: []const u8,
    message: []const u8,
    suggestion: ?[]const u8 = null,
};

pub const ApiError = error{
    MissingApiKey,
    NetworkError,
    HttpError,
    ApiErrorResponse,
    InvalidJsonResponse,
    NoCandidates,
};

pub fn jsonEscape(allocator: Allocator, text: []const u8) ![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    const hex_digits = "0123456789abcdef";

    for (text) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            0x08 => try list.appendSlice(allocator, "\\b"),
            0x0C => try list.appendSlice(allocator, "\\f"),
            else => {
                if (c < 0x20) {
                    const esc = [_]u8{ '\\', 'u', '0', '0', hex_digits[c >> 4], hex_digits[c & 0x0F] };
                    try list.appendSlice(allocator, &esc);
                } else {
                    try list.append(allocator, c);
                }
            },
        }
    }
    return try list.toOwnedSlice(allocator);
}

pub fn modelSupportsThinking(model: []const u8) bool {
    // Models that do NOT support thinkingConfig / thinkingBudget:
    if (std.mem.indexOf(u8, model, "lite") != null) return false;
    if (std.mem.indexOf(u8, model, "gemma") != null) return false;
    if (std.mem.indexOf(u8, model, "embedding") != null) return false;
    if (std.mem.indexOf(u8, model, "transcribe") != null) return false;
    if (std.mem.indexOf(u8, model, "tts") != null) return false;
    if (std.mem.indexOf(u8, model, "veo") != null) return false;
    if (std.mem.indexOf(u8, model, "lyria") != null) return false;
    if (std.mem.indexOf(u8, model, "1.5") != null or std.mem.indexOf(u8, model, "1.0") != null) return false;
    if (std.mem.indexOf(u8, model, "aqa") != null or std.mem.indexOf(u8, model, "robotics") != null) return false;
    if (std.mem.indexOf(u8, model, "computer-use") != null) return false;

    // Models known to support thinkingConfig:
    if (std.mem.indexOf(u8, model, "gemini-2.5") != null) return true;
    if (std.mem.indexOf(u8, model, "gemini-3") != null) return true;
    if (std.mem.indexOf(u8, model, "thinking") != null) return true;

    return false;
}

pub fn modelSupportsSystemInstruction(model: []const u8) bool {
    // Gemma 2 does not support systemInstruction in Gemini API v1beta
    if (std.mem.indexOf(u8, model, "gemma-2") != null) return false;
    if (std.mem.indexOf(u8, model, "embedding") != null) return false;
    if (std.mem.indexOf(u8, model, "transcribe") != null) return false;
    return true;
}

pub fn buildPayload(
    allocator: Allocator,
    model: []const u8,
    prompt: []const u8,
    system_instruction: ?[]const u8,
    temperature: f64,
    thinking_budget: ?i32,
) ![]const u8 {
    const supports_thinking = modelSupportsThinking(model);
    const supports_sys = modelSupportsSystemInstruction(model);

    var final_prompt = prompt;
    var allocated_prompt: ?[]const u8 = null;
    defer if (allocated_prompt) |p| allocator.free(p);

    var actual_sys_instruction: ?[]const u8 = null;

    if (system_instruction) |sys| {
        if (supports_sys) {
            actual_sys_instruction = sys;
        } else {
            allocated_prompt = try std.fmt.allocPrint(allocator, "[Instruction: {s}]\n\n{s}", .{ sys, prompt });
            final_prompt = allocated_prompt.?;
        }
    }

    const escaped_prompt = try jsonEscape(allocator, final_prompt);
    defer allocator.free(escaped_prompt);

    var gen_config_str: []const u8 = undefined;
    if (supports_thinking and thinking_budget != null) {
        gen_config_str = try std.fmt.allocPrint(
            allocator,
            \\"generationConfig": {{
            \\    "temperature": {d:.2},
            \\    "thinkingConfig": {{
            \\      "thinkingBudget": {d}
            \\    }}
            \\  }}
        ,
            .{ temperature, thinking_budget.? },
        );
    } else {
        gen_config_str = try std.fmt.allocPrint(
            allocator,
            \\"generationConfig": {{
            \\    "temperature": {d:.2}
            \\  }}
        ,
            .{temperature},
        );
    }
    defer allocator.free(gen_config_str);

    if (actual_sys_instruction) |sys| {
        const escaped_sys = try jsonEscape(allocator, sys);
        defer allocator.free(escaped_sys);
        return try std.fmt.allocPrint(
            allocator,
            \\{{
            \\  "contents": [
            \\    {{
            \\      "role": "user",
            \\      "parts": [{{"text": "{s}"}}]
            \\    }}
            \\  ],
            \\  "systemInstruction": {{
            \\    "parts": [{{"text": "{s}"}}]
            \\  }},
            \\  {s}
            \\}}
        ,
            .{ escaped_prompt, escaped_sys, gen_config_str },
        );
    } else {
        return try std.fmt.allocPrint(
            allocator,
            \\{{
            \\  "contents": [
            \\    {{
            \\      "role": "user",
            \\      "parts": [{{"text": "{s}"}}]
            \\    }}
            \\  ],
            \\  {s}
            \\}}
        ,
            .{ escaped_prompt, gen_config_str },
        );
    }
}

pub const ChunkCallback = *const fn (ctx: *anyopaque, text: []const u8) void;
pub const OnStartCallback = *const fn (ctx: *anyopaque, model_used: []const u8, is_fallback: bool) void;

pub const DEFAULT_FALLBACK_MODELS = [_][]const u8{
    "gemini-3.5-flash",
    "gemini-3.5-flash-lite",
    "gemini-2.5-flash",
    "gemini-2.5-flash-lite",
    "gemma-4-31b-it",
};

pub fn isFallbackEligibleError(status_code: ?u16) bool {
    if (status_code) |code| {
        return code == 503 or code == 429 or code == 500 or code == 502 or code == 504 or code == 404;
    }
    return true;
}

fn parseRetrySeconds(msg: []const u8) ?u64 {
    const pattern = "Please retry in ";
    if (std.mem.indexOf(u8, msg, pattern)) |idx| {
        const after = msg[idx + pattern.len ..];
        var end_idx: usize = 0;
        while (end_idx < after.len and (std.ascii.isDigit(after[end_idx]) or after[end_idx] == '.')) : (end_idx += 1) {}
        if (end_idx > 0) {
            const num_str = after[0..end_idx];
            if (std.fmt.parseFloat(f64, num_str)) |val| {
                return @intFromFloat(@ceil(val));
            } else |_| {}
        }
    }
    return null;
}

pub fn generateContentStream(
    allocator: Allocator,
    io: Io,
    api_key: []const u8,
    model: []const u8,
    prompt: []const u8,
    system_instruction: ?[]const u8,
    temperature: f64,
    thinking_budget: ?i32,
    is_fallback: bool,
    on_start: ?OnStartCallback,
    on_chunk: ?ChunkCallback,
    ctx_ptr: ?*anyopaque,
    error_detail_out: ?*?ApiErrorDetail,
) !ApiResponse {
    if (error_detail_out) |out| out.* = null;

    if (!vtable_initialized) {
        original_netLookup = io.vtable.netLookup;
        custom_vtable = io.vtable.*;
        custom_vtable.netLookup = forceIp4NetLookup;
        vtable_initialized = true;
    }
    const custom_io = Io{
        .userdata = io.userdata,
        .vtable = &custom_vtable,
    };

    var client = http.Client{ .allocator = allocator, .io = custom_io };
    defer client.deinit();

    const url_str = try std.fmt.allocPrint(
        allocator,
        "https://generativelanguage.googleapis.com/v1beta/models/{s}:streamGenerateContent?alt=sse&key={s}",
        .{ model, api_key },
    );
    defer allocator.free(url_str);

    const uri = std.Uri.parse(url_str) catch {
        if (error_detail_out) |out| {
            out.* = ApiErrorDetail{
                .title = "Network / URI Error",
                .message = "Failed to construct valid Gemini API request URI.",
                .suggestion = "Verify your model name configuration.",
            };
        }
        return error.NetworkError;
    };

    const payload = buildPayload(allocator, model, prompt, system_instruction, temperature, thinking_budget) catch {
        if (error_detail_out) |out| {
            out.* = ApiErrorDetail{
                .title = "Payload Construction Error",
                .message = "Failed to serialize JSON payload for the prompt.",
            };
        }
        return error.InvalidJsonResponse;
    };
    defer allocator.free(payload);

    const extra_headers = [_]http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    };

    var req = client.request(.POST, uri, .{
        .extra_headers = &extra_headers,
    }) catch {
        if (error_detail_out) |out| {
            out.* = ApiErrorDetail{
                .title = "Network Connection Failed",
                .message = "Unable to connect to Google Gemini API servers.",
                .suggestion = "Check your internet connection, proxy, or DNS settings.",
            };
        }
        return error.NetworkError;
    };
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = payload.len };
    var body = req.sendBodyUnflushed(&.{}) catch {
        if (error_detail_out) |out| {
            out.* = ApiErrorDetail{
                .title = "Network Transfer Error",
                .message = "Failed to send request body to Gemini API.",
                .suggestion = "Check your connection stability.",
            };
        }
        return error.NetworkError;
    };
    body.writer.writeAll(payload) catch return error.NetworkError;
    body.end() catch return error.NetworkError;
    if (req.connection) |*conn| {
        conn.*.flush() catch return error.NetworkError;
    }

    var redirect_buf: [4096]u8 = undefined;
    var resp = req.receiveHead(&redirect_buf) catch {
        if (error_detail_out) |out| {
            out.* = ApiErrorDetail{
                .title = "Network Timeout / Error",
                .message = "Did not receive HTTP response headers from Gemini API.",
                .suggestion = "Check if Google API is reachable from your network.",
            };
        }
        return error.NetworkError;
    };

    if (resp.head.status != .ok) {
        var err_reader = resp.reader(&.{});
        var err_buf: [4096]u8 = undefined;
        const amt = err_reader.readSliceShort(&err_buf) catch 0;
        const err_slice = err_buf[0..amt];

        const status_code: u16 = @intFromEnum(resp.head.status);
        var raw_msg: ?[]const u8 = null;
        var err_status: ?[]const u8 = null;

        var err_arena = std.heap.ArenaAllocator.init(allocator);
        defer err_arena.deinit();
        if (std.json.parseFromSlice(std.json.Value, err_arena.allocator(), err_slice, .{})) |parsed| {
            if (parsed.value == .object) {
                if (parsed.value.object.get("error")) |e_obj| {
                    if (e_obj == .object) {
                        if (e_obj.object.get("message")) |m_val| {
                            if (m_val == .string and m_val.string.len > 0) {
                                raw_msg = m_val.string;
                            }
                        }
                        if (e_obj.object.get("status")) |s_val| {
                            if (s_val == .string) {
                                err_status = s_val.string;
                            }
                        }
                    }
                }
            }
        } else |_| {}

        if (status_code == 429 or (err_status != null and std.mem.eql(u8, err_status.?, "RESOURCE_EXHAUSTED"))) {
            var msg_formatted: []const u8 = "You exceeded your current Gemini API quota / rate limit.";
            if (raw_msg) |m| {
                if (parseRetrySeconds(m)) |sec| {
                    msg_formatted = try std.fmt.allocPrint(allocator, "Quota limit exceeded for {s}. Please retry in ~{d}s.", .{ model, sec });
                } else {
                    msg_formatted = try std.fmt.allocPrint(allocator, "Quota limit exceeded for model {s}.", .{model});
                }
            }

            if (error_detail_out) |out| {
                out.* = ApiErrorDetail{
                    .status_code = 429,
                    .title = "Rate Limit / Quota Exceeded (HTTP 429)",
                    .message = msg_formatted,
                    .suggestion = "Switch models: ask -m gemini-2.0-flash \"...\" or check: https://aistudio.google.com/app/plan_information",
                };
            }
            return error.HttpError;
        }

        if (status_code == 400) {
            const is_invalid_key = if (raw_msg) |m| (std.mem.indexOf(u8, m, "API key not valid") != null or std.mem.indexOf(u8, m, "API_KEY_INVALID") != null) else false;

            if (is_invalid_key) {
                if (error_detail_out) |out| {
                    out.* = ApiErrorDetail{
                        .status_code = 400,
                        .title = "Invalid API Key (HTTP 400)",
                        .message = "The provided Gemini API key is not valid or has been revoked.",
                        .suggestion = "Save a new key: ask --key \"AIzaSy...\" (Get key at https://aistudio.google.com/app/apikey)",
                    };
                }
            } else {
                if (error_detail_out) |out| {
                    out.* = ApiErrorDetail{
                        .status_code = 400,
                        .title = "Bad Request (HTTP 400)",
                        .message = if (raw_msg) |m| try allocator.dupe(u8, m) else "The API rejected the request parameters.",
                        .suggestion = "Check your prompt or model configuration.",
                    };
                }
            }
            return error.HttpError;
        }

        if (status_code == 403) {
            if (error_detail_out) |out| {
                out.* = ApiErrorDetail{
                    .status_code = 403,
                    .title = "Access Forbidden (HTTP 403)",
                    .message = if (raw_msg) |m| try allocator.dupe(u8, m) else "API key does not have permission for this resource or region.",
                    .suggestion = "Ensure Gemini API is enabled in your Google Cloud / AI Studio project.",
                };
            }
            return error.HttpError;
        }

        if (status_code == 404) {
            if (error_detail_out) |out| {
                out.* = ApiErrorDetail{
                    .status_code = 404,
                    .title = "Model Not Found (HTTP 404)",
                    .message = try std.fmt.allocPrint(allocator, "Model '{s}' was not found or is not supported.", .{model}),
                    .suggestion = "Use a supported model, e.g.: ask -m gemini-2.5-flash",
                };
            }
            return error.HttpError;
        }

        if (status_code >= 500) {
            if (error_detail_out) |out| {
                out.* = ApiErrorDetail{
                    .status_code = status_code,
                    .title = try std.fmt.allocPrint(allocator, "Gemini Server Error (HTTP {d})", .{status_code}),
                    .message = "Google Gemini servers are currently experiencing issues or high load.",
                    .suggestion = "Please wait a few moments and try your query again.",
                };
            }
            return error.HttpError;
        }

        // Generic HTTP error
        if (error_detail_out) |out| {
            out.* = ApiErrorDetail{
                .status_code = status_code,
                .title = try std.fmt.allocPrint(allocator, "Gemini API Error (HTTP {d})", .{status_code}),
                .message = if (raw_msg) |m| try allocator.dupe(u8, m) else "Unexpected response from Gemini API.",
                .suggestion = "Run ask -c to verify configuration or check your network.",
            };
        }
        return error.HttpError;
    }

    if (on_start) |start_cb| {
        if (ctx_ptr) |ctx| {
            start_cb(ctx, model, is_fallback);
        }
    }

    var r = resp.reader(&.{});
    var total_text: std.ArrayList(u8) = .empty;
    errdefer total_text.deinit(allocator);

    var prompt_tokens: ?i64 = null;
    var candidates_tokens: ?i64 = null;

    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(allocator);

    var read_buf: [1024]u8 = undefined;

    while (true) {
        const amt = r.readSliceShort(&read_buf) catch break;
        if (amt == 0) break;

        for (read_buf[0..amt]) |byte| {
            if (byte == '\n') {
                const line = std.mem.trim(u8, line_buf.items, "\r");
                if (std.mem.startsWith(u8, line, "data: ")) {
                    const json_data = line[6..];
                    var arena = std.heap.ArenaAllocator.init(allocator);
                    defer arena.deinit();
                    const arena_alloc = arena.allocator();

                    if (std.json.parseFromSlice(std.json.Value, arena_alloc, json_data, .{})) |parsed| {
                        if (parsed.value == .object) {
                            // Check API error in stream
                            if (parsed.value.object.get("error")) |api_err| {
                                if (api_err == .object) {
                                    var stream_err_msg: []const u8 = "An error occurred during streaming.";
                                    if (api_err.object.get("message")) |msg_val| {
                                        if (msg_val == .string) {
                                            stream_err_msg = msg_val.string;
                                        }
                                    }
                                    if (error_detail_out) |out| {
                                        out.* = ApiErrorDetail{
                                            .title = "Stream Generation Error",
                                            .message = try allocator.dupe(u8, stream_err_msg),
                                            .suggestion = "Retry your request or switch model.",
                                        };
                                    }
                                    return error.ApiErrorResponse;
                                }
                            }

                            // Check usageMetadata
                            if (parsed.value.object.get("usageMetadata")) |usage| {
                                if (usage == .object) {
                                    if (usage.object.get("promptTokenCount")) |pt| {
                                        if (pt == .integer) prompt_tokens = pt.integer;
                                    }
                                    if (usage.object.get("candidatesTokenCount")) |ct| {
                                        if (ct == .integer) candidates_tokens = ct.integer;
                                    }
                                }
                            }

                            // Extract text chunk (excluding thought scratchpad)
                            if (parsed.value.object.get("candidates")) |cands| {
                                if (cands == .array and cands.array.items.len > 0) {
                                    const first = cands.array.items[0];
                                    if (first == .object) {
                                        if (first.object.get("content")) |content| {
                                            if (content == .object) {
                                                if (content.object.get("parts")) |parts| {
                                                    if (parts == .array) {
                                                        for (parts.array.items) |part| {
                                                            if (part == .object) {
                                                                if (part.object.get("thought")) |th| {
                                                                    if (th == .bool and th.bool) continue;
                                                                }

                                                                if (part.object.get("text")) |t_val| {
                                                                    if (t_val == .string and t_val.string.len > 0) {
                                                                        try total_text.appendSlice(allocator, t_val.string);
                                                                        if (on_chunk) |cb| {
                                                                            if (ctx_ptr) |ctx| {
                                                                                cb(ctx, t_val.string);
                                                                            }
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    } else |_| {}
                }
                line_buf.clearRetainingCapacity();
            } else {
                try line_buf.append(allocator, byte);
            }
        }
    }

    if (total_text.items.len == 0) {
        if (error_detail_out) |out| {
            out.* = ApiErrorDetail{
                .title = "Empty Model Response",
                .message = "The model did not return any candidates or response text.",
                .suggestion = "The request may have triggered content safety filters, or prompt was empty.",
            };
        }
        return error.NoCandidates;
    }

    return ApiResponse{
        .text = try total_text.toOwnedSlice(allocator),
        .model = try allocator.dupe(u8, model),
        .prompt_tokens = prompt_tokens,
        .candidates_tokens = candidates_tokens,
        .is_fallback = is_fallback,
    };
}

pub fn generateWithFallback(
    allocator: Allocator,
    io: Io,
    api_key: []const u8,
    primary_model: []const u8,
    fallback_enabled: bool,
    prompt: []const u8,
    system_instruction: ?[]const u8,
    temperature: f64,
    thinking_budget: ?i32,
    on_start: ?OnStartCallback,
    on_chunk: ?ChunkCallback,
    ctx_ptr: ?*anyopaque,
    error_detail_out: ?*?ApiErrorDetail,
) !ApiResponse {
    var models_to_try: std.ArrayList([]const u8) = .empty;
    defer models_to_try.deinit(allocator);

    try models_to_try.append(allocator, primary_model);

    if (fallback_enabled) {
        for (DEFAULT_FALLBACK_MODELS) |fb_model| {
            var already_present = false;
            for (models_to_try.items) |m| {
                if (std.mem.eql(u8, m, fb_model)) {
                    already_present = true;
                    break;
                }
            }
            if (!already_present) {
                try models_to_try.append(allocator, fb_model);
            }
        }
    }

    var last_err: anyerror = error.HttpError;
    var is_first = true;

    for (models_to_try.items) |current_model| {
        const is_fallback = !is_first;
        is_first = false;

        const res = generateContentStream(
            allocator,
            io,
            api_key,
            current_model,
            prompt,
            system_instruction,
            temperature,
            thinking_budget,
            is_fallback,
            on_start,
            on_chunk,
            ctx_ptr,
            error_detail_out,
        );

        if (res) |api_resp| {
            return api_resp;
        } else |err| {
            last_err = err;
            if (error_detail_out) |out| {
                if (out.*) |detail| {
                    if (!isFallbackEligibleError(detail.status_code)) {
                        return err;
                    }
                }
            }
            continue;
        }
    }

    return last_err;
}
