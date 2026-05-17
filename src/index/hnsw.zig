const std = @import("std");
const common = @import("../types/common.zig");

pub const HnswIndex = struct {
    dim: usize,
    m: usize,
    ef_construction: usize,
    ef_search: usize,
    enter_point: ?usize,
    max_level: u32,
    nodes: std.ArrayListUnmanaged(HnswNode),
    vectors: std.ArrayListUnmanaged([]f32),
    mutex: std.Thread.RwLock,
    allocator: std.mem.Allocator,
    path: []const u8,
    vector_norms: std.ArrayListUnmanaged(f32),

    pub const HnswNode = struct {
        id: []const u8,
        level: u32,
        neighbors: [][]u32,
    };

    const FileMagic: u32 = 0x484E5357;
    const FileVersion: u32 = 2;
    const max_id_len: usize = 4096;

    const Scored = struct {
        idx: usize,
        score: f32,
    };

    pub fn load(path: []const u8, dim: usize, allocator: std.mem.Allocator) !HnswIndex {
        const path_copy = try allocator.dupe(u8, path);
        errdefer allocator.free(path_copy);

        var idx = HnswIndex{
            .dim = dim,
            .m = 16,
            .ef_construction = 200,
            .ef_search = 50,
            .enter_point = null,
            .max_level = 0,
            .nodes = .{},
            .vectors = .{},
            .mutex = .{},
            .allocator = allocator,
            .path = path_copy,
            .vector_norms = .{},
        };
        errdefer idx.deinit();

        const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return idx,
            else => return err,
        };
        defer file.close();

        const magic = try readIntLe(u32, file);
        if (magic != FileMagic) return error.InvalidFormat;

        const version = try readIntLe(u32, file);
        if (version != 1 and version != FileVersion) return error.UnsupportedVersion;

        const count_u64 = try readIntLe(u64, file);
        const file_dim_u64 = try readIntLe(u64, file);
        if (file_dim_u64 != dim) return error.DimensionMismatch;

        const count = std.math.cast(usize, count_u64) orelse return error.Overflow;

        try idx.nodes.ensureTotalCapacity(allocator, count);
        try idx.vectors.ensureTotalCapacity(allocator, count);
        try idx.vector_norms.ensureTotalCapacity(allocator, count);

        if (version >= 2) {
            idx.m = try readBoundedUsize(file, 1, 1024);
            idx.ef_construction = try readBoundedUsize(file, 1, 1_000_000);
            idx.ef_search = try readBoundedUsize(file, 1, 1_000_000);
        }

        var max_level: u32 = 0;
        var enter_point: ?usize = null;

        var ci: usize = 0;
        while (ci < count) : (ci += 1) {
            const id_len_u32 = try readIntLe(u32, file);
            const id_len = std.math.cast(usize, id_len_u32) orelse return error.Overflow;
            if (id_len == 0 or id_len > max_id_len) return error.InvalidIdentifierLength;

            const id_buf = try allocator.alloc(u8, id_len);
            var id_owned = true;
            errdefer {
                if (id_owned) allocator.free(id_buf);
            }
            try readExact(file, id_buf);

            const vec = try allocator.alloc(f32, dim);
            var vec_owned = true;
            errdefer {
                if (vec_owned) allocator.free(vec);
            }

            var norm_sq: f32 = 0;
            for (vec) |*v| {
                const bits = try readIntLe(u32, file);
                const value: f32 = @bitCast(bits);
                if (!std.math.isFinite(value)) return error.InvalidVectorValue;
                v.* = value;
                norm_sq += value * value;
            }

            var node_level: u32 = 0;
            var neighbors = try allocator.alloc([]u32, 0);
            var neighbors_owned = true;
            var allocated_layers: usize = 0;
            errdefer {
                if (neighbors_owned) {
                    for (neighbors[0..allocated_layers]) |layer| {
                        allocator.free(layer);
                    }
                    allocator.free(neighbors);
                }
            }

            if (version >= 2) {
                node_level = try readIntLe(u32, file);
                const layer_count_u32 = try readIntLe(u32, file);
                const layer_count = std.math.cast(usize, layer_count_u32) orelse return error.Overflow;
                if (layer_count == 0) {
                    if (node_level != 0) return error.InvalidLevelData;
                } else {
                    const expected_layers = (std.math.cast(usize, node_level) orelse return error.Overflow) + 1;
                    if (layer_count != expected_layers) return error.InvalidLevelData;

                    allocator.free(neighbors);
                    neighbors = try allocator.alloc([]u32, layer_count);
                    allocated_layers = 0;

                    for (0..layer_count) |layer_idx| {
                        const neighbor_count_u32 = try readIntLe(u32, file);
                        const neighbor_count = std.math.cast(usize, neighbor_count_u32) orelse return error.Overflow;
                        if (neighbor_count > idx.m * 2) return error.InvalidNeighborCount;

                        const layer = try allocator.alloc(u32, neighbor_count);
                        neighbors[layer_idx] = layer;
                        allocated_layers = layer_idx + 1;

                        for (layer) |*dst| {
                            const neighbor_idx_u32 = try readIntLe(u32, file);
                            const neighbor_idx = std.math.cast(usize, neighbor_idx_u32) orelse return error.Overflow;
                            if (neighbor_idx >= count) return error.InvalidNeighborIndex;
                            dst.* = neighbor_idx_u32;
                        }
                    }
                }
            }

            const norm = if (norm_sq > 0) @sqrt(norm_sq) else @as(f32, 0);

            try idx.vectors.append(allocator, vec);
            var vec_in_list = true;
            errdefer {
                if (vec_in_list) {
                    _ = idx.vectors.pop();
                    allocator.free(vec);
                    vec_owned = false;
                    vec_in_list = false;
                }
            }

            try idx.vector_norms.append(allocator, norm);
            var norm_in_list = true;
            errdefer {
                if (norm_in_list) {
                    _ = idx.vector_norms.pop();
                    norm_in_list = false;
                }
            }

            try idx.nodes.append(allocator, .{
                .id = id_buf,
                .level = node_level,
                .neighbors = neighbors,
            });
            errdefer {
                _ = idx.nodes.pop();
                if (id_owned) {
                    allocator.free(id_buf);
                    id_owned = false;
                }
                if (vec_in_list) {
                    _ = idx.vectors.pop();
                    allocator.free(vec);
                    vec_owned = false;
                    vec_in_list = false;
                }
                if (norm_in_list) {
                    _ = idx.vector_norms.pop();
                    norm_in_list = false;
                }
                if (neighbors_owned) {
                    for (neighbors[0..allocated_layers]) |layer| {
                        allocator.free(layer);
                    }
                    allocator.free(neighbors);
                    neighbors_owned = false;
                }
            }

            if (enter_point == null or node_level > max_level) {
                max_level = node_level;
                enter_point = ci;
            }
        }

        idx.max_level = max_level;
        idx.enter_point = enter_point;

        return idx;
    }

    pub fn deinit(self: *HnswIndex) void {
        for (self.vectors.items) |vec| {
            self.allocator.free(vec);
        }
        self.vectors.deinit(self.allocator);

        for (self.nodes.items) |node| {
            self.allocator.free(node.id);
            for (node.neighbors) |layer| {
                self.allocator.free(layer);
            }
            self.allocator.free(node.neighbors);
        }
        self.nodes.deinit(self.allocator);

        self.vector_norms.deinit(self.allocator);
        self.allocator.free(self.path);
    }

    pub fn save(self: *HnswIndex, path: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (std.fs.path.dirname(path)) |dir| {
            if (dir.len > 0) {
                try std.fs.cwd().makePath(dir);
            }
        }

        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
        defer self.allocator.free(tmp_path);

        {
            const file = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
            defer file.close();

            if (self.nodes.items.len != self.vectors.items.len or self.nodes.items.len != self.vector_norms.items.len) {
                return error.CorruptIndexState;
            }

            try writeIntLe(u32, file, FileMagic);
            try writeIntLe(u32, file, FileVersion);
            try writeIntLe(u64, file, @as(u64, @intCast(self.nodes.items.len)));
            try writeIntLe(u64, file, @as(u64, @intCast(self.dim)));
            try writeIntLe(u64, file, @as(u64, @intCast(self.m)));
            try writeIntLe(u64, file, @as(u64, @intCast(self.ef_construction)));
            try writeIntLe(u64, file, @as(u64, @intCast(self.ef_search)));

            for (self.nodes.items, 0..) |node, i| {
                const vec = self.vectors.items[i];
                if (vec.len != self.dim) return error.CorruptIndexState;
                if (node.id.len == 0 or node.id.len > max_id_len) return error.CorruptIndexState;
                if (node.neighbors.len == 0 and node.level != 0) return error.CorruptIndexState;
                if (node.neighbors.len > 0 and node.neighbors.len != (std.math.cast(usize, node.level) orelse return error.CorruptIndexState) + 1) return error.CorruptIndexState;

                try writeIntLe(u32, file, @as(u32, @intCast(node.id.len)));
                try file.writeAll(node.id);

                for (vec) |v| {
                    if (!std.math.isFinite(v)) return error.InvalidVectorValue;
                    const bits: u32 = @bitCast(v);
                    try writeIntLe(u32, file, bits);
                }

                try writeIntLe(u32, file, node.level);
                try writeIntLe(u32, file, @as(u32, @intCast(node.neighbors.len)));

                for (node.neighbors) |layer| {
                    if (layer.len > self.m * 2) return error.CorruptIndexState;
                    try writeIntLe(u32, file, @as(u32, @intCast(layer.len)));
                    for (layer) |neighbor_idx| {
                        if (neighbor_idx >= self.nodes.items.len) return error.CorruptIndexState;
                        try writeIntLe(u32, file, neighbor_idx);
                    }
                }
            }

            try file.sync();
        }

        std.fs.cwd().rename(tmp_path, path) catch |err| switch (err) {
            error.PathAlreadyExists => {
                try std.fs.cwd().deleteFile(path);
                try std.fs.cwd().rename(tmp_path, path);
            },
            else => return err,
        };
    }

    pub fn insert(self: *HnswIndex, id: []const u8, vec: []const f32) !void {
        if (vec.len != self.dim) return error.DimensionMismatch;
        if (id.len == 0 or id.len > max_id_len) return error.InvalidIdentifierLength;

        self.mutex.lock();
        defer self.mutex.unlock();

        const vec_copy = try self.allocator.alloc(f32, vec.len);
        errdefer self.allocator.free(vec_copy);
        @memcpy(vec_copy, vec);

        var norm_sq: f32 = 0;
        for (vec_copy) |v| {
            if (!std.math.isFinite(v)) return error.InvalidVectorValue;
            norm_sq += v * v;
        }
        const norm = if (norm_sq > 0) @sqrt(norm_sq) else @as(f32, 0);

        const id_copy = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_copy);

        const level = self.randomLevel(id, vec_copy);
        const layer_count = level + 1;
        var neighbors = try self.allocator.alloc([]u32, layer_count);
        errdefer self.allocator.free(neighbors);
        for (0..layer_count) |i| {
            neighbors[i] = &.{};
        }

        const new_idx = self.nodes.items.len;

        try self.vectors.append(self.allocator, vec_copy);
        errdefer _ = self.vectors.pop();

        try self.vector_norms.append(self.allocator, norm);
        errdefer _ = self.vector_norms.pop();

        try self.nodes.append(self.allocator, .{
            .id = id_copy,
            .level = level,
            .neighbors = neighbors,
        });
        errdefer _ = self.nodes.pop();

        if (self.enter_point == null) {
            self.enter_point = new_idx;
            self.max_level = level;
            return;
        }

        var curr_node = self.enter_point.?;
        var curr_score = cosineSimilarityWithNorm(vec_copy, norm, self.vectors.items[curr_node], self.vector_norms.items[curr_node]);
        var curr_level = self.max_level;

        while (curr_level > level) {
            var changed = true;
            while (changed) {
                changed = false;
                const node_neighbors = self.nodes.items[curr_node].neighbors[curr_level];
                for (node_neighbors) |neighbor_u32| {
                    const neighbor = @as(usize, neighbor_u32);
                    const score = cosineSimilarityWithNorm(vec_copy, norm, self.vectors.items[neighbor], self.vector_norms.items[neighbor]);
                    if (score > curr_score) {
                        curr_score = score;
                        curr_node = neighbor;
                        changed = true;
                    }
                }
            }
            if (curr_level == 0) break;
            curr_level -= 1;
        }

        curr_level = @min(self.max_level, level);
        while (true) {
            const top_candidates = try self.searchLayerBase(vec_copy, norm, curr_node, self.ef_construction, curr_level, self.allocator);
            defer self.allocator.free(top_candidates);

            const m_count = @min(top_candidates.len, self.m);
            var new_neighbors = try self.allocator.alloc(u32, m_count);
            for (0..m_count) |i| {
                new_neighbors[i] = @intCast(top_candidates[i].idx);
            }
            self.nodes.items[new_idx].neighbors[curr_level] = new_neighbors;

            for (new_neighbors) |neighbor_u32| {
                const neighbor = @as(usize, neighbor_u32);
                try self.addLink(neighbor, new_idx, curr_level, vec_copy, norm);
            }

            if (top_candidates.len > 0) {
                curr_node = top_candidates[0].idx;
            }

            if (curr_level == 0) break;
            curr_level -= 1;
        }

        if (level > self.max_level) {
            self.max_level = level;
            self.enter_point = new_idx;
        }
    }

    pub fn search(self: *HnswIndex, query_vec: []const f32, k: usize, allocator: std.mem.Allocator) ![]common.SearchHit {
        if (query_vec.len != self.dim) return error.DimensionMismatch;
        if (k == 0) return try allocator.alloc(common.SearchHit, 0);

        self.mutex.lockShared();
        defer self.mutex.unlockShared();

        if (self.enter_point == null) {
            return try allocator.alloc(common.SearchHit, 0);
        }

        var query_norm_sq: f32 = 0;
        for (query_vec) |v| {
            if (!std.math.isFinite(v)) return error.InvalidVectorValue;
            query_norm_sq += v * v;
        }
        const query_norm = if (query_norm_sq > 0) @sqrt(query_norm_sq) else @as(f32, 0);

        var curr_node = self.enter_point.?;
        var curr_score = cosineSimilarityWithNorm(query_vec, query_norm, self.vectors.items[curr_node], self.vector_norms.items[curr_node]);

        var curr_level = self.max_level;
        while (curr_level > 0) {
            var changed = true;
            while (changed) {
                changed = false;
                const neighbors = self.nodes.items[curr_node].neighbors[curr_level];
                for (neighbors) |neighbor_u32| {
                    const neighbor = @as(usize, neighbor_u32);
                    const score = cosineSimilarityWithNorm(query_vec, query_norm, self.vectors.items[neighbor], self.vector_norms.items[neighbor]);
                    if (score > curr_score) {
                        curr_score = score;
                        curr_node = neighbor;
                        changed = true;
                    }
                }
            }
            curr_level -= 1;
        }

        const top_candidates = try self.searchLayerBase(query_vec, query_norm, curr_node, @max(self.ef_search, k), 0, allocator);
        defer allocator.free(top_candidates);

        const result_count = @min(k, top_candidates.len);
        var hits = try allocator.alloc(common.SearchHit, result_count);
        for (0..result_count) |i| {
            hits[i] = .{
                .id = self.nodes.items[top_candidates[i].idx].id,
                .score = top_candidates[i].score,
            };
        }

        return hits;
    }

    fn searchLayerBase(self: *HnswIndex, query_vec: []const f32, query_norm: f32, ep: usize, ef: usize, layer: usize, allocator: std.mem.Allocator) ![]Scored {
        var visited = std.AutoHashMap(usize, void).init(allocator);
        defer visited.deinit();
        try visited.put(ep, {});

        var candidates = try std.ArrayList(Scored).initCapacity(allocator, ef);
        defer candidates.deinit();

        var top_results = try std.ArrayList(Scored).initCapacity(allocator, ef);
        defer top_results.deinit();

        const ep_score = cosineSimilarityWithNorm(query_vec, query_norm, self.vectors.items[ep], self.vector_norms.items[ep]);
        candidates.appendAssumeCapacity(.{ .idx = ep, .score = ep_score });
        top_results.appendAssumeCapacity(.{ .idx = ep, .score = ep_score });

        while (candidates.items.len > 0) {
            var best_cand_idx: usize = 0;
            var best_cand_score = candidates.items[0].score;
            for (candidates.items[1..], 1..) |cand, i| {
                if (cand.score > best_cand_score) {
                    best_cand_score = cand.score;
                    best_cand_idx = i;
                }
            }
            const c = candidates.swapRemove(best_cand_idx);

            const worst_res_score = top_results.items[top_results.items.len - 1].score;
            if (c.score < worst_res_score and top_results.items.len >= ef) {
                break;
            }

            const node_neighbors = self.nodes.items[c.idx].neighbors[layer];
            for (node_neighbors) |neighbor_u32| {
                const neighbor = @as(usize, neighbor_u32);
                if (!visited.contains(neighbor)) {
                    try visited.put(neighbor, {});
                    const score = cosineSimilarityWithNorm(query_vec, query_norm, self.vectors.items[neighbor], self.vector_norms.items[neighbor]);

                    const current_worst = top_results.items[top_results.items.len - 1].score;
                    if (top_results.items.len < ef or score > current_worst) {
                        try candidates.append(.{ .idx = neighbor, .score = score });
                        try insertSorted(&top_results, .{ .idx = neighbor, .score = score }, ef);
                    }
                }
            }
        }

        return top_results.toOwnedSlice();
    }

    fn addLink(self: *HnswIndex, target: usize, new_node: usize, layer: usize, new_vec: []const f32, new_norm: f32) !void {
        const neighbors = self.nodes.items[target].neighbors[layer];
        const max_m = if (layer == 0) self.m * 2 else self.m;

        for (neighbors) |n| {
            if (n == new_node) return;
        }

        if (neighbors.len < max_m) {
            var new_neighbors = try self.allocator.alloc(u32, neighbors.len + 1);
            @memcpy(new_neighbors[0..neighbors.len], neighbors);
            new_neighbors[neighbors.len] = @intCast(new_node);
            self.allocator.free(neighbors);
            self.nodes.items[target].neighbors[layer] = new_neighbors;
        } else {
            var candidates = try self.allocator.alloc(Scored, neighbors.len + 1);
            defer self.allocator.free(candidates);

            for (neighbors, 0..) |n, i| {
                candidates[i] = .{
                    .idx = n,
                    .score = cosineSimilarityWithNorm(self.vectors.items[target], self.vector_norms.items[target], self.vectors.items[n], self.vector_norms.items[n]),
                };
            }
            candidates[neighbors.len] = .{
                .idx = new_node,
                .score = cosineSimilarityWithNorm(self.vectors.items[target], self.vector_norms.items[target], new_vec, new_norm),
            };

            sortScoredDesc(candidates);

            var new_neighbors = try self.allocator.alloc(u32, max_m);
            for (0..max_m) |i| {
                new_neighbors[i] = @intCast(candidates[i].idx);
            }
            self.allocator.free(neighbors);
            self.nodes.items[target].neighbors[layer] = new_neighbors;
        }
    }

    fn randomLevel(self: *const HnswIndex, id: []const u8, vec: []const f32) u32 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(id);
        var len_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &len_bytes, @intCast(self.nodes.items.len), .little);
        hasher.update(&len_bytes);
        if (vec.len > 0) {
            var first_bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &first_bytes, @bitCast(vec[0]), .little);
            hasher.update(&first_bytes);
        }
        var state = hasher.final();
        const divisor = @max(self.m, 2);
        var level: u32 = 0;
        const max_level: u32 = 32;
        while (level < max_level) {
            state = state *% 2862933555777941757 +% 3037000493;
            if (state % @as(u64, @intCast(divisor)) != 0) break;
            level += 1;
        }
        return level;
    }

    fn readBoundedUsize(file: std.fs.File, min: usize, max: usize) !usize {
        const value_u64 = try readIntLe(u64, file);
        const value = std.math.cast(usize, value_u64) orelse return error.Overflow;
        if (value < min or value > max) return error.InvalidParameter;
        return value;
    }
};

fn insertSorted(list: *std.ArrayList(HnswIndex.Scored), item: HnswIndex.Scored, max_len: usize) !void {
    var insert_idx: usize = list.items.len;
    for (list.items, 0..) |existing, i| {
        if (item.score > existing.score) {
            insert_idx = i;
            break;
        }
    }
    try list.insert(insert_idx, item);
    if (list.items.len > max_len) {
        _ = list.pop();
    }
}

fn sortScoredDesc(items: []HnswIndex.Scored) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0 and items[j].score > items[j - 1].score) : (j -= 1) {
            std.mem.swap(HnswIndex.Scored, &items[j], &items[j - 1]);
        }
    }
}

pub fn cosineSimilarity(a: []const f32, b: []const f32) f32 {
    if (a.len != b.len) return 0;

    var norm_b_sq: f32 = 0;
    for (b) |v| {
        if (!std.math.isFinite(v)) return 0;
        norm_b_sq += v * v;
    }
    const norm_b = if (norm_b_sq > 0) @sqrt(norm_b_sq) else @as(f32, 0);
    return cosineSimilarityWithNorm(a, null, b, norm_b);
}

fn cosineSimilarityWithNorm(a: []const f32, a_norm_opt: ?f32, b: []const f32, b_norm: f32) f32 {
    if (a.len != b.len) return 0;
    if (a.len == 0) return 0;

    var dot_product: f32 = 0;
    var norm_a_sq: f32 = 0;

    for (a, b) |av, bv| {
        if (!std.math.isFinite(av) or !std.math.isFinite(bv)) return 0;
        dot_product += av * bv;
        if (a_norm_opt == null) {
            norm_a_sq += av * av;
        }
    }

    const norm_a = if (a_norm_opt) |n| n else if (norm_a_sq > 0) @sqrt(norm_a_sq) else @as(f32, 0);
    if (norm_a <= 0 or b_norm <= 0) return 0;

    const score = dot_product / (norm_a * b_norm);
    if (!std.math.isFinite(score)) return 0;
    return score;
}

fn readExact(file: std.fs.File, buf: []u8) !void {
    var offset: usize = 0;
    while (offset < buf.len) {
        const n = try file.read(buf[offset..]);
        if (n == 0) return error.UnexpectedEndOfFile;
        offset += n;
    }
}

fn readIntLe(comptime T: type, file: std.fs.File) !T {
    var buf: [@sizeOf(T)]u8 = undefined;
    try readExact(file, buf[0..]);
    return std.mem.readInt(T, buf[0..], .little);
}

fn writeIntLe(comptime T: type, file: std.fs.File, value: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, buf[0..], value, .little);
    try file.writeAll(buf[0..]);
}

test "cosine similarity" {
    const a = [_]f32{ 1, 0, 0 };
    const b = [_]f32{ 1, 0, 0 };
    try std.testing.expectApproxEqAbs(@as(f32, 1), cosineSimilarity(&a, &b), 0.001);

    const c = [_]f32{ 1, 0, 0 };
    const d = [_]f32{ 0, 1, 0 };
    try std.testing.expectApproxEqAbs(@as(f32, 0), cosineSimilarity(&c, &d), 0.001);

    const e = [_]f32{ 0, 0, 0 };
    try std.testing.expectApproxEqAbs(@as(f32, 0), cosineSimilarity(&a, &e), 0.001);
}

test "insert and search" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var index = HnswIndex{
        .dim = 3,
        .m = 16,
        .ef_construction = 200,
        .ef_search = 50,
        .enter_point = null,
        .max_level = 0,
        .nodes = .{},
        .vectors = .{},
        .mutex = .{},
        .allocator = allocator,
        .path = try allocator.dupe(u8, "test.hnsw"),
        .vector_norms = .{},
    };
    defer index.deinit();

    try index.insert("a", &[_]f32{ 1, 0, 0 });
    try index.insert("b", &[_]f32{ 0, 1, 0 });
    try index.insert("c", &[_]f32{ 0.9, 0.1, 0 });

    const hits = try index.search(&[_]f32{ 1, 0, 0 }, 2, allocator);
    defer allocator.free(hits);

    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expectEqualStrings("a", hits[0].id);
    try std.testing.expect(hits[0].score >= hits[1].score);
}

test "save and load" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const path = "zig-out/tmp/hnsw_test.bin";

    {
        var index = HnswIndex{
            .dim = 3,
            .m = 8,
            .ef_construction = 100,
            .ef_search = 25,
            .enter_point = null,
            .max_level = 0,
            .nodes = .{},
            .vectors = .{},
            .mutex = .{},
            .allocator = allocator,
            .path = try allocator.dupe(u8, path),
            .vector_norms = .{},
        };
        defer index.deinit();

        try index.insert("x", &[_]f32{ 1, 2, 3 });
        try index.insert("y", &[_]f32{ 4, 5, 6 });

        try index.save(path);
    }

    {
        var loaded = try HnswIndex.load(path, 3, allocator);
        defer loaded.deinit();

        try std.testing.expectEqual(@as(usize, 2), loaded.nodes.items.len);
        try std.testing.expectEqual(@as(usize, 2), loaded.vectors.items.len);
        try std.testing.expectEqual(@as(usize, 2), loaded.vector_norms.items.len);
        try std.testing.expectEqualStrings("x", loaded.nodes.items[0].id);
        try std.testing.expectEqualStrings("y", loaded.nodes.items[1].id);

        const hits = try loaded.search(&[_]f32{ 1, 2, 3 }, 1, allocator);
        defer allocator.free(hits);

        try std.testing.expectEqual(@as(usize, 1), hits.len);
        try std.testing.expectEqualStrings("x", hits[0].id);
    }

    std.fs.cwd().deleteFile(path) catch {};
}
