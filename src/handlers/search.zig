const std = @import("std");
const common = @import("../types/common.zig");
const search_types = @import("../types/search.zig");
const app_state = @import("../app_state.zig");
const search_engine = @import("../search/engine.zig");
const queries = @import("../db/queries.zig");
const uuid_util = @import("../utils/uuid.zig");
const time_util = @import("../utils/time.zig");

const MAX_REQUEST_BODY_BYTES: usize = 1 * 1024 * 1024;
const MAX_QUERY_LEN: usize = 4096;

fn freeResponseBody(allocator: std.mem.Allocator, body: []const u8) void {
    allocator.free(body);
}

fn errorResponse(status: u16, message: []const u8, tag: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    var headers = std.StringHashMap([]const u8).init(allocator);
    errdefer headers.deinit();
    try headers.put("content-type", "application/json");
    try headers.put("access-control-allow-origin", "*");

    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const w = buf.writer();
    try w.writeAll("{\"error\":");
    try std.json.stringify(message, .{}, w);
    try w.writeAll(",\"tag\":");
    try std.json.stringify(tag, .{}, w);
    try w.writeAll("}");

    const body = try buf.toOwnedSlice();
    return common.HttpResponse{
        .status = status,
        .headers = headers,
        .body = body,
        .body_owned = true,
    };
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    try std.json.stringify(s, .{}, w);
}

fn isTruthyBool(v: std.json.Value) bool {
    return v == .bool and v.bool;
}

fn isPresentTruthy(v: ?std.json.Value) bool {
    if (v) |val| {
        return switch (val) {
            .bool => |b| b,
            .null => false,
            else => false,
        };
    }
    return false;
}

fn readOptionalBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

fn readBoolFromContentsObject(contents_obj: std.json.ObjectMap, key: []const u8, all_default: ?bool) ?bool {
    const v = contents_obj.get(key) orelse return all_default;
    return switch (v) {
        .bool => |b| b,
        .object => true,
        .null => null,
        else => null,
    };
}

fn parseContents(obj: std.json.ObjectMap) !?search_types.ContentsOptions {
    if (obj.get("contents")) |v| {
        switch (v) {
            .bool => |b| {
                if (b) {
                    return search_types.ContentsOptions{
                        .text = true,
                        .highlights = null,
                        .summary = null,
                    };
                }
                return null;
            },
            .object => |cobj| {
                return search_types.ContentsOptions{
                    .text = readBoolFromContentsObject(cobj, "text", null),
                    .highlights = readBoolFromContentsObject(cobj, "highlights", null),
                    .summary = readBoolFromContentsObject(cobj, "summary", null),
                };
            },
            .null => return null,
            else => return error.InvalidContents,
        }
    }

    const text_val = readOptionalBool(obj, "text");
    const highlights_val = readOptionalBool(obj, "highlights");
    const summary_val = readOptionalBool(obj, "summary");

    const has_any = obj.get("text") != null or obj.get("highlights") != null or obj.get("summary") != null;
    if (!has_any) return null;

    return search_types.ContentsOptions{
        .text = text_val,
        .highlights = highlights_val,
        .summary = summary_val,
    };
}

fn mapEngineErrorToHttp(err: anyerror, allocator: std.mem.Allocator) !common.HttpResponse {
    return switch (err) {
        error.OutOfMemory => errorResponse(503, "Service temporarily unavailable", "OUT_OF_MEMORY", allocator),
        error.Unauthorized => errorResponse(401, "Unauthorized", "UNAUTHORIZED", allocator),
        error.Forbidden => errorResponse(403, "Forbidden", "FORBIDDEN", allocator),
        error.RateLimited => errorResponse(429, "Rate limit exceeded", "RATE_LIMITED", allocator),
        error.UpstreamUnavailable, error.EmbeddingUnavailable, error.LlmUnavailable => errorResponse(502, "Upstream service unavailable", "UPSTREAM_UNAVAILABLE", allocator),
        error.Timeout => errorResponse(504, "Upstream timeout", "TIMEOUT", allocator),
        error.InvalidRequest => errorResponse(400, "Invalid request", "INVALID_REQUEST"[0..], allocator),
        else => errorResponse(500, "Internal server error", "INTERNAL_ERROR", allocator),
    };
}

pub fn handleSearch(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = queries;
    _ = uuid_util;

    if (req.body.len == 0) return errorResponse(400, "Empty request body", "INVALID_REQUEST_BODY", allocator);
    if (req.body.len > MAX_REQUEST_BODY_BYTES) return errorResponse(413, "Request body too large", "PAYLOAD_TOO_LARGE", allocator);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, req.body, .{ .allocate = .alloc_always }) catch {
        return errorResponse(400, "Invalid JSON", "INVALID_JSON", allocator);
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return errorResponse(400, "Request must be a JSON object", "INVALID_REQUEST_BODY", allocator);
    }
    const obj = parsed.value.object;

    const query_val_opt = obj.get("query") orelse obj.get("q");
    if (query_val_opt == null) {
        return errorResponse(400, "Missing required field: query", "MISSING_QUERY", allocator);
    }
    const query_val = query_val_opt.?;
    if (query_val != .string) {
        return errorResponse(400, "query must be a string", "INVALID_QUERY_TYPE", allocator);
    }
    const query_src = query_val.string;
    if (query_src.len == 0) {
        return errorResponse(400, "query cannot be empty", "EMPTY_QUERY", allocator);
    }
    if (query_src.len > MAX_QUERY_LEN) {
        return errorResponse(400, "query exceeds maximum length", "QUERY_TOO_LONG", allocator);
    }

    const query_owned = try allocator.dupe(u8, query_src);
    defer allocator.free(query_owned);

    const num_results: usize = blk: {
        const nr_opt = obj.get("numResults") orelse obj.get("num_results");
        if (nr_opt) |v| {
            switch (v) {
                .integer => |i| {
                    if (i < 1) {
                        break :blk 1;
                    }
                    const i_u: u64 = @intCast(i);
                    const max_u: u64 = @as(u64, state.cfg.max_search_results);
                    const clamped: u64 = if (i_u > max_u) max_u else i_u;
                    break :blk @as(usize, @intCast(clamped));
                },
                .float => |f| {
                    if (f < 1.0) {
                        break :blk 1;
                    }
                    const max_f: f64 = @floatFromInt(state.cfg.max_search_results);
                    const clamped_f: f64 = if (f > max_f) max_f else f;
                    break :blk @as(usize, @intFromFloat(clamped_f));
                },
                else => return errorResponse(400, "numResults must be a number", "INVALID_NUM_RESULTS", allocator),
            }
        }
        break :blk @as(usize, state.cfg.default_search_results);
    };

    var resolved_search_type_owned: []u8 = undefined;
    var has_resolved_str = false;
    defer if (has_resolved_str) allocator.free(resolved_search_type_owned);

    const search_type: search_types.SearchType = blk: {
        const t_opt = obj.get("type") orelse obj.get("searchType");
        if (t_opt) |v| {
            if (v != .string) {
                return errorResponse(400, "type must be a string", "INVALID_SEARCH_TYPE", allocator);
            }
            const parsed_type = std.meta.stringToEnum(search_types.SearchType, v.string);
            if (parsed_type == null) {
                return errorResponse(400, "Unknown search type", "UNKNOWN_SEARCH_TYPE", allocator);
            }
            resolved_search_type_owned = try allocator.dupe(u8, v.string);
            has_resolved_str = true;
            break :blk parsed_type.?;
        }
        resolved_search_type_owned = try allocator.dupe(u8, "auto");
        has_resolved_str = true;
        break :blk .auto;
    };

    const category: ?search_types.Category = blk: {
        const v_opt = obj.get("category");
        if (v_opt) |v| {
            if (v == .null) break :blk null;
            if (v != .string) {
                return errorResponse(400, "category must be a string", "INVALID_CATEGORY_TYPE", allocator);
            }
            const cat = std.meta.stringToEnum(search_types.Category, v.string);
            if (cat == null) {
                return errorResponse(400, "Unknown category", "UNKNOWN_CATEGORY", allocator);
            }
            break :blk cat.?;
        }
        break :blk null;
    };

    const contents_opts: ?search_types.ContentsOptions = parseContents(obj) catch |e| switch (e) {
        error.InvalidContents => return errorResponse(400, "contents must be an object or boolean", "INVALID_CONTENTS", allocator),
        else => return e,
    };

    const search_req = search_types.SearchRequest{
        .query = query_owned,
        .type = search_type,
        .num_results = num_results,
        .category = category,
        .contents = contents_opts,
    };

    const start_time = time_util.nowMillis();

    var engine = search_engine.SearchEngine{
        .cfg = state.cfg,
        .pg_pool = state.pg_pool,
        .redis_pool = state.redis_pool,
        .hnsw_index = state.hnsw_index,
        .embedding_client = state.embedding_client,
        .llm_client = state.llm_client,
    };

    var response = engine.search(&search_req, auth, allocator) catch |err| {
        std.log.err("engine.search failed: {s}", .{@errorName(err)});
        return mapEngineErrorToHttp(err, allocator);
    };
    defer response.deinit(allocator);

    const end_time = time_util.nowMillis();
    const elapsed_raw: i64 = end_time - start_time;
    const elapsed_nonneg: i64 = if (elapsed_raw < 0) 0 else elapsed_raw;
    const search_time_ms: u64 = @intCast(elapsed_nonneg);

    var body = std.ArrayList(u8).init(allocator);
    errdefer body.deinit();
    const w = body.writer();

    try w.writeAll("{\"requestId\":");
    try writeJsonString(w, response.request_id);
    try w.writeAll(",\"resolvedSearchType\":");
    const resolved_engine_str: []const u8 = if (response.resolved_search_type) |rt| @tagName(rt) else resolved_search_type_owned;
    try writeJsonString(w, resolved_engine_str);

    if (response.autoprompt_string) |aps| {
        try w.writeAll(",\"autopromptString\":");
        try writeJsonString(w, aps);
    }

    try w.writeAll(",\"results\":[");
    for (response.results, 0..) |result, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"id\":");
        try writeJsonString(w, result.id);
        try w.writeAll(",\"url\":");
        try writeJsonString(w, result.url);
        if (result.title) |t| {
            try w.writeAll(",\"title\":");
            try writeJsonString(w, t);
        }
        if (result.score) |s| {
            try w.print(",\"score\":{d:.6}", .{@as(f64, s)});
        }
        if (result.author) |a| {
            try w.writeAll(",\"author\":");
            try writeJsonString(w, a);
        }
        if (result.favicon) |f| {
            try w.writeAll(",\"favicon\":");
            try writeJsonString(w, f);
        }
        if (result.published_date) |pd| {
            try w.writeAll(",\"publishedDate\":");
            try writeJsonString(w, pd);
        }
        if (result.image) |img| {
            try w.writeAll(",\"image\":");
            try writeJsonString(w, img);
        }
        if (result.text) |t| {
            try w.writeAll(",\"text\":");
            try writeJsonString(w, t);
        }
        if (result.highlights) |hs| {
            try w.writeAll(",\"highlights\":[");
            for (hs, 0..) |h, hi| {
                if (hi > 0) try w.writeAll(",");
                try writeJsonString(w, h);
            }
            try w.writeAll("]");
        }
        if (result.summary) |sm| {
            try w.writeAll(",\"summary\":");
            try writeJsonString(w, sm);
        }
        try w.writeAll("}");
    }
    try w.writeAll("],\"searchTime\":");
    try w.print("{d}", .{search_time_ms});
    try w.writeAll(",\"costDollars\":{\"total\":0.0000}}");

    var headers = std.StringHashMap([]const u8).init(allocator);
    errdefer headers.deinit();
    try headers.put("content-type", "application/json; charset=utf-8");
    try headers.put("access-control-allow-origin", "*");
    try headers.put("x-request-id", response.request_id);

    const body_slice = try body.toOwnedSlice();
    errdefer allocator.free(body_slice);

    return common.HttpResponse{
        .status = 200,
        .headers = headers,
        .body = body_slice,
        .body_owned = true,
    };
}

pub fn handleContext(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;

    var headers = std.StringHashMap([]const u8).init(allocator);
    errdefer headers.deinit();
    try headers.put("content-type", "application/json; charset=utf-8");
    try headers.put("access-control-allow-origin", "*");

    const literal = "{\"context\":\"\",\"contextSnippets\":[]}";
    const body = try allocator.dupe(u8, literal);
    errdefer allocator.free(body);

    return common.HttpResponse{
        .status = 200,
        .headers = headers,
        .body = body,
        .body_owned = true,
    };
}
