const std = @import("std");
const common = @import("types/common.zig");
const app_state = @import("app_state.zig");
const middleware_auth = @import("middleware/auth.zig");
const search_handler = @import("handlers/search.zig");
const contents_handler = @import("handlers/contents.zig");
const answer_handler = @import("handlers/answer.zig");
const research_handler = @import("handlers/research.zig");
const monitors_handler = @import("handlers/monitors.zig");
const websets_handler = @import("handlers/websets.zig");
const team_handler = @import("handlers/team_management.zig");
const health_handler = @import("handlers/health.zig");
const auth_handler = @import("handlers/auth.zig");
const mcp_handler = @import("mcp/server.zig");

const SegmentSplit = struct {
    head: []const u8,
    tail: []const u8,
};

pub fn route(
    req: *common.HttpRequest,
    state: *app_state.AppState,
    allocator: std.mem.Allocator,
) !common.HttpResponse {
    const path = req.path;
    const method = req.method;

    if (std.mem.eql(u8, path, "/health") or std.mem.eql(u8, path, "/healthz")) {
        return health_handler.handleHealth(req, state, allocator);
    }

    if (std.mem.eql(u8, path, "/v1/mcp") or std.mem.startsWith(u8, path, "/v1/mcp/")) {
        return mcp_handler.handleMcp(req, state, allocator);
    }

    if (std.mem.eql(u8, path, "/auth/register")) {
        if (std.mem.eql(u8, method, "POST")) {
            return auth_handler.register(req, state, allocator);
        }
        return methodNotAllowedJson(allocator, "POST");
    }

    if (std.mem.eql(u8, path, "/auth/login")) {
        if (std.mem.eql(u8, method, "POST")) {
            return auth_handler.login(req, state, allocator);
        }
        return methodNotAllowedJson(allocator, "POST");
    }

    if (std.mem.eql(u8, path, "/") or
        std.mem.eql(u8, path, "/app") or
        std.mem.eql(u8, path, "/login") or
        std.mem.eql(u8, path, "/register"))
    {
        if (std.mem.eql(u8, method, "GET")) {
            return serveFile("public/index.html", "text/html; charset=utf-8", allocator);
        }
        return methodNotAllowedJson(allocator, "GET");
    }

    if (requiresAuthentication(path)) {
        const auth = try middleware_auth.authenticate(req, state.pg_pool, state.redis_pool, allocator);
        return routeAuthenticated(req, auth, state, allocator);
    }

    return notFoundJson(allocator, true);
}

fn routeAuthenticated(
    req: *common.HttpRequest,
    auth: common.AuthContext,
    state: *app_state.AppState,
    allocator: std.mem.Allocator,
) !common.HttpResponse {
    const path = req.path;
    const method = req.method;

    if (std.mem.eql(u8, path, "/search")) {
        if (std.mem.eql(u8, method, "POST")) return search_handler.handleSearch(req, auth, state, allocator);
        return methodNotAllowedJson(allocator, "POST");
    }

    if (std.mem.eql(u8, path, "/contents")) {
        if (std.mem.eql(u8, method, "POST")) return contents_handler.handleContents(req, auth, state, allocator);
        return methodNotAllowedJson(allocator, "POST");
    }

    if (std.mem.eql(u8, path, "/search/context")) {
        if (std.mem.eql(u8, method, "POST")) return search_handler.handleContext(req, auth, state, allocator);
        return methodNotAllowedJson(allocator, "POST");
    }

    if (std.mem.eql(u8, path, "/v1/search")) {
        if (std.mem.eql(u8, method, "POST")) return search_handler.handleSearch(req, auth, state, allocator);
        return methodNotAllowedJson(allocator, "POST");
    }

    if (std.mem.eql(u8, path, "/v1/contents")) {
        if (std.mem.eql(u8, method, "POST")) return contents_handler.handleContents(req, auth, state, allocator);
        return methodNotAllowedJson(allocator, "POST");
    }

    if (std.mem.eql(u8, path, "/answer")) {
        if (std.mem.eql(u8, method, "POST")) return answer_handler.handleAnswer(req, auth, state, allocator);
        return methodNotAllowedJson(allocator, "POST");
    }

    if (std.mem.eql(u8, path, "/v1/chat/completions")) {
        if (std.mem.eql(u8, method, "POST")) return answer_handler.handleChatCompletions(req, auth, state, allocator);
        return methodNotAllowedJson(allocator, "POST");
    }

    if (std.mem.eql(u8, path, "/v1/responses")) {
        if (std.mem.eql(u8, method, "POST")) return answer_handler.handleResponses(req, auth, state, allocator);
        return methodNotAllowedJson(allocator, "POST");
    }

    if (try routeResearch(req, auth, state, allocator)) |response| return response;
    if (try routeMonitors(req, auth, state, allocator)) |response| return response;
    if (try routeWebsets(req, auth, state, allocator)) |response| return response;
    if (try routeEvents(req, auth, state, allocator)) |response| return response;
    if (try routeWebhooks(req, auth, state, allocator)) |response| return response;
    if (try routeTeam(req, auth, state, allocator)) |response| return response;
    if (try routeImports(req, auth, state, allocator)) |response| return response;

    return notFoundJson(allocator, true);
}

fn routeResearch(
    req: *common.HttpRequest,
    auth: common.AuthContext,
    state: *app_state.AppState,
    allocator: std.mem.Allocator,
) !?common.HttpResponse {
    const path = req.path;
    const method = req.method;

    if (std.mem.eql(u8, path, "/v1/research/tasks")) {
        if (std.mem.eql(u8, method, "POST")) return research_handler.createTask(req, auth, state, allocator);
        if (std.mem.eql(u8, method, "GET")) return research_handler.listTasks(req, auth, state, allocator);
        return methodNotAllowedJson(allocator, "GET, POST");
    }

    if (!std.mem.startsWith(u8, path, "/v1/research/tasks/")) return null;

    const task_id = path["/v1/research/tasks/".len..];
    if (!isSinglePathSegment(task_id)) return notFoundJson(allocator, true);

    if (std.mem.eql(u8, method, "GET")) return research_handler.getTask(req, auth, state, task_id, allocator);
    if (std.mem.eql(u8, method, "DELETE")) return research_handler.cancelTask(req, auth, state, task_id, allocator);
    return methodNotAllowedJson(allocator, "DELETE, GET");
}

fn routeMonitors(
    req: *common.HttpRequest,
    auth: common.AuthContext,
    state: *app_state.AppState,
    allocator: std.mem.Allocator,
) !?common.HttpResponse {
    const path = req.path;
    const method = req.method;

    if (std.mem.eql(u8, path, "/v1/monitors")) {
        if (std.mem.eql(u8, method, "GET")) return monitors_handler.listMonitors(req, auth, state, allocator);
        if (std.mem.eql(u8, method, "POST")) return monitors_handler.createMonitor(req, auth, state, allocator);
        return methodNotAllowedJson(allocator, "GET, POST");
    }

    if (std.mem.eql(u8, path, "/v1/monitors/batch")) {
        if (std.mem.eql(u8, method, "POST")) return monitors_handler.batchMonitors(req, auth, state, allocator);
        return methodNotAllowedJson(allocator, "POST");
    }

    if (!std.mem.startsWith(u8, path, "/v1/monitors/")) return null;

    const rest = path["/v1/monitors/".len..];
    const first = splitFirstSegment(rest);
    const monitor_id = first.head;
    const sub = first.tail;

    if (!isSinglePathSegment(monitor_id)) return notFoundJson(allocator, true);

    if (sub.len == 0) {
        if (std.mem.eql(u8, method, "GET")) return monitors_handler.getMonitor(req, auth, state, monitor_id, allocator);
        if (std.mem.eql(u8, method, "PATCH")) return monitors_handler.updateMonitor(req, auth, state, monitor_id, allocator);
        if (std.mem.eql(u8, method, "DELETE")) return monitors_handler.deleteMonitor(req, auth, state, monitor_id, allocator);
        return methodNotAllowedJson(allocator, "DELETE, GET, PATCH");
    }

    if (std.mem.eql(u8, sub, "/trigger")) {
        if (std.mem.eql(u8, method, "POST")) return monitors_handler.triggerMonitor(req, auth, state, monitor_id, allocator);
        return methodNotAllowedJson(allocator, "POST");
    }

    if (std.mem.eql(u8, sub, "/runs")) {
        if (std.mem.eql(u8, method, "GET")) return monitors_handler.listRuns(req, auth, state, monitor_id, allocator);
        return methodNotAllowedJson(allocator, "GET");
    }

    if (std.mem.startsWith(u8, sub, "/runs/")) {
        const run_id = sub["/runs/".len..];
        if (!isSinglePathSegment(run_id)) return notFoundJson(allocator, true);
        if (std.mem.eql(u8, method, "GET")) return monitors_handler.getRun(req, auth, state, monitor_id, run_id, allocator);
        return methodNotAllowedJson(allocator, "GET");
    }

    return notFoundJson(allocator, true);
}

fn routeWebsets(
    req: *common.HttpRequest,
    auth: common.AuthContext,
    state: *app_state.AppState,
    allocator: std.mem.Allocator,
) !?common.HttpResponse {
    const path = req.path;
    const method = req.method;

    if (std.mem.eql(u8, path, "/v1/websets")) {
        if (std.mem.eql(u8, method, "GET")) return websets_handler.listWebsets(req, auth, state, allocator);
        if (std.mem.eql(u8, method, "POST")) return websets_handler.createWebset(req, auth, state, allocator);
        return methodNotAllowedJson(allocator, "GET, POST");
    }

    if (std.mem.eql(u8, path, "/v1/websets/preview")) {
        if (std.mem.eql(u8, method, "POST")) return websets_handler.previewWebset(req, auth, state, allocator);
        return methodNotAllowedJson(allocator, "POST");
    }

    if (!std.mem.startsWith(u8, path, "/v1/websets/")) return null;

    return try routeWebset(req, auth, state, path, method, allocator);
}

fn routeEvents(
    req: *common.HttpRequest,
    auth: common.AuthContext,
    state: *app_state.AppState,
    allocator: std.mem.Allocator,
) !?common.HttpResponse {
    const path = req.path;
    const method = req.method;

    if (std.mem.eql(u8, path, "/v1/events")) {
        if (std.mem.eql(u8, method, "GET")) return websets_handler.listEvents(req, auth, state, allocator);
        return methodNotAllowedJson(allocator, "GET");
    }

    if (!std.mem.startsWith(u8, path, "/v1/events/")) return null;

    const event_id = path["/v1/events/".len..];
    if (!isSinglePathSegment(event_id)) return notFoundJson(allocator, true);

    if (std.mem.eql(u8, method, "GET")) return websets_handler.getEvent(req, auth, state, event_id, allocator);
    return methodNotAllowedJson(allocator, "GET");
}

fn routeWebhooks(
    req: *common.HttpRequest,
    auth: common.AuthContext,
    state: *app_state.AppState,
    allocator: std.mem.Allocator,
) !?common.HttpResponse {
    const path = req.path;
    const method = req.method;

    if (std.mem.eql(u8, path, "/v1/webhooks")) {
        if (std.mem.eql(u8, method, "GET")) return websets_handler.listWebhooks(req, auth, state, allocator);
        if (std.mem.eql(u8, method, "POST")) return websets_handler.createWebhook(req, auth, state, allocator);
        return methodNotAllowedJson(allocator, "GET, POST");
    }

    if (!std.mem.startsWith(u8, path, "/v1/webhooks/")) return null;

    const rest = path["/v1/webhooks/".len..];
    const first = splitFirstSegment(rest);
    const webhook_id = first.head;
    const sub = first.tail;

    if (!isSinglePathSegment(webhook_id)) return notFoundJson(allocator, true);

    if (sub.len == 0) {
        if (std.mem.eql(u8, method, "GET")) return websets_handler.getWebhook(req, auth, state, webhook_id, allocator);
        if (std.mem.eql(u8, method, "PATCH")) return websets_handler.updateWebhook(req, auth, state, webhook_id, allocator);
        if (std.mem.eql(u8, method, "DELETE")) return websets_handler.deleteWebhook(req, auth, state, webhook_id, allocator);
        return methodNotAllowedJson(allocator, "DELETE, GET, PATCH");
    }

    if (std.mem.eql(u8, sub, "/attempts")) {
        if (std.mem.eql(u8, method, "GET")) return websets_handler.listWebhookAttempts(req, auth, state, webhook_id, allocator);
        return methodNotAllowedJson(allocator, "GET");
    }

    return notFoundJson(allocator, true);
}

fn routeTeam(
    req: *common.HttpRequest,
    auth: common.AuthContext,
    state: *app_state.AppState,
    allocator: std.mem.Allocator,
) !?common.HttpResponse {
    const path = req.path;
    const method = req.method;

    if (std.mem.eql(u8, path, "/v1/team")) {
        if (std.mem.eql(u8, method, "GET")) return websets_handler.getTeamInfo(req, auth, state, allocator);
        return methodNotAllowedJson(allocator, "GET");
    }

    if (std.mem.eql(u8, path, "/v1/team/apikeys")) {
        if (std.mem.eql(u8, method, "GET")) return team_handler.listApiKeys(req, auth, state, allocator);
        if (std.mem.eql(u8, method, "POST")) return team_handler.createApiKey(req, auth, state, allocator);
        return methodNotAllowedJson(allocator, "GET, POST");
    }

    if (!std.mem.startsWith(u8, path, "/v1/team/apikeys/")) return null;

    const rest = path["/v1/team/apikeys/".len..];
    const first = splitFirstSegment(rest);
    const key_id = first.head;
    const sub = first.tail;

    if (!isSinglePathSegment(key_id)) return notFoundJson(allocator, true);

    if (sub.len == 0) {
        if (std.mem.eql(u8, method, "GET")) return team_handler.getApiKey(req, auth, state, key_id, allocator);
        if (std.mem.eql(u8, method, "PATCH")) return team_handler.updateApiKey(req, auth, state, key_id, allocator);
        if (std.mem.eql(u8, method, "DELETE")) return team_handler.deleteApiKey(req, auth, state, key_id, allocator);
        return methodNotAllowedJson(allocator, "DELETE, GET, PATCH");
    }

    if (std.mem.eql(u8, sub, "/usage")) {
        if (std.mem.eql(u8, method, "GET")) return team_handler.getApiKeyUsage(req, auth, state, key_id, allocator);
        return methodNotAllowedJson(allocator, "GET");
    }

    return notFoundJson(allocator, true);
}

fn routeImports(
    req: *common.HttpRequest,
    auth: common.AuthContext,
    state: *app_state.AppState,
    allocator: std.mem.Allocator,
) !?common.HttpResponse {
    const path = req.path;
    const method = req.method;

    if (std.mem.eql(u8, path, "/v1/imports")) {
        if (std.mem.eql(u8, method, "GET")) return websets_handler.listImports(req, auth, state, allocator);
        if (std.mem.eql(u8, method, "POST")) return websets_handler.createImport(req, auth, state, allocator);
        return methodNotAllowedJson(allocator, "GET, POST");
    }

    if (!std.mem.startsWith(u8, path, "/v1/imports/")) return null;

    const import_id = path["/v1/imports/".len..];
    if (!isSinglePathSegment(import_id)) return notFoundJson(allocator, true);

    if (std.mem.eql(u8, method, "GET")) return websets_handler.getImport(req, auth, state, import_id, allocator);
    if (std.mem.eql(u8, method, "PATCH")) return websets_handler.updateImport(req, auth, state, import_id, allocator);
    if (std.mem.eql(u8, method, "DELETE")) return websets_handler.deleteImport(req, auth, state, import_id, allocator);
    return methodNotAllowedJson(allocator, "DELETE, GET, PATCH");
}

fn serveFile(file_path: []const u8, content_type: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    const file = std.fs.cwd().openFile(file_path, .{}) catch {
        var h = std.StringHashMap([]const u8).init(allocator);
        try h.put("content-type", "text/html; charset=utf-8");
        return common.HttpResponse{
            .status = 404,
            .headers = h,
            .body = "<!DOCTYPE html><html><body>Not Found</body></html>",
        };
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        var h = std.StringHashMap([]const u8).init(allocator);
        try h.put("content-type", "text/plain; charset=utf-8");
        return common.HttpResponse{
            .status = 500,
            .headers = h,
            .body = "Internal Server Error",
        };
    };

    var h = std.StringHashMap([]const u8).init(allocator);
    try h.put("content-type", content_type);
    return common.HttpResponse{
        .status = 200,
        .headers = h,
        .body = content,
    };
}

fn routeWebset(
    req: *common.HttpRequest,
    auth: common.AuthContext,
    state: *app_state.AppState,
    path: []const u8,
    method: []const u8,
    allocator: std.mem.Allocator,
) !common.HttpResponse {
    const rest = path["/v1/websets/".len..];
    if (rest.len == 0) return notFoundJson(allocator, false);

    const root = splitFirstSegment(rest);
    const webset_id = root.head;
    const sub = root.tail;

    if (!isSinglePathSegment(webset_id)) return notFoundJson(allocator, false);

    if (sub.len == 0) {
        if (std.mem.eql(u8, method, "GET")) return websets_handler.getWebset(req, auth, state, webset_id, allocator);
        if (std.mem.eql(u8, method, "PATCH")) return websets_handler.updateWebset(req, auth, state, webset_id, allocator);
        if (std.mem.eql(u8, method, "DELETE")) return websets_handler.deleteWebset(req, auth, state, webset_id, allocator);
        return methodNotAllowedJson(allocator, "DELETE, GET, PATCH");
    }

    if (std.mem.eql(u8, sub, "/cancel")) {
        if (std.mem.eql(u8, method, "POST")) return websets_handler.cancelWebset(req, auth, state, webset_id, allocator);
        return methodNotAllowedJson(allocator, "POST");
    }

    if (std.mem.eql(u8, sub, "/searches")) {
        if (std.mem.eql(u8, method, "POST")) return websets_handler.createSearch(req, auth, state, webset_id, allocator);
        return methodNotAllowedJson(allocator, "POST");
    }

    if (std.mem.startsWith(u8, sub, "/searches/")) {
        const after = sub["/searches/".len..];
        const split = splitFirstSegment(after);
        const search_id = split.head;
        const search_sub = split.tail;

        if (!isSinglePathSegment(search_id)) return notFoundJson(allocator, false);

        if (search_sub.len == 0) {
            if (std.mem.eql(u8, method, "GET")) return websets_handler.getSearch(req, auth, state, webset_id, search_id, allocator);
            return methodNotAllowedJson(allocator, "GET");
        }

        if (std.mem.eql(u8, search_sub, "/cancel")) {
            if (std.mem.eql(u8, method, "POST")) return websets_handler.cancelSearch(req, auth, state, webset_id, search_id, allocator);
            return methodNotAllowedJson(allocator, "POST");
        }

        return notFoundJson(allocator, false);
    }

    if (std.mem.eql(u8, sub, "/items")) {
        if (std.mem.eql(u8, method, "GET")) return websets_handler.listItems(req, auth, state, webset_id, allocator);
        return methodNotAllowedJson(allocator, "GET");
    }

    if (std.mem.startsWith(u8, sub, "/items/")) {
        const item_id = sub["/items/".len..];
        if (!isSinglePathSegment(item_id)) return notFoundJson(allocator, false);
        if (std.mem.eql(u8, method, "GET")) return websets_handler.getItem(req, auth, state, webset_id, item_id, allocator);
        if (std.mem.eql(u8, method, "DELETE")) return websets_handler.deleteItem(req, auth, state, webset_id, item_id, allocator);
        return methodNotAllowedJson(allocator, "DELETE, GET");
    }

    if (std.mem.eql(u8, sub, "/enrichments")) {
        if (std.mem.eql(u8, method, "POST")) return websets_handler.createEnrichment(req, auth, state, webset_id, allocator);
        return methodNotAllowedJson(allocator, "POST");
    }

    if (std.mem.startsWith(u8, sub, "/enrichments/")) {
        const after = sub["/enrichments/".len..];
        const split = splitFirstSegment(after);
        const enrichment_id = split.head;
        const enrichment_sub = split.tail;

        if (!isSinglePathSegment(enrichment_id)) return notFoundJson(allocator, false);

        if (enrichment_sub.len == 0) {
            if (std.mem.eql(u8, method, "GET")) return websets_handler.getEnrichment(req, auth, state, webset_id, enrichment_id, allocator);
            if (std.mem.eql(u8, method, "PUT")) return websets_handler.updateEnrichment(req, auth, state, webset_id, enrichment_id, allocator);
            if (std.mem.eql(u8, method, "DELETE")) return websets_handler.deleteEnrichment(req, auth, state, webset_id, enrichment_id, allocator);
            return methodNotAllowedJson(allocator, "DELETE, GET, PUT");
        }

        if (std.mem.eql(u8, enrichment_sub, "/cancel")) {
            if (std.mem.eql(u8, method, "POST")) return websets_handler.cancelEnrichment(req, auth, state, webset_id, enrichment_id, allocator);
            return methodNotAllowedJson(allocator, "POST");
        }

        return notFoundJson(allocator, false);
    }

    if (std.mem.eql(u8, sub, "/exports")) {
        if (std.mem.eql(u8, method, "POST")) return websets_handler.createExport(req, auth, state, webset_id, allocator);
        return methodNotAllowedJson(allocator, "POST");
    }

    if (std.mem.startsWith(u8, sub, "/exports/")) {
        const export_id = sub["/exports/".len..];
        if (!isSinglePathSegment(export_id)) return notFoundJson(allocator, false);
        if (std.mem.eql(u8, method, "GET")) return websets_handler.getExport(req, auth, state, webset_id, export_id, allocator);
        return methodNotAllowedJson(allocator, "GET");
    }

    if (std.mem.eql(u8, sub, "/monitors")) {
        if (std.mem.eql(u8, method, "GET")) return websets_handler.listWebsetMonitors(req, auth, state, webset_id, allocator);
        if (std.mem.eql(u8, method, "POST")) return websets_handler.createWebsetMonitor(req, auth, state, webset_id, allocator);
        return methodNotAllowedJson(allocator, "GET, POST");
    }

    if (std.mem.startsWith(u8, sub, "/monitors/")) {
        const after = sub["/monitors/".len..];
        const split = splitFirstSegment(after);
        const monitor_id = split.head;
        const monitor_sub = split.tail;

        if (!isSinglePathSegment(monitor_id)) return notFoundJson(allocator, false);

        if (monitor_sub.len == 0) {
            if (std.mem.eql(u8, method, "GET")) return websets_handler.getWebsetMonitor(req, auth, state, webset_id, monitor_id, allocator);
            if (std.mem.eql(u8, method, "PATCH")) return websets_handler.updateWebsetMonitor(req, auth, state, webset_id, monitor_id, allocator);
            if (std.mem.eql(u8, method, "DELETE")) return websets_handler.deleteWebsetMonitor(req, auth, state, webset_id, monitor_id, allocator);
            return methodNotAllowedJson(allocator, "DELETE, GET, PATCH");
        }

        if (std.mem.eql(u8, monitor_sub, "/runs")) {
            if (std.mem.eql(u8, method, "GET")) return websets_handler.listWebsetMonitorRuns(req, auth, state, webset_id, monitor_id, allocator);
            return methodNotAllowedJson(allocator, "GET");
        }

        if (std.mem.startsWith(u8, monitor_sub, "/runs/")) {
            const run_id = monitor_sub["/runs/".len..];
            if (!isSinglePathSegment(run_id)) return notFoundJson(allocator, false);
            if (std.mem.eql(u8, method, "GET")) return websets_handler.getWebsetMonitorRun(req, auth, state, webset_id, monitor_id, run_id, allocator);
            return methodNotAllowedJson(allocator, "GET");
        }

        return notFoundJson(allocator, false);
    }

    return notFoundJson(allocator, false);
}

fn notFoundJson(allocator: std.mem.Allocator, with_tag: bool) !common.HttpResponse {
    var headers = std.StringHashMap([]const u8).init(allocator);
    try headers.put("content-type", "application/json");
    return common.HttpResponse{
        .status = 404,
        .headers = headers,
        .body = if (with_tag) "{\"error\":\"Not Found\",\"tag\":\"NOT_FOUND\"}" else "{\"error\":\"Not Found\"}",
    };
}

fn methodNotAllowedJson(allocator: std.mem.Allocator, allow: []const u8) !common.HttpResponse {
    var headers = std.StringHashMap([]const u8).init(allocator);
    try headers.put("content-type", "application/json");
    try headers.put("allow", allow);
    return common.HttpResponse{
        .status = 405,
        .headers = headers,
        .body = "{\"error\":\"Method Not Allowed\",\"tag\":\"METHOD_NOT_ALLOWED\"}",
    };
}

fn requiresAuthentication(path: []const u8) bool {
    return std.mem.eql(u8, path, "/search") or
        std.mem.eql(u8, path, "/contents") or
        std.mem.eql(u8, path, "/search/context") or
        std.mem.eql(u8, path, "/v1/search") or
        std.mem.eql(u8, path, "/v1/contents") or
        std.mem.eql(u8, path, "/answer") or
        std.mem.eql(u8, path, "/v1/chat/completions") or
        std.mem.eql(u8, path, "/v1/responses") or
        std.mem.eql(u8, path, "/v1/research/tasks") or
        std.mem.startsWith(u8, path, "/v1/research/tasks/") or
        std.mem.eql(u8, path, "/v1/monitors") or
        std.mem.eql(u8, path, "/v1/monitors/batch") or
        std.mem.startsWith(u8, path, "/v1/monitors/") or
        std.mem.eql(u8, path, "/v1/websets") or
        std.mem.eql(u8, path, "/v1/websets/preview") or
        std.mem.startsWith(u8, path, "/v1/websets/") or
        std.mem.eql(u8, path, "/v1/events") or
        std.mem.startsWith(u8, path, "/v1/events/") or
        std.mem.eql(u8, path, "/v1/webhooks") or
        std.mem.startsWith(u8, path, "/v1/webhooks/") or
        std.mem.eql(u8, path, "/v1/team") or
        std.mem.eql(u8, path, "/v1/team/apikeys") or
        std.mem.startsWith(u8, path, "/v1/team/apikeys/") or
        std.mem.eql(u8, path, "/v1/imports") or
        std.mem.startsWith(u8, path, "/v1/imports/");
}

fn splitFirstSegment(input: []const u8) SegmentSplit {
    if (std.mem.indexOfScalar(u8, input, '/')) |index| {
        return .{
            .head = input[0..index],
            .tail = input[index..],
        };
    }
    return .{
        .head = input,
        .tail = "",
    };
}

fn isSinglePathSegment(value: []const u8) bool {
    return value.len > 0 and std.mem.indexOfScalar(u8, value, '/') == null;
}
