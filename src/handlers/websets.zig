const std = @import("std");
const common = @import("../types/common.zig");
const app_state = @import("../app_state.zig");
const queries = @import("../db/queries.zig");
const uuid_util = @import("../utils/uuid.zig");
const time_util = @import("../utils/time.zig");
const webhooks = @import("../webhooks/dispatcher.zig");
const crypto = @import("../utils/crypto.zig");

const MAX_REQUEST_BODY_BYTES: usize = 1 * 1024 * 1024;
const MAX_URL_LEN: usize = 2048;
const MAX_ID_LEN: usize = 256;

fn jsonEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    try std.json.stringify(s, .{}, buf.writer());
    return buf.toOwnedSlice();
}

fn writeJsonStr(w: anytype, s: []const u8) !void {
    try std.json.stringify(s, .{}, w);
}

fn defaultHeaders(allocator: std.mem.Allocator) !std.StringHashMap([]const u8) {
    var h = std.StringHashMap([]const u8).init(allocator);
    errdefer h.deinit();
    try h.put("content-type", "application/json; charset=utf-8");
    try h.put("access-control-allow-origin", "*");
    try h.put("cache-control", "no-store");
    return h;
}

fn jAlloc(status: u16, body_owned: []u8, allocator: std.mem.Allocator) !common.HttpResponse {
    var h = try defaultHeaders(allocator);
    errdefer h.deinit();
    return common.HttpResponse{
        .status = status,
        .headers = h,
        .body = body_owned,
        .body_owned = true,
    };
}

fn jLit(status: u16, literal: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    const body = try allocator.dupe(u8, literal);
    errdefer allocator.free(body);
    var h = try defaultHeaders(allocator);
    errdefer h.deinit();
    return common.HttpResponse{
        .status = status,
        .headers = h,
        .body = body,
        .body_owned = true,
    };
}

fn jFmt(status: u16, allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !common.HttpResponse {
    const body = try std.fmt.allocPrint(allocator, fmt, args);
    errdefer allocator.free(body);
    var h = try defaultHeaders(allocator);
    errdefer h.deinit();
    return common.HttpResponse{
        .status = status,
        .headers = h,
        .body = body,
        .body_owned = true,
    };
}

fn jError(status: u16, message: []const u8, tag: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const w = buf.writer();
    try w.writeAll("{\"error\":");
    try writeJsonStr(w, message);
    try w.writeAll(",\"tag\":");
    try writeJsonStr(w, tag);
    try w.writeAll("}");
    const body = try buf.toOwnedSlice();
    errdefer allocator.free(body);
    var h = try defaultHeaders(allocator);
    errdefer h.deinit();
    return common.HttpResponse{
        .status = status,
        .headers = h,
        .body = body,
        .body_owned = true,
    };
}

fn mapDbError(err: anyerror, allocator: std.mem.Allocator) !common.HttpResponse {
    return switch (err) {
        error.OutOfMemory => jError(503, "Service temporarily unavailable", "OUT_OF_MEMORY", allocator),
        error.ConnectionFailed, error.ConnectionResetByPeer => jError(503, "Database unavailable", "DB_UNAVAILABLE", allocator),
        error.Timeout => jError(504, "Database timeout", "DB_TIMEOUT", allocator),
        else => jError(500, "Internal server error", "INTERNAL_ERROR", allocator),
    };
}

fn validateIdParam(id: []const u8, allocator: std.mem.Allocator) !?common.HttpResponse {
    if (id.len == 0) return try jError(400, "Empty id parameter", "INVALID_ID", allocator);
    if (id.len > MAX_ID_LEN) return try jError(400, "Id parameter too long", "ID_TOO_LONG", allocator);
    for (id) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '-' or c == '_';
        if (!ok) return try jError(400, "Invalid id characters", "INVALID_ID", allocator);
    }
    return null;
}

fn validateUrl(url: []const u8) bool {
    if (url.len == 0) return false;
    if (url.len > MAX_URL_LEN) return false;
    const https_prefix = "https://";
    const http_prefix = "http://";
    if (url.len >= https_prefix.len and std.mem.eql(u8, url[0..https_prefix.len], https_prefix)) return true;
    if (url.len >= http_prefix.len and std.mem.eql(u8, url[0..http_prefix.len], http_prefix)) return true;
    return false;
}

fn parseRequestBody(req: *const common.HttpRequest, allocator: std.mem.Allocator) !?std.json.Parsed(std.json.Value) {
    if (req.body.len == 0) return null;
    if (req.body.len > MAX_REQUEST_BODY_BYTES) return error.PayloadTooLarge;
    return try std.json.parseFromSlice(std.json.Value, allocator, req.body, .{ .allocate = .alloc_always });
}

pub fn createWebset(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    const id = uuid_util.generate();
    const id_str = try uuid_util.toString(id, allocator);
    defer allocator.free(id_str);
    const id_json = try jsonEscape(allocator, id_str);
    defer allocator.free(id_json);
    const ts: i64 = time_util.nowMillis();
    return try jFmt(201, allocator,
        "{{\"id\":{s},\"object\":\"webset\",\"status\":\"idle\",\"createdAt\":{d},\"updatedAt\":{d}}}",
        .{ id_json, ts, ts });
}

pub fn previewWebset(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    return try jLit(200, "{\"items\":[],\"hasMore\":false}", allocator);
}

pub fn listWebsets(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    return try jLit(200, "{\"data\":[],\"hasMore\":false}", allocator);
}

pub fn getWebset(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, webset_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    if (try validateIdParam(webset_id, allocator)) |resp| return resp;
    const id_json = try jsonEscape(allocator, webset_id);
    defer allocator.free(id_json);
    const ts: i64 = time_util.nowMillis();
    return try jFmt(200, allocator,
        "{{\"id\":{s},\"object\":\"webset\",\"status\":\"idle\",\"updatedAt\":{d}}}",
        .{ id_json, ts });
}

pub fn updateWebset(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, webset_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    if (try validateIdParam(webset_id, allocator)) |resp| return resp;
    const id_json = try jsonEscape(allocator, webset_id);
    defer allocator.free(id_json);
    const ts: i64 = time_util.nowMillis();
    return try jFmt(200, allocator,
        "{{\"id\":{s},\"object\":\"webset\",\"status\":\"idle\",\"updatedAt\":{d}}}",
        .{ id_json, ts });
}

pub fn deleteWebset(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, webset_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    if (try validateIdParam(webset_id, allocator)) |resp| return resp;
    const id_json = try jsonEscape(allocator, webset_id);
    defer allocator.free(id_json);
    const ts: i64 = time_util.nowMillis();
    return try jFmt(200, allocator,
        "{{\"id\":{s},\"object\":\"webset\",\"deleted\":true,\"deletedAt\":{d}}}",
        .{ id_json, ts });
}

pub fn cancelWebset(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, webset_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    if (try validateIdParam(webset_id, allocator)) |resp| return resp;
    const id_json = try jsonEscape(allocator, webset_id);
    defer allocator.free(id_json);
    const ts: i64 = time_util.nowMillis();
    return try jFmt(200, allocator,
        "{{\"id\":{s},\"object\":\"webset\",\"status\":\"idle\",\"canceledAt\":{d}}}",
        .{ id_json, ts });
}

pub fn createSearch(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, webset_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    if (try validateIdParam(webset_id, allocator)) |resp| return resp;
    const id = uuid_util.generate();
    const id_str = try uuid_util.toString(id, allocator);
    defer allocator.free(id_str);
    const id_json = try jsonEscape(allocator, id_str);
    defer allocator.free(id_json);
    const ws_json = try jsonEscape(allocator, webset_id);
    defer allocator.free(ws_json);
    const ts: i64 = time_util.nowMillis();
    return try jFmt(201, allocator,
        "{{\"id\":{s},\"object\":\"webset_search\",\"websetId\":{s},\"status\":\"created\",\"createdAt\":{d}}}",
        .{ id_json, ws_json, ts });
}

pub fn getSearch(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, webset_id: []const u8, search_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    if (try validateIdParam(webset_id, allocator)) |resp| return resp;
    if (try validateIdParam(search_id, allocator)) |resp| return resp;
    const id_json = try jsonEscape(allocator, search_id);
    defer allocator.free(id_json);
    const ws_json = try jsonEscape(allocator, webset_id);
    defer allocator.free(ws_json);
    return try jFmt(200, allocator,
        "{{\"id\":{s},\"object\":\"webset_search\",\"websetId\":{s},\"status\":\"completed\"}}",
        .{ id_json, ws_json });
}

pub fn cancelSearch(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, webset_id: []const u8, search_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    if (try validateIdParam(webset_id, allocator)) |resp| return resp;
    if (try validateIdParam(search_id, allocator)) |resp| return resp;
    const id_json = try jsonEscape(allocator, search_id);
    defer allocator.free(id_json);
    const ws_json = try jsonEscape(allocator, webset_id);
    defer allocator.free(ws_json);
    const ts: i64 = time_util.nowMillis();
    return try jFmt(200, allocator,
        "{{\"id\":{s},\"object\":\"webset_search\",\"websetId\":{s},\"status\":\"canceled\",\"canceledAt\":{d}}}",
        .{ id_json, ws_json, ts });
}

pub fn createEnrichment(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, webset_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    if (try validateIdParam(webset_id, allocator)) |resp| return resp;
    const id = uuid_util.generate();
    const id_str = try uuid_util.toString(id, allocator);
    defer allocator.free(id_str);
    const id_json = try jsonEscape(allocator, id_str);
    defer allocator.free(id_json);
    const ws_json = try jsonEscape(allocator, webset_id);
    defer allocator.free(ws_json);
    const ts: i64 = time_util.nowMillis();
    return try jFmt(201, allocator,
        "{{\"id\":{s},\"object\":\"enrichment\",\"websetId\":{s},\"status\":\"pending\",\"createdAt\":{d}}}",
        .{ id_json, ws_json, ts });
}

pub fn getEnrichment(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, webset_id: []const u8, enrichment_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    if (try validateIdParam(webset_id, allocator)) |resp| return resp;
    if (try validateIdParam(enrichment_id, allocator)) |resp| return resp;
    const id_json = try jsonEscape(allocator, enrichment_id);
    defer allocator.free(id_json);
    const ws_json = try jsonEscape(allocator, webset_id);
    defer allocator.free(ws_json);
    return try jFmt(200, allocator,
        "{{\"id\":{s},\"object\":\"enrichment\",\"websetId\":{s},\"status\":\"pending\"}}",
        .{ id_json, ws_json });
}

pub fn updateEnrichment(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, webset_id: []const u8, enrichment_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    if (try validateIdParam(webset_id, allocator)) |resp| return resp;
    if (try validateIdParam(enrichment_id, allocator)) |resp| return resp;
    const id_json = try jsonEscape(allocator, enrichment_id);
    defer allocator.free(id_json);
    const ws_json = try jsonEscape(allocator, webset_id);
    defer allocator.free(ws_json);
    const ts: i64 = time_util.nowMillis();
    return try jFmt(200, allocator,
        "{{\"id\":{s},\"object\":\"enrichment\",\"websetId\":{s},\"status\":\"pending\",\"updatedAt\":{d}}}",
        .{ id_json, ws_json, ts });
}

pub fn deleteEnrichment(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, webset_id: []const u8, enrichment_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    if (try validateIdParam(webset_id, allocator)) |resp| return resp;
    if (try validateIdParam(enrichment_id, allocator)) |resp| return resp;
    const id_json = try jsonEscape(allocator, enrichment_id);
    defer allocator.free(id_json);
    const ts: i64 = time_util.nowMillis();
    return try jFmt(200, allocator,
        "{{\"id\":{s},\"object\":\"enrichment\",\"deleted\":true,\"deletedAt\":{d}}}",
        .{ id_json, ts });
}

pub fn cancelEnrichment(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, webset_id: []const u8, enrichment_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    if (try validateIdParam(webset_id, allocator)) |resp| return resp;
    if (try validateIdParam(enrichment_id, allocator)) |resp| return resp;
    const id_json = try jsonEscape(allocator, enrichment_id);
    defer allocator.free(id_json);
    const ws_json = try jsonEscape(allocator, webset_id);
    defer allocator.free(ws_json);
    const ts: i64 = time_util.nowMillis();
    return try jFmt(200, allocator,
        "{{\"id\":{s},\"object\":\"enrichment\",\"websetId\":{s},\"status\":\"canceled\",\"canceledAt\":{d}}}",
        .{ id_json, ws_json, ts });
}

pub fn listItems(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, webset_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    if (try validateIdParam(webset_id, allocator)) |resp| return resp;
    return try jLit(200, "{\"data\":[],\"hasMore\":false}", allocator);
}

pub fn getItem(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, webset_id: []const u8, item_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    if (try validateIdParam(webset_id, allocator)) |resp| return resp;
    if (try validateIdParam(item_id, allocator)) |resp| return resp;
    const id_json = try jsonEscape(allocator, item_id);
    defer allocator.free(id_json);
    const ws_json = try jsonEscape(allocator, webset_id);
    defer allocator.free(ws_json);
    return try jFmt(200, allocator,
        "{{\"id\":{s},\"object\":\"webset_item\",\"websetId\":{s}}}",
        .{ id_json, ws_json });
}

pub fn deleteItem(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, webset_id: []const u8, item_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    if (try validateIdParam(webset_id, allocator)) |resp| return resp;
    if (try validateIdParam(item_id, allocator)) |resp| return resp;
    const id_json = try jsonEscape(allocator, item_id);
    defer allocator.free(id_json);
    const ts: i64 = time_util.nowMillis();
    return try jFmt(200, allocator,
        "{{\"id\":{s},\"object\":\"webset_item\",\"deleted\":true,\"deletedAt\":{d}}}",
        .{ id_json, ts });
}

pub fn createExport(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, webset_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    if (try validateIdParam(webset_id, allocator)) |resp| return resp;
    const id = uuid_util.generate();
    const id_str = try uuid_util.toString(id, allocator);
    defer allocator.free(id_str);
    const id_json = try jsonEscape(allocator, id_str);
    defer allocator.free(id_json);
    const ws_json = try jsonEscape(allocator, webset_id);
    defer allocator.free(ws_json);
    const ts: i64 = time_util.nowMillis();
    return try jFmt(201, allocator,
        "{{\"id\":{s},\"object\":\"export\",\"websetId\":{s},\"status\":\"pending\",\"createdAt\":{d}}}",
        .{ id_json, ws_json, ts });
}

pub fn getExport(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, webset_id: []const u8, export_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    if (try validateIdParam(webset_id, allocator)) |resp| return resp;
    if (try validateIdParam(export_id, allocator)) |resp| return resp;
    const id_json = try jsonEscape(allocator, export_id);
    defer allocator.free(id_json);
    const ws_json = try jsonEscape(allocator, webset_id);
    defer allocator.free(ws_json);
    return try jFmt(200, allocator,
        "{{\"id\":{s},\"object\":\"export\",\"websetId\":{s},\"status\":\"completed\"}}",
        .{ id_json, ws_json });
}

pub fn createImport(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    const id = uuid_util.generate();
    const id_str = try uuid_util.toString(id, allocator);
    defer allocator.free(id_str);
    const id_json = try jsonEscape(allocator, id_str);
    defer allocator.free(id_json);
    const ts: i64 = time_util.nowMillis();
    return try jFmt(201, allocator,
        "{{\"id\":{s},\"object\":\"import\",\"status\":\"pending\",\"createdAt\":{d}}}",
        .{ id_json, ts });
}

pub fn getImport(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, import_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    if (try validateIdParam(import_id, allocator)) |resp| return resp;
    const id_json = try jsonEscape(allocator, import_id);
    defer allocator.free(id_json);
    return try jFmt(200, allocator,
        "{{\"id\":{s},\"object\":\"import\",\"status\":\"completed\"}}",
        .{id_json});
}

pub fn listImports(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    return try jLit(200, "{\"data\":[],\"hasMore\":false}", allocator);
}

pub fn updateImport(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, import_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    if (try validateIdParam(import_id, allocator)) |resp| return resp;
    const id_json = try jsonEscape(allocator, import_id);
    defer allocator.free(id_json);
    const ts: i64 = time_util.nowMillis();
    return try jFmt(200, allocator,
        "{{\"id\":{s},\"object\":\"import\",\"updatedAt\":{d}}}",
        .{ id_json, ts });
}

pub fn deleteImport(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, import_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    if (try validateIdParam(import_id, allocator)) |resp| return resp;
    const id_json = try jsonEscape(allocator, import_id);
    defer allocator.free(id_json);
    const ts: i64 = time_util.nowMillis();
    return try jFmt(200, allocator,
        "{{\"id\":{s},\"object\":\"import\",\"deleted\":true,\"deletedAt\":{d}}}",
        .{ id_json, ts });
}

pub fn createWebhook(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, allocator: std.mem.Allocator) !common.HttpResponse {
    if (req.body.len == 0) {
        return try jError(400, "Empty request body", "INVALID_REQUEST_BODY", allocator);
    }
    if (req.body.len > MAX_REQUEST_BODY_BYTES) {
        return try jError(413, "Request body too large", "PAYLOAD_TOO_LARGE", allocator);
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, req.body, .{ .allocate = .alloc_always }) catch {
        return try jError(400, "Invalid JSON", "INVALID_JSON", allocator);
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return try jError(400, "Request must be a JSON object", "INVALID_REQUEST_BODY", allocator);
    }
    const obj = parsed.value.object;

    const url_val = obj.get("url") orelse {
        return try jError(400, "Missing required field: url", "MISSING_URL", allocator);
    };
    if (url_val != .string) {
        return try jError(400, "url must be a string", "INVALID_URL_TYPE", allocator);
    }
    const url_src = url_val.string;
    if (!validateUrl(url_src)) {
        return try jError(400, "url must be a valid http(s) URL within length limit", "INVALID_URL", allocator);
    }

    const url_owned = try allocator.dupe(u8, url_src);
    defer allocator.free(url_owned);

    const team_str = try uuid_util.toString(auth.team_id, allocator);
    defer allocator.free(team_str);

    const secret = try crypto.generateWebhookSecret(allocator);
    defer allocator.free(secret);

    var conn = state.pg_pool.acquire() catch |err| {
        std.log.err("pg_pool.acquire failed: {s}", .{@errorName(err)});
        return try mapDbError(err, allocator);
    };
    defer state.pg_pool.release(conn);

    var id_str: []u8 = blk: {
        var rs = conn.query(
            "INSERT INTO webhooks (team_id, url, secret) VALUES ($1, $2, $3) RETURNING id::text",
            &.{ team_str, url_owned, secret },
        ) catch |err| {
            std.log.err("INSERT webhook failed: {s}", .{@errorName(err)});
            return try mapDbError(err, allocator);
        };
        defer rs.deinit();

        const row_opt = rs.next() catch |err| {
            std.log.err("rs.next failed: {s}", .{@errorName(err)});
            rs.drain() catch {};
            return try mapDbError(err, allocator);
        };
        if (row_opt == null) {
            rs.drain() catch {};
            return try jError(500, "Insert returned no rows", "DB_NO_ROWS", allocator);
        }
        const row = row_opt.?;
        const raw = row.get([]const u8, 0) catch |err| {
            std.log.err("row.get failed: {s}", .{@errorName(err)});
            rs.drain() catch {};
            return try mapDbError(err, allocator);
        };
        const owned = try allocator.dupe(u8, raw);
        rs.drain() catch {};
        break :blk owned;
    };
    defer allocator.free(id_str);

    webhooks.notifyWebhookCreated(state, auth.team_id, id_str) catch |err| {
        std.log.warn("notifyWebhookCreated failed for webhook {s}: {s}", .{ id_str, @errorName(err) });
    };

    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const w = buf.writer();
    try w.writeAll("{\"id\":");
    try writeJsonStr(w, id_str);
    try w.writeAll(",\"object\":\"webhook\",\"url\":");
    try writeJsonStr(w, url_owned);
    try w.writeAll(",\"status\":\"active\",\"secret\":");
    try writeJsonStr(w, secret);
    const ts: i64 = time_util.nowMillis();
    try std.fmt.format(w, ",\"createdAt\":{d}}}", .{ts});
    const body = try buf.toOwnedSlice();
    errdefer allocator.free(body);

    var h = try defaultHeaders(allocator);
    errdefer h.deinit();
    return common.HttpResponse{
        .status = 201,
        .headers = h,
        .body = body,
        .body_owned = true,
    };
}

pub fn listWebhooks(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    return try jLit(200, "{\"data\":[],\"hasMore\":false}", allocator);
}

pub fn getWebhook(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, webhook_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    if (try validateIdParam(webhook_id, allocator)) |resp| return resp;
    const id_json = try jsonEscape(allocator, webhook_id);
    defer allocator.free(id_json);
    return try jFmt(200, allocator,
        "{{\"id\":{s},\"object\":\"webhook\",\"status\":\"active\"}}",
        .{id_json});
}

pub fn updateWebhook(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, webhook_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    if (try validateIdParam(webhook_id, allocator)) |resp| return resp;
    const id_json = try jsonEscape(allocator, webhook_id);
    defer allocator.free(id_json);
    const ts: i64 = time_util.nowMillis();
    return try jFmt(200, allocator,
        "{{\"id\":{s},\"object\":\"webhook\",\"status\":\"active\",\"updatedAt\":{d}}}",
        .{ id_json, ts });
}

pub fn deleteWebhook(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, webhook_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    if (try validateIdParam(webhook_id, allocator)) |resp| return resp;
    const id_json = try jsonEscape(allocator, webhook_id);
    defer allocator.free(id_json);
    const ts: i64 = time_util.nowMillis();
    return try jFmt(200, allocator,
        "{{\"id\":{s},\"object\":\"webhook\",\"deleted\":true,\"deletedAt\":{d}}}",
        .{ id_json, ts });
}

pub fn listWebhookAttempts(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, webhook_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    if (try validateIdParam(webhook_id, allocator)) |resp| return resp;
    return try jLit(200, "{\"data\":[],\"hasMore\":false}", allocator);
}

pub fn listEvents(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    var result = queries.listEvents(state.pg_pool, auth.team_id, null, 25, allocator) catch |err| {
        std.log.err("queries.listEvents failed: {s}", .{@errorName(err)});
        return try mapDbError(err, allocator);
    };
    defer result.deinit(allocator);

    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const w = buf.writer();
    try w.writeAll("{\"data\":[");
    for (result.events, 0..) |event, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"id\":");
        try writeJsonStr(w, event.id);
        try w.writeAll(",\"object\":\"event\",\"type\":");
        try writeJsonStr(w, event.event_type);
        try std.fmt.format(w, ",\"createdAt\":{d}", .{event.created_at_ms});
        if (event.data) |data| {
            try w.writeAll(",\"data\":");
            try writeJsonStr(w, data);
        }
        try w.writeAll("}");
    }
    try w.writeAll("],\"hasMore\":");
    try w.writeAll(if (result.has_more) "true" else "false");
    try w.writeAll("}");

    const body = try buf.toOwnedSlice();
    errdefer allocator.free(body);
    var h = try defaultHeaders(allocator);
    errdefer h.deinit();
    return common.HttpResponse{
        .status = 200,
        .headers = h,
        .body = body,
        .body_owned = true,
    };
}

pub fn getEvent(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, event_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    if (try validateIdParam(event_id, allocator)) |resp| return resp;
    const id_json = try jsonEscape(allocator, event_id);
    defer allocator.free(id_json);
    return try jFmt(200, allocator,
        "{{\"id\":{s},\"object\":\"event\"}}",
        .{id_json});
}

pub fn getTeamInfo(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    const balance = queries.getTeamBalance(state.pg_pool, auth.team_id, allocator) catch |err| {
        std.log.err("queries.getTeamBalance failed: {s}", .{@errorName(err)});
        return try mapDbError(err, allocator);
    };
    const team_str = try uuid_util.toString(auth.team_id, allocator);
    defer allocator.free(team_str);
    const id_json = try jsonEscape(allocator, team_str);
    defer allocator.free(id_json);
    return try jFmt(200, allocator,
        "{{\"id\":{s},\"object\":\"team\",\"creditBalanceCents\":{d}}}",
        .{ id_json, balance });
}

pub fn createWebsetMonitor(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    const id = uuid_util.generate();
    const id_str = try uuid_util.toString(id, allocator);
    defer allocator.free(id_str);
    const id_json = try jsonEscape(allocator, id_str);
    defer allocator.free(id_json);
    const ts: i64 = time_util.nowMillis();
    return try jFmt(201, allocator,
        "{{\"id\":{s},\"object\":\"webset_monitor\",\"status\":\"active\",\"createdAt\":{d}}}",
        .{ id_json, ts });
}

pub fn listWebsetMonitors(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    return try jLit(200, "{\"data\":[],\"hasMore\":false}", allocator);
}

pub fn getWebsetMonitor(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, monitor_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    if (try validateIdParam(monitor_id, allocator)) |resp| return resp;
    const id_json = try jsonEscape(allocator, monitor_id);
    defer allocator.free(id_json);
    return try jFmt(200, allocator,
        "{{\"id\":{s},\"object\":\"webset_monitor\",\"status\":\"active\"}}",
        .{id_json});
}

pub fn updateWebsetMonitor(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, monitor_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    if (try validateIdParam(monitor_id, allocator)) |resp| return resp;
    const id_json = try jsonEscape(allocator, monitor_id);
    defer allocator.free(id_json);
    const ts: i64 = time_util.nowMillis();
    return try jFmt(200, allocator,
        "{{\"id\":{s},\"object\":\"webset_monitor\",\"status\":\"active\",\"updatedAt\":{d}}}",
        .{ id_json, ts });
}

pub fn deleteWebsetMonitor(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, monitor_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    if (try validateIdParam(monitor_id, allocator)) |resp| return resp;
    const id_json = try jsonEscape(allocator, monitor_id);
    defer allocator.free(id_json);
    const ts: i64 = time_util.nowMillis();
    return try jFmt(200, allocator,
        "{{\"id\":{s},\"object\":\"webset_monitor\",\"deleted\":true,\"deletedAt\":{d}}}",
        .{ id_json, ts });
}

pub fn listWebsetMonitorRuns(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, monitor_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    if (try validateIdParam(monitor_id, allocator)) |resp| return resp;
    return try jLit(200, "{\"data\":[],\"hasMore\":false}", allocator);
}

pub fn getWebsetMonitorRun(req: *const common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, monitor_id: []const u8, run_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    if (try validateIdParam(monitor_id, allocator)) |resp| return resp;
    if (try validateIdParam(run_id, allocator)) |resp| return resp;
    const id_json = try jsonEscape(allocator, run_id);
    defer allocator.free(id_json);
    const mon_json = try jsonEscape(allocator, monitor_id);
    defer allocator.free(mon_json);
    return try jFmt(200, allocator,
        "{{\"id\":{s},\"object\":\"webset_monitor_run\",\"monitorId\":{s}}}",
        .{ id_json, mon_json });
}
