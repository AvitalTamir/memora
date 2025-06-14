const std = @import("std");
const types = @import("types.zig");
const Memora = @import("main.zig").Memora;
const DistributedMemora = @import("distributed_memora.zig").DistributedMemora;
const config = @import("config.zig");

/// HTTP Status codes
pub const HttpStatus = enum(u16) {
    ok = 200,
    created = 201,
    bad_request = 400,
    not_found = 404,
    method_not_allowed = 405,
    internal_server_error = 500,
    service_unavailable = 503,
};

/// HTTP Methods
pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    DELETE,
    OPTIONS,
    UNKNOWN,

    pub fn fromString(method: []const u8) HttpMethod {
        if (std.mem.eql(u8, method, "GET")) return .GET;
        if (std.mem.eql(u8, method, "POST")) return .POST;
        if (std.mem.eql(u8, method, "PUT")) return .PUT;
        if (std.mem.eql(u8, method, "DELETE")) return .DELETE;
        if (std.mem.eql(u8, method, "OPTIONS")) return .OPTIONS;
        return .UNKNOWN;
    }
};

/// HTTP Request
pub const HttpRequest = struct {
    method: HttpMethod,
    path: []const u8,
    body: []const u8,
    headers: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) HttpRequest {
        return HttpRequest{
            .method = .UNKNOWN,
            .path = "",
            .body = "",
            .headers = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *HttpRequest) void {
        self.headers.deinit();
    }
};

/// HTTP Response
pub const HttpResponse = struct {
    status: HttpStatus,
    body: []const u8,
    content_type: []const u8,

    pub fn init(status: HttpStatus, body: []const u8, content_type: []const u8) HttpResponse {
        return HttpResponse{
            .status = status,
            .body = body,
            .content_type = content_type,
        };
    }

    pub fn json(status: HttpStatus, body: []const u8) HttpResponse {
        return init(status, body, "application/json");
    }

    pub fn text(status: HttpStatus, body: []const u8) HttpResponse {
        return init(status, body, "text/plain");
    }

    pub fn toString(self: HttpResponse) ![]const u8 {
        var response_buf: [8192]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&response_buf);
        const temp_allocator = fba.allocator();

        const http_response = try std.fmt.allocPrint(temp_allocator,
            "HTTP/1.1 {} \r\nContent-Type: {s}\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\n\r\n{s}",
            .{ @intFromEnum(self.status), self.content_type, self.body.len, self.body }
        );

        return http_response[0..];
    }
};

/// JSON request/response types
pub const NodeRequest = struct {
    id: u64,
    label: []const u8,
};

pub const EdgeRequest = struct {
    from: u64,
    to: u64,
    kind: []const u8,
};

pub const VectorRequest = struct {
    id: u64,
    dims: []f32,
};

pub const BatchRequest = struct {
    nodes: []NodeRequest = &[_]NodeRequest{},
    edges: []EdgeRequest = &[_]EdgeRequest{},
    vectors: []VectorRequest = &[_]VectorRequest{},
};

pub const QueryRelatedRequest = struct {
    depth: u8 = 2,
};

pub const QuerySimilarRequest = struct {
    top_k: u32 = 10,
};

pub const QueryHybridRequest = struct {
    depth: u8 = 2,
    top_k: u32 = 10,
};

/// HTTP Server configuration derived from centralized config
pub const HttpConfig = struct {
    port: u16,
    request_buffer_size: u32,
    response_buffer_size: u32,
    bind_address: []const u8,
    memory_warning_bytes: u64,
    memory_critical_bytes: u64,
    error_rate_warning: f32,
    error_rate_critical: f32,
    
    pub fn fromConfig(global_cfg: config.Config, port_override: ?u16) HttpConfig {
        return HttpConfig{
            .port = port_override orelse global_cfg.http_port,
            .request_buffer_size = global_cfg.http_request_buffer_size,
            .response_buffer_size = global_cfg.http_response_buffer_size,
            .bind_address = global_cfg.http_bind_address,
            .memory_warning_bytes = @intFromFloat(global_cfg.health_memory_warning_gb * 1_000_000_000.0),
            .memory_critical_bytes = @intFromFloat(global_cfg.health_memory_critical_gb * 1_000_000_000.0),
            .error_rate_warning = global_cfg.health_error_rate_warning,
            .error_rate_critical = global_cfg.health_error_rate_critical,
        };
    }
};

/// API Server
pub const ApiServer = struct {
    allocator: std.mem.Allocator,
    db: *Memora,
    distributed_db: ?*DistributedMemora,
    port: u16,
    server: ?std.net.Server,
    http_config: HttpConfig,

    pub fn init(allocator: std.mem.Allocator, db: *Memora, distributed_db: ?*DistributedMemora, port: ?u16, global_config: ?config.Config) ApiServer {
        const global_cfg = global_config orelse config.Config{};
        const http_cfg = HttpConfig.fromConfig(global_cfg, port);
        
        return ApiServer{
            .allocator = allocator,
            .db = db,
            .distributed_db = distributed_db,
            .port = http_cfg.port,
            .server = null,
            .http_config = http_cfg,
        };
    }

    pub fn start(self: *ApiServer) !void {
        const address = std.net.Address.parseIp("127.0.0.1", self.port) catch unreachable;
        self.server = try address.listen(.{ .reuse_address = true });
        
        std.debug.print("Memora HTTP API server listening on http://127.0.0.1:{}\n", .{self.port});
        std.debug.print("Available endpoints:\n");
        std.debug.print("  POST   /api/v1/nodes           - Insert node\n");
        std.debug.print("  GET    /api/v1/nodes/:id       - Get node\n");
        std.debug.print("  GET    /api/v1/nodes/:id/related - Get related nodes\n");
        std.debug.print("  POST   /api/v1/edges           - Insert edge\n");
        std.debug.print("  POST   /api/v1/vectors         - Insert vector\n");
        std.debug.print("  GET    /api/v1/vectors/:id/similar - Get similar vectors\n");
        std.debug.print("  POST   /api/v1/batch           - Batch insert\n");
        std.debug.print("  POST   /api/v1/query/hybrid    - Hybrid query\n");
        std.debug.print("  GET    /api/v1/health          - Health check\n");
        std.debug.print("  GET    /api/v1/metrics         - Database metrics\n");
        std.debug.print("  POST   /api/v1/snapshot        - Create snapshot\n");

        while (true) {
            const connection = self.server.?.accept() catch |err| {
                std.debug.print("Failed to accept connection: {}\n", .{err});
                continue;
            };
            
            // Handle each connection in a separate thread for better concurrency
            const thread = std.Thread.spawn(.{}, handleConnection, .{ self, connection }) catch |err| {
                std.debug.print("Failed to spawn thread: {}\n", .{err});
                connection.stream.close();
                continue;
            };
            thread.detach();
        }
    }

    pub fn stop(self: *ApiServer) void {
        if (self.server) |*server| {
            server.deinit();
            self.server = null;
        }
    }

    fn handleConnection(self: *ApiServer, connection: std.net.Server.Connection) void {
        defer connection.stream.close();
        
        // Track active connection
        self.db.metrics.incrementActiveConnections();
        defer self.db.metrics.decrementActiveConnections();
        
        // Use configurable buffer size
        const buffer = self.allocator.alloc(u8, self.http_config.request_buffer_size) catch {
            std.debug.print("Failed to allocate request buffer\n", .{});
            return;
        };
        defer self.allocator.free(buffer);
        
        var request_start: usize = 0;
        
        while (true) {
            const bytes_read = connection.stream.read(buffer[request_start..]) catch |err| {
                std.debug.print("Error reading from connection: {}\n", .{err});
                return;
            };
            
            if (bytes_read == 0) break; // Connection closed by client
            
            request_start += bytes_read;
            
            // Try to parse a complete HTTP request
            if (std.mem.indexOf(u8, buffer[0..request_start], "\r\n\r\n")) |end| {
                const request_data = buffer[0..end + 4];
                
                const request = self.parseHttpRequest(request_data) catch |err| {
                    std.debug.print("Error parsing HTTP request: {}\n", .{err});
                    const error_response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 11\r\n\r\nBad Request";
                    _ = connection.stream.writeAll(error_response) catch {};
                    return;
                };
                
                const response = self.handleRequest(&request) catch |err| {
                    std.debug.print("Error handling request: {}\n", .{err});
                    return HttpResponse.text(.internal_server_error, "Internal Server Error");
                };
                
                const response_text = response.toString() catch |err| {
                    std.debug.print("Error formatting response: {}\n", .{err});
                    const fallback_response = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 21\r\n\r\nInternal Server Error";
                    _ = connection.stream.writeAll(fallback_response) catch {};
                    return;
                };
                defer self.allocator.free(response_text);
                
                _ = connection.stream.writeAll(response_text) catch |err| {
                    std.debug.print("Error writing response: {}\n", .{err});
                    return;
                };
                
                // Reset buffer for next request
                if (request_start > end + 4) {
                    std.mem.copyForwards(u8, buffer[0..], buffer[end + 4..request_start]);
                    request_start -= (end + 4);
                } else {
                    request_start = 0;
                }
            }
            
            // Prevent buffer overflow
            if (request_start >= buffer.len) {
                std.debug.print("Request too large, closing connection\n", .{});
                return;
            }
        }
    }

    pub fn parseHttpRequest(self: *ApiServer, data: []const u8) !HttpRequest {
        var request = HttpRequest.init(self.allocator);
        var lines = std.mem.splitSequence(u8, data, "\r\n");
        
        // Parse request line
        if (lines.next()) |request_line| {
            var parts = std.mem.splitSequence(u8, request_line, " ");
            const method_str = parts.next() orelse return error.InvalidRequest;
            request.method = HttpMethod.fromString(method_str);
            request.path = parts.next() orelse return error.InvalidRequest;
        } else {
            return error.InvalidRequest;
        }

        // Find body (after empty line)
        var found_empty_line = false;
        while (lines.next()) |line| {
            if (line.len == 0) {
                found_empty_line = true;
                break;
            }
            // Parse headers if needed
        }

        if (found_empty_line) {
            if (lines.next()) |body| {
                request.body = body;
            }
        }

        return request;
    }

    fn handleRequest(self: *ApiServer, request: *const HttpRequest) !HttpResponse {
        // Handle OPTIONS for CORS
        if (request.method == .OPTIONS) {
            return HttpResponse.text(.ok, "");
        }

        // Route requests
        if (std.mem.startsWith(u8, request.path, "/api/v1/")) {
            return self.handleApiRequest(request);
        }

        return HttpResponse.text(.not_found, "Not Found");
    }

    fn handleApiRequest(self: *ApiServer, request: *const HttpRequest) !HttpResponse {
        const path = request.path[8..]; // Remove "/api/v1/"

        // Health check endpoint
        if (std.mem.eql(u8, path, "health")) {
            if (request.method != .GET) {
                return HttpResponse.text(.method_not_allowed, "Method not allowed");
            }
            return try self.handleHealth();
        }

        // Metrics endpoint
        if (std.mem.eql(u8, path, "metrics")) {
            if (request.method != .GET) {
                return HttpResponse.text(.method_not_allowed, "Method not allowed");
            }
            return try self.handleMetrics();
        }

        // Snapshot endpoint
        if (std.mem.eql(u8, path, "snapshot")) {
            if (request.method != .POST) {
                return HttpResponse.text(.method_not_allowed, "Method not allowed");
            }
            return try self.handleCreateSnapshot();
        }

        // Batch endpoint
        if (std.mem.eql(u8, path, "batch")) {
            if (request.method != .POST) {
                return HttpResponse.text(.method_not_allowed, "Method not allowed");
            }
            return try self.handleBatch(request);
        }

        // Node endpoints
        if (std.mem.startsWith(u8, path, "nodes")) {
            return self.handleNodeRequest(request, path[5..]);
        }

        // Edge endpoints
        if (std.mem.startsWith(u8, path, "edges")) {
            return self.handleEdgeRequest(request, path[5..]);
        }

        // Vector endpoints
        if (std.mem.startsWith(u8, path, "vectors")) {
            return self.handleVectorRequest(request, path[7..]);
        }

        // Query endpoints
        if (std.mem.startsWith(u8, path, "query")) {
            return self.handleQueryRequest(request, path[5..]);
        }

        return HttpResponse.text(.not_found, "Endpoint not found");
    }

    fn handleHealth(self: *ApiServer) !HttpResponse {
        const response_buf = try self.allocator.alloc(u8, self.http_config.response_buffer_size);
        defer self.allocator.free(response_buf);
        var fba = std.heap.FixedBufferAllocator.init(response_buf);
        const temp_allocator = fba.allocator();

        // Perform comprehensive health checks
        var health_check = self.db.monitoring.HealthCheck.init(temp_allocator);
        defer health_check.deinit();
        
        // Database connectivity check
        const db_check_start = std.time.nanoTimestamp();
        const stats = self.db.getStats();
        const db_check_time = @divTrunc(std.time.nanoTimestamp() - db_check_start, 1000);
        
        const db_status = if (stats.node_count >= 0 and stats.edge_count >= 0 and stats.vector_count >= 0) 
            self.db.monitoring.HealthStatus.healthy 
        else 
            self.db.monitoring.HealthStatus.unhealthy;
            
        try health_check.addCheck("database_connectivity", db_status, "Database is accessible and returning valid statistics", @intCast(db_check_time));
        
        // Memory usage check
        const memory_check_start = std.time.nanoTimestamp();
        const memory_usage = self.db.metrics.memory_usage_bytes.get();
        const memory_check_time = @divTrunc(std.time.nanoTimestamp() - memory_check_start, 1000);
        
        const memory_status = if (memory_usage < self.http_config.memory_warning_bytes)
            self.db.monitoring.HealthStatus.healthy
        else if (memory_usage < self.http_config.memory_critical_bytes)
            self.db.monitoring.HealthStatus.degraded
        else
            self.db.monitoring.HealthStatus.unhealthy;
            
        const memory_message = try std.fmt.allocPrint(temp_allocator, "Memory usage: {} bytes", .{memory_usage});
        try health_check.addCheck("memory_usage", memory_status, memory_message, @intCast(memory_check_time));
        
        // Error rate check
        const error_check_start = std.time.nanoTimestamp();
        const error_rate = self.db.metrics.getErrorRate();
        const error_check_time = @divTrunc(std.time.nanoTimestamp() - error_check_start, 1000);
        
        const error_status = if (error_rate < self.http_config.error_rate_warning)
            self.db.monitoring.HealthStatus.healthy
        else if (error_rate < self.http_config.error_rate_critical)
            self.db.monitoring.HealthStatus.degraded
        else
            self.db.monitoring.HealthStatus.unhealthy;
            
        const error_message = try std.fmt.allocPrint(temp_allocator, "Error rate: {d:.2}%", .{error_rate});
        try health_check.addCheck("error_rate", error_status, error_message, @intCast(error_check_time));
        
        // Distributed system check (if applicable)
        if (self.distributed_db) |dist_db| {
            const cluster_check_start = std.time.nanoTimestamp();
            const is_leader = dist_db.isLeader();
            const cluster_check_time = @divTrunc(std.time.nanoTimestamp() - cluster_check_start, 1000);
            
            const cluster_status = self.db.monitoring.HealthStatus.healthy;
            const cluster_message = if (is_leader) "Acting as cluster leader" else "Acting as cluster follower";
            try health_check.addCheck("cluster_status", cluster_status, cluster_message, @intCast(cluster_check_time));
        }

        // Generate JSON response
        const health_json = try health_check.exportJson(temp_allocator);
        return HttpResponse.json(.ok, health_json);
    }

    fn handleMetrics(self: *ApiServer) !HttpResponse {
        var response_buf: [8192]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&response_buf);
        const temp_allocator = fba.allocator();

        // Update database statistics in metrics
        _ = self.db.getStats();
        
        // Update memory usage (basic estimation)
        // In a real implementation, you'd use a proper memory tracker
        self.db.metrics.updateMemoryUsage(10_000_000); // 10MB baseline estimate
        
        // Check if Prometheus format is requested
        const accept_header = ""; // Would need to parse from actual request headers
        const wants_prometheus = std.mem.indexOf(u8, accept_header, "text/plain") != null;
        
        if (wants_prometheus) {
            // Return Prometheus format
            const prometheus_metrics = try self.db.metrics.exportPrometheusMetrics(temp_allocator);
            return HttpResponse{
                .status = .ok,
                .headers = "Content-Type: text/plain; version=0.0.4\r\n",
                .body = prometheus_metrics,
            };
        } else {
            // Return JSON format
            const json_metrics = try self.db.metrics.exportJsonMetrics(temp_allocator);
            return HttpResponse.json(.ok, json_metrics);
        }
    }

    fn handleCreateSnapshot(self: *ApiServer) !HttpResponse {
        const snapshot_info = self.db.createSnapshot() catch |err| {
            std.debug.print("Failed to create snapshot: {}\n", .{err});
            return HttpResponse.json(.internal_server_error, "{\"error\":\"Failed to create snapshot\"}");
        };

        var response_buf: [256]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&response_buf);
        const temp_allocator = fba.allocator();

        const response = try std.fmt.allocPrint(temp_allocator,
            "{{\"snapshot_id\":{},\"timestamp\":{}}}", 
            .{ snapshot_info.snapshot_id, std.time.timestamp() }
        );

        return HttpResponse.json(.created, response);
    }

    fn handleNodeRequest(self: *ApiServer, request: *const HttpRequest, sub_path: []const u8) !HttpResponse {
        if (sub_path.len == 0) {
            // POST /api/v1/nodes - Insert node
            if (request.method != .POST) {
                return HttpResponse.text(.method_not_allowed, "Method not allowed");
            }
            return try self.handleInsertNode(request);
        }

        // Parse node ID from path
        var parts = std.mem.splitSequence(u8, sub_path[1..], "/"); // Skip leading "/"
        const id_str = parts.next() orelse return HttpResponse.text(.bad_request, "Invalid node ID");
        const node_id = std.fmt.parseInt(u64, id_str, 10) catch {
            return HttpResponse.text(.bad_request, "Invalid node ID format");
        };

        const sub_resource = parts.next();
        if (sub_resource) |resource| {
            if (std.mem.eql(u8, resource, "related")) {
                // GET /api/v1/nodes/:id/related
                if (request.method != .GET) {
                    return HttpResponse.text(.method_not_allowed, "Method not allowed");
                }
                return try self.handleQueryRelated(node_id, request);
            }
        } else {
            // GET /api/v1/nodes/:id
            if (request.method != .GET) {
                return HttpResponse.text(.method_not_allowed, "Method not allowed");
            }
            return try self.handleGetNode(node_id);
        }

        return HttpResponse.text(.not_found, "Node endpoint not found");
    }

    fn handleInsertNode(self: *ApiServer, request: *const HttpRequest) !HttpResponse {
        var json_parser = std.json.parseFromSlice(NodeRequest, self.allocator, request.body, .{}) catch {
            return HttpResponse.json(.bad_request, "{\"error\":\"Invalid JSON format\"}");
        };
        defer json_parser.deinit();

        const node_req = json_parser.value;
        const node = types.Node.init(node_req.id, node_req.label);

        if (self.distributed_db) |dist_db| {
            dist_db.insertNode(node) catch |err| {
                std.debug.print("Failed to insert node: {}\n", .{err});
                return HttpResponse.json(.internal_server_error, "{\"error\":\"Failed to insert node\"}");
            };
        } else {
            self.db.insertNode(node) catch |err| {
                std.debug.print("Failed to insert node: {}\n", .{err});
                return HttpResponse.json(.internal_server_error, "{\"error\":\"Failed to insert node\"}");
            };
        }

        var response_buf: [128]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&response_buf);
        const temp_allocator = fba.allocator();

        const response = try std.fmt.allocPrint(temp_allocator, "{{\"id\":{},\"status\":\"created\"}}", .{node.id});
        return HttpResponse.json(.created, response);
    }

    fn handleGetNode(self: *ApiServer, node_id: u64) !HttpResponse {
        // For now, return a simple response indicating the node exists if we can find it in related queries
        // This could be enhanced with a proper node lookup method
        const related = self.db.queryRelated(node_id, 0) catch {
            return HttpResponse.json(.not_found, "{\"error\":\"Node not found\"}");
        };
        defer related.deinit();

        var response_buf: [256]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&response_buf);
        const temp_allocator = fba.allocator();

        const response = try std.fmt.allocPrint(temp_allocator, "{{\"id\":{},\"exists\":true}}", .{node_id});
        return HttpResponse.json(.ok, response);
    }

    fn handleQueryRelated(self: *ApiServer, node_id: u64, request: *const HttpRequest) !HttpResponse {
        var depth: u8 = 2;
        
        // Parse query parameters from request body if provided
        if (request.body.len > 0) {
            var json_parser = std.json.parseFromSlice(QueryRelatedRequest, self.allocator, request.body, .{}) catch {
                return HttpResponse.json(.bad_request, "{\"error\":\"Invalid JSON format\"}");
            };
            defer json_parser.deinit();
            depth = json_parser.value.depth;
        }

        const related = self.db.queryRelated(node_id, depth) catch |err| {
            std.debug.print("Failed to query related nodes: {}\n", .{err});
            return HttpResponse.json(.internal_server_error, "{\"error\":\"Failed to query related nodes\"}");
        };
        defer related.deinit();

        // Build JSON response
        var response_list = std.ArrayList(u8).init(self.allocator);
        defer response_list.deinit();

        try response_list.appendSlice("{\"nodes\":[");
        for (related.items, 0..) |node, i| {
            if (i > 0) try response_list.appendSlice(",");
            const node_json = try std.fmt.allocPrint(self.allocator, "{{\"id\":{},\"label\":\"{s}\"}}", .{ node.id, node.getLabelAsString() });
            defer self.allocator.free(node_json);
            try response_list.appendSlice(node_json);
        }
        try response_list.appendSlice("]}");

        return HttpResponse.json(.ok, response_list.items);
    }

    fn handleEdgeRequest(self: *ApiServer, request: *const HttpRequest, sub_path: []const u8) !HttpResponse {
        if (sub_path.len == 0) {
            // POST /api/v1/edges - Insert edge
            if (request.method != .POST) {
                return HttpResponse.text(.method_not_allowed, "Method not allowed");
            }
            return try self.handleInsertEdge(request);
        }

        return HttpResponse.text(.not_found, "Edge endpoint not found");
    }

    fn handleInsertEdge(self: *ApiServer, request: *const HttpRequest) !HttpResponse {
        var json_parser = std.json.parseFromSlice(EdgeRequest, self.allocator, request.body, .{}) catch {
            return HttpResponse.json(.bad_request, "{\"error\":\"Invalid JSON format\"}");
        };
        defer json_parser.deinit();

        const edge_req = json_parser.value;
        const edge_kind = if (std.mem.eql(u8, edge_req.kind, "owns")) types.EdgeKind.owns
        else if (std.mem.eql(u8, edge_req.kind, "links")) types.EdgeKind.links
        else if (std.mem.eql(u8, edge_req.kind, "related")) types.EdgeKind.related
        else if (std.mem.eql(u8, edge_req.kind, "child_of")) types.EdgeKind.child_of
        else if (std.mem.eql(u8, edge_req.kind, "similar_to")) types.EdgeKind.similar_to
        else types.EdgeKind.related;

        const edge = types.Edge.init(edge_req.from, edge_req.to, edge_kind);

        if (self.distributed_db) |dist_db| {
            dist_db.insertEdge(edge) catch |err| {
                std.debug.print("Failed to insert edge: {}\n", .{err});
                return HttpResponse.json(.internal_server_error, "{\"error\":\"Failed to insert edge\"}");
            };
        } else {
            self.db.insertEdge(edge) catch |err| {
                std.debug.print("Failed to insert edge: {}\n", .{err});
                return HttpResponse.json(.internal_server_error, "{\"error\":\"Failed to insert edge\"}");
            };
        }

        var response_buf: [128]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&response_buf);
        const temp_allocator = fba.allocator();

        const response = try std.fmt.allocPrint(temp_allocator, "{{\"from\":{},\"to\":{},\"status\":\"created\"}}", .{ edge.from, edge.to });
        return HttpResponse.json(.created, response);
    }

    fn handleVectorRequest(self: *ApiServer, request: *const HttpRequest, sub_path: []const u8) !HttpResponse {
        if (sub_path.len == 0) {
            // POST /api/v1/vectors - Insert vector
            if (request.method != .POST) {
                return HttpResponse.text(.method_not_allowed, "Method not allowed");
            }
            return try self.handleInsertVector(request);
        }

        // Parse vector ID from path
        var parts = std.mem.splitSequence(u8, sub_path[1..], "/"); // Skip leading "/"
        const id_str = parts.next() orelse return HttpResponse.text(.bad_request, "Invalid vector ID");
        const vector_id = std.fmt.parseInt(u64, id_str, 10) catch {
            return HttpResponse.text(.bad_request, "Invalid vector ID format");
        };

        const sub_resource = parts.next();
        if (sub_resource) |resource| {
            if (std.mem.eql(u8, resource, "similar")) {
                // GET /api/v1/vectors/:id/similar
                if (request.method != .GET) {
                    return HttpResponse.text(.method_not_allowed, "Method not allowed");
                }
                return try self.handleQuerySimilar(vector_id, request);
            }
        }

        return HttpResponse.text(.not_found, "Vector endpoint not found");
    }

    fn handleInsertVector(self: *ApiServer, request: *const HttpRequest) !HttpResponse {
        var json_parser = std.json.parseFromSlice(VectorRequest, self.allocator, request.body, .{}) catch {
            return HttpResponse.json(.bad_request, "{\"error\":\"Invalid JSON format\"}");
        };
        defer json_parser.deinit();

        const vector_req = json_parser.value;
        const vector = types.Vector.init(vector_req.id, vector_req.dims);

        if (self.distributed_db) |dist_db| {
            dist_db.insertVector(vector) catch |err| {
                std.debug.print("Failed to insert vector: {}\n", .{err});
                return HttpResponse.json(.internal_server_error, "{\"error\":\"Failed to insert vector\"}");
            };
        } else {
            self.db.insertVector(vector) catch |err| {
                std.debug.print("Failed to insert vector: {}\n", .{err});
                return HttpResponse.json(.internal_server_error, "{\"error\":\"Failed to insert vector\"}");
            };
        }

        var response_buf: [128]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&response_buf);
        const temp_allocator = fba.allocator();

        const response = try std.fmt.allocPrint(temp_allocator, "{{\"id\":{},\"status\":\"created\"}}", .{vector.id});
        return HttpResponse.json(.created, response);
    }

    fn handleQuerySimilar(self: *ApiServer, vector_id: u64, request: *const HttpRequest) !HttpResponse {
        var top_k: u32 = 10;
        
        // Parse query parameters from request body if provided
        if (request.body.len > 0) {
            var json_parser = std.json.parseFromSlice(QuerySimilarRequest, self.allocator, request.body, .{}) catch {
                return HttpResponse.json(.bad_request, "{\"error\":\"Invalid JSON format\"}");
            };
            defer json_parser.deinit();
            top_k = json_parser.value.top_k;
        }

        const similar = self.db.querySimilar(vector_id, top_k) catch |err| {
            std.debug.print("Failed to query similar vectors: {}\n", .{err});
            return HttpResponse.json(.internal_server_error, "{\"error\":\"Failed to query similar vectors\"}");
        };
        defer similar.deinit();

        // Build JSON response
        var response_list = std.ArrayList(u8).init(self.allocator);
        defer response_list.deinit();

        try response_list.appendSlice("{\"vectors\":[");
        for (similar.items, 0..) |result, i| {
            if (i > 0) try response_list.appendSlice(",");
            const result_json = try std.fmt.allocPrint(self.allocator, "{{\"id\":{},\"similarity\":{d:.6}}}", .{ result.id, result.similarity });
            defer self.allocator.free(result_json);
            try response_list.appendSlice(result_json);
        }
        try response_list.appendSlice("]}");

        return HttpResponse.json(.ok, response_list.items);
    }

    fn handleQueryRequest(self: *ApiServer, request: *const HttpRequest, sub_path: []const u8) !HttpResponse {
        if (std.mem.startsWith(u8, sub_path, "/hybrid")) {
            if (request.method != .POST) {
                return HttpResponse.text(.method_not_allowed, "Method not allowed");
            }
            return try self.handleQueryHybrid(request);
        }

        return HttpResponse.text(.not_found, "Query endpoint not found");
    }

    fn handleQueryHybrid(self: *ApiServer, request: *const HttpRequest) !HttpResponse {
        var json_parser = std.json.parseFromSlice(struct {
            node_id: u64,
            depth: u8 = 2,
            top_k: u32 = 10,
        }, self.allocator, request.body, .{}) catch {
            return HttpResponse.json(.bad_request, "{\"error\":\"Invalid JSON format\"}");
        };
        defer json_parser.deinit();

        const hybrid_req = json_parser.value;
        const hybrid_result = self.db.queryHybrid(hybrid_req.node_id, hybrid_req.depth, hybrid_req.top_k) catch |err| {
            std.debug.print("Failed to execute hybrid query: {}\n", .{err});
            return HttpResponse.json(.internal_server_error, "{\"error\":\"Failed to execute hybrid query\"}");
        };
        defer hybrid_result.deinit();

        // Build JSON response
        var response_list = std.ArrayList(u8).init(self.allocator);
        defer response_list.deinit();

        try response_list.appendSlice("{\"related_nodes\":[");
        for (hybrid_result.related_nodes.items, 0..) |node, i| {
            if (i > 0) try response_list.appendSlice(",");
            const node_json = try std.fmt.allocPrint(self.allocator, "{{\"id\":{},\"label\":\"{s}\"}}", .{ node.id, node.getLabelAsString() });
            defer self.allocator.free(node_json);
            try response_list.appendSlice(node_json);
        }
        try response_list.appendSlice("],\"similar_vectors\":[");
        for (hybrid_result.similar_vectors.items, 0..) |result, i| {
            if (i > 0) try response_list.appendSlice(",");
            const result_json = try std.fmt.allocPrint(self.allocator, "{{\"id\":{},\"similarity\":{d:.6}}}", .{ result.id, result.similarity });
            defer self.allocator.free(result_json);
            try response_list.appendSlice(result_json);
        }
        try response_list.appendSlice("]}");

        return HttpResponse.json(.ok, response_list.items);
    }

    fn handleBatch(self: *ApiServer, request: *const HttpRequest) !HttpResponse {
        var json_parser = std.json.parseFromSlice(BatchRequest, self.allocator, request.body, .{}) catch {
            return HttpResponse.json(.bad_request, "{\"error\":\"Invalid JSON format\"}");
        };
        defer json_parser.deinit();

        const batch_req = json_parser.value;
        
        // Convert request types to Memora types
        var nodes = std.ArrayList(types.Node).init(self.allocator);
        defer nodes.deinit();
        for (batch_req.nodes) |node_req| {
            try nodes.append(types.Node.init(node_req.id, node_req.label));
        }

        var edges = std.ArrayList(types.Edge).init(self.allocator);
        defer edges.deinit();
        for (batch_req.edges) |edge_req| {
            const edge_kind = if (std.mem.eql(u8, edge_req.kind, "owns")) types.EdgeKind.owns
            else if (std.mem.eql(u8, edge_req.kind, "links")) types.EdgeKind.links
            else if (std.mem.eql(u8, edge_req.kind, "related")) types.EdgeKind.related
            else if (std.mem.eql(u8, edge_req.kind, "child_of")) types.EdgeKind.child_of
            else if (std.mem.eql(u8, edge_req.kind, "similar_to")) types.EdgeKind.similar_to
            else types.EdgeKind.related;
            try edges.append(types.Edge.init(edge_req.from, edge_req.to, edge_kind));
        }

        var vectors = std.ArrayList(types.Vector).init(self.allocator);
        defer vectors.deinit();
        for (batch_req.vectors) |vector_req| {
            try vectors.append(types.Vector.init(vector_req.id, vector_req.dims));
        }

        // Execute batch insert
        if (self.distributed_db) |dist_db| {
            dist_db.insertBatch(nodes.items, edges.items, vectors.items) catch |err| {
                std.debug.print("Failed to execute batch insert: {}\n", .{err});
                return HttpResponse.json(.internal_server_error, "{\"error\":\"Failed to execute batch insert\"}");
            };
        } else {
            self.db.insertBatch(nodes.items, edges.items, vectors.items) catch |err| {
                std.debug.print("Failed to execute batch insert: {}\n", .{err});
                return HttpResponse.json(.internal_server_error, "{\"error\":\"Failed to execute batch insert\"}");
            };
        }

        var response_buf: [256]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&response_buf);
        const temp_allocator = fba.allocator();

        const response = try std.fmt.allocPrint(temp_allocator, 
            "{{\"inserted\":{{\"nodes\":{},\"edges\":{},\"vectors\":{}}},\"status\":\"created\"}}", 
            .{ nodes.items.len, edges.items.len, vectors.items.len }
        );
        return HttpResponse.json(.created, response);
    }
}; 