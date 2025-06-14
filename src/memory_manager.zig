const std = @import("std");
const types = @import("types.zig");
const memory_types = @import("memory_types.zig");
const main = @import("main.zig");

const Memora = main.Memora;
const Memory = memory_types.Memory;
const MemoryType = memory_types.MemoryType;
const MemoryRelation = memory_types.MemoryRelation;
const MemoryRelationType = memory_types.MemoryRelationType;
const MemorySession = memory_types.MemorySession;
const MemoryQuery = memory_types.MemoryQuery;
const MemoryQueryResult = memory_types.MemoryQueryResult;
const MemoryStatistics = memory_types.MemoryStatistics;
const MemoryConfidence = memory_types.MemoryConfidence;
const MemoryImportance = memory_types.MemoryImportance;
const MemorySource = memory_types.MemorySource;

/// High-level memory manager for LLM operations
/// Provides semantic memory operations built on Memora's infrastructure
pub const MemoryManager = struct {
    allocator: std.mem.Allocator,
    memora: *Memora,
    
    // Memory content storage (memory ID -> content mapping)
    memory_content: std.AutoHashMap(u64, []u8),
    
    // Session management
    sessions: std.AutoHashMap(u64, MemorySession),
    current_session_id: u64,
    
    // Memory ID generation
    next_memory_id: u64,
    next_session_id: u64,
    
    // Embedding cache for semantic search
    embedding_cache: std.AutoHashMap(u64, [128]f32),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, memora: *Memora) Self {
        var manager = Self{
            .allocator = allocator,
            .memora = memora,
            .memory_content = std.AutoHashMap(u64, []u8).init(allocator),
            .sessions = std.AutoHashMap(u64, MemorySession).init(allocator),
            .current_session_id = 0,
            .next_memory_id = 1,
            .next_session_id = 1,
            .embedding_cache = std.AutoHashMap(u64, [128]f32).init(allocator),
        };
        
        // Load existing memory content from the log
        manager.loadExistingMemories() catch |err| {
            // If we can't load existing memories, continue with empty state
            std.debug.print("Warning: Failed to load existing memories from snapshots and log: {}\n", .{err});
            std.debug.print("MemoryManager will start with empty state\n", .{});
        };
        
        std.debug.print("MemoryManager initialized with {} memories in cache\n", .{manager.memory_content.count()});
        
        return manager;
    }
    
    pub fn deinit(self: *Self) void {
        // Clean up memory content strings
        var content_iter = self.memory_content.iterator();
        while (content_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.memory_content.deinit();
        
        self.sessions.deinit();
        self.embedding_cache.deinit();
    }
    
    /// Store a new memory with LLM-specific metadata
    pub fn storeMemory(self: *Self, memory_type: MemoryType, content: []const u8, options: struct {
        confidence: ?MemoryConfidence = null,
        importance: ?MemoryImportance = null,
        source: ?MemorySource = null,
        session_id: ?u64 = null,
        user_id: ?u64 = null,
        create_embedding: bool = true,
    }) !u64 {
        const memory_id = self.next_memory_id;
        self.next_memory_id += 1;
        
        // Create memory with metadata
        var memory = Memory.init(memory_id, memory_type, content);
        
        // Apply options
        if (options.confidence) |conf| memory.confidence = conf;
        if (options.importance) |imp| memory.importance = imp;
        if (options.source) |src| memory.source = src;
        if (options.session_id) |sid| memory.session_id = sid;
        if (options.user_id) |uid| memory.user_id = uid;
        
        // Store full content in the log for persistence (Node label is limited to 32 bytes)
        const content_log_entry = types.LogEntry.initMemoryContent(memory_id, content);
        try self.memora.append_log.append(content_log_entry);
        
        // Also store in in-memory cache for fast access
        const content_copy = try self.allocator.dupe(u8, content);
        try self.memory_content.put(memory_id, content_copy);
        
        // Convert to Node and store in underlying database
        const node = memory.toNode();
        try self.memora.insertNode(node);
        
        // Create semantic embedding if requested
        if (options.create_embedding) {
            const embedding = try self.generateEmbedding(content);
            const vector = types.Vector.init(memory_id, &embedding);
            try self.memora.insertVector(vector);
            try self.embedding_cache.put(memory_id, embedding);
        }
        
        // If this memory belongs to current session, update session activity
        if (options.session_id) |sid| {
            if (self.sessions.getPtr(sid)) |session| {
                                 session.last_active = @as(u64, @intCast(std.time.timestamp()));
                session.interaction_count += 1;
            }
        }
        
        return memory_id;
    }
    
    /// Create a relationship between two memories
    pub fn createRelationship(self: *Self, from_memory_id: u64, to_memory_id: u64, relation_type: MemoryRelationType, options: struct {
        strength: ?f32 = null,
        source: ?MemorySource = null,
    }) !void {
        var relation = MemoryRelation.init(from_memory_id, to_memory_id, relation_type);
        
        if (options.strength) |strength| relation.strength = strength;
        if (options.source) |source| relation.created_by = source;
        
        const edge = relation.toEdge();
        try self.memora.insertEdge(edge);
    }
    
    /// Retrieve memories based on query criteria
    pub fn queryMemories(self: *Self, query: MemoryQuery) !MemoryQueryResult {
        const start_time = std.time.nanoTimestamp();
        var result = MemoryQueryResult.init(self.allocator);
        
        // Vector-based semantic search if query text is provided
        if (query.query_text) |text| {
            try self.performSemanticSearch(&result, text, query);
        }
        
        // Graph-based filtering and traversal
        try self.performGraphSearch(&result, query);
        
        // Apply filters
        try self.applyFilters(&result, query);
        
        // Include related memories if requested
        if (query.include_related) {
            try self.includeRelatedMemories(&result, query);
        }
        
        // Sort and limit results
        try self.sortAndLimitResults(&result, query);
        
        const end_time = std.time.nanoTimestamp();
        result.execution_time_ms = @intCast(@divTrunc(end_time - start_time, 1_000_000));
        
        return result;
    }
    
    /// Retrieve a specific memory by ID
    pub fn getMemory(self: *Self, memory_id: u64) !?Memory {
        // Get the node from underlying database
        const node = self.memora.graph_index.getNode(memory_id) orelse return null;
        
        // Get the full content from cache or load from log
        var content = self.memory_content.get(memory_id);
        if (content == null) {
            // Content not in cache, try to load from log
            if (try self.loadContentFromLog(memory_id)) |log_content| {
                // Cache the loaded content
                const content_copy = try self.allocator.dupe(u8, log_content);
                try self.memory_content.put(memory_id, content_copy);
                content = self.memory_content.get(memory_id);
            }
        }
        
        // If we still don't have content, this memory is corrupted/incomplete
        const final_content = content orelse {
            std.debug.print("Warning: Memory {} exists as node but has no content - data may be corrupted\n", .{memory_id});
            return null; // Return null instead of creating placeholder content
        };
        
        // Reconstruct memory
        var memory = Memory.fromNode(node, final_content);
        
        // Update access tracking
        memory.markAccessed();
        
        // Update the node in the database with new access info
        const updated_node = memory.toNode();
        try self.memora.insertNode(updated_node); // This will overwrite existing
        
        return memory;
    }
    
    /// Create a new conversation session
    pub fn createSession(self: *Self, user_id: u64, title: []const u8, context: ?[]const u8) !u64 {
        const session_id = self.next_session_id;
        self.next_session_id += 1;
        
        var session = MemorySession.init(session_id, user_id, title);
        
        if (context) |ctx| {
            const copy_len = @min(ctx.len, 256);
            @memcpy(session.context[0..copy_len], ctx[0..copy_len]);
        }
        
        try self.sessions.put(session_id, session);
        self.current_session_id = session_id;
        
        return session_id;
    }
    
    /// Set the current active session
    pub fn setCurrentSession(self: *Self, session_id: u64) void {
        self.current_session_id = session_id;
    }
    
    /// Get current session information
    pub fn getCurrentSession(self: *Self) ?MemorySession {
        return self.sessions.get(self.current_session_id);
    }
    
    /// Update a memory's content and metadata
    pub fn updateMemory(self: *Self, memory_id: u64, new_content: ?[]const u8, updates: struct {
        confidence: ?MemoryConfidence = null,
        importance: ?MemoryImportance = null,
        memory_type: ?MemoryType = null,
    }) !void {
        // Get existing memory
        var memory = (try self.getMemory(memory_id)) orelse return error.MemoryNotFound;
        
        // Apply updates
        if (updates.confidence) |conf| memory.confidence = conf;
        if (updates.importance) |imp| memory.importance = imp;
        if (updates.memory_type) |mt| memory.memory_type = mt;
        
        // Update content if provided
        if (new_content) |content| {
            // Free old content and store new
            if (self.memory_content.get(memory_id)) |old_content| {
                self.allocator.free(old_content);
            }
            
            const content_copy = try self.allocator.dupe(u8, content);
            try self.memory_content.put(memory_id, content_copy);
            
            // Update memory content array
            const copy_len = @min(content.len, 256);
            @memset(memory.content[0..], 0);
            @memcpy(memory.content[0..copy_len], content[0..copy_len]);
            
            // Regenerate embedding
            const embedding = try self.generateEmbedding(content);
            const vector = types.Vector.init(memory_id, &embedding);
            try self.memora.insertVector(vector);
            try self.embedding_cache.put(memory_id, embedding);
        }
        
        // Increment version
        memory.version += 1;
        
        // Store updated memory
        const node = memory.toNode();
        try self.memora.insertNode(node);
    }
    
    /// Delete a memory and its relationships
    pub fn forgetMemory(self: *Self, memory_id: u64) !void {
        // Free stored content
        if (self.memory_content.get(memory_id)) |content| {
            self.allocator.free(content);
            _ = self.memory_content.remove(memory_id);
        }
        
        // Remove from embedding cache
        _ = self.embedding_cache.remove(memory_id);
        
        // TODO: Remove from underlying Memora database
        // This would need new functionality in Memora to delete nodes/edges/vectors
        // For now, we just mark it as forgotten in our layer
    }
    
    /// Get comprehensive memory statistics
    pub fn getStatistics(self: *Self) !MemoryStatistics {
        var stats = MemoryStatistics.init();
        
        // Count memories by type
        var node_iter = self.memora.graph_index.nodes.iterator();
        while (node_iter.next()) |entry| {
            const node = entry.value_ptr.*;
            
            // Decode memory type from node label
            const memory_type: MemoryType = @enumFromInt(node.label[0]);
            const type_index = @intFromEnum(memory_type);
            if (type_index < stats.memory_counts_by_type.len) {
                stats.memory_counts_by_type[type_index] += 1;
            }
            
            // Decode confidence
            const confidence: MemoryConfidence = @enumFromInt(node.label[1]);
            const conf_index = @intFromEnum(confidence);
            if (conf_index < stats.confidence_distribution.len) {
                stats.confidence_distribution[conf_index] += 1;
            }
            
            // Decode importance
            const importance: MemoryImportance = @enumFromInt(node.label[2]);
            const imp_index = @intFromEnum(importance);
            if (imp_index < stats.importance_distribution.len) {
                stats.importance_distribution[imp_index] += 1;
            }
        }
        
        // Count active sessions
        var session_iter = self.sessions.iterator();
        while (session_iter.next()) |entry| {
            if (entry.value_ptr.is_active) {
                stats.active_sessions += 1;
            }
        }
        
        // Count relationships
        var edge_iter = self.memora.graph_index.outgoing_edges.iterator();
        while (edge_iter.next()) |entry| {
            const edges_list = entry.value_ptr.*;
            for (edges_list.items) |edge| {
                stats.total_relationships += 1;
                
                // Check if this edge involves concept nodes
                if (edge.from >= 0x8000000000000000 or edge.to >= 0x8000000000000000) {
                    stats.concept_relationships += 1;
                }
            }
        }
        
        return stats;
    }
    
    // Private helper methods
    
    fn performSemanticSearch(self: *Self, result: *MemoryQueryResult, query_text: []const u8, query: MemoryQuery) !void {
        // Generate embedding for the query text
        const query_embedding = try self.generateEmbedding(query_text);
        
        // Create temporary vector for similarity search
        const query_vector = types.Vector.init(0, &query_embedding); // ID 0 for query vector
        
        // Find similar vectors using the query vector
        const similar_results = try self.memora.vector_search.querySimilarByVector(&self.memora.vector_index, query_vector, @intCast(query.limit));
        defer similar_results.deinit();
        
        // Convert similarity results to memories
        for (similar_results.items) |sim_result| {
            if (try self.getMemory(sim_result.id)) |memory| {
                try result.memories.append(memory);
                try result.similarity_scores.append(sim_result.similarity);
            }
        }
        
        result.total_matches = @intCast(similar_results.items.len);
    }
    
    fn performGraphSearch(self: *Self, result: *MemoryQueryResult, _: MemoryQuery) !void {
        // If we don't have semantic results yet, get all memories and filter
        if (result.memories.items.len == 0) {
            var node_iter = self.memora.graph_index.nodes.iterator();
            while (node_iter.next()) |entry| {
                const node = entry.value_ptr.*;
                if (try self.getMemory(node.id)) |memory| {
                    try result.memories.append(memory);
                }
            }
        }
    }
    
    fn applyFilters(self: *Self, result: *MemoryQueryResult, query: MemoryQuery) !void {
        _ = self;
        
        // Filter by memory types
        if (query.memory_types) |types_filter| {
            var filtered = std.ArrayList(Memory).init(result.memories.allocator);
            for (result.memories.items) |memory| {
                for (types_filter) |allowed_type| {
                    if (memory.memory_type == allowed_type) {
                        try filtered.append(memory);
                        break;
                    }
                }
            }
            result.memories.deinit();
            result.memories = filtered;
        }
        
        // Filter by confidence
        if (query.min_confidence) |min_conf| {
            var filtered = std.ArrayList(Memory).init(result.memories.allocator);
            for (result.memories.items) |memory| {
                if (@intFromEnum(memory.confidence) >= @intFromEnum(min_conf)) {
                    try filtered.append(memory);
                }
            }
            result.memories.deinit();
            result.memories = filtered;
        }
        
        // Filter by importance
        if (query.min_importance) |min_imp| {
            var filtered = std.ArrayList(Memory).init(result.memories.allocator);
            for (result.memories.items) |memory| {
                if (@intFromEnum(memory.importance) >= @intFromEnum(min_imp)) {
                    try filtered.append(memory);
                }
            }
            result.memories.deinit();
            result.memories = filtered;
        }
        
        // Filter by session
        if (query.session_id) |session_id| {
            var filtered = std.ArrayList(Memory).init(result.memories.allocator);
            for (result.memories.items) |memory| {
                if (memory.session_id == session_id) {
                    try filtered.append(memory);
                }
            }
            result.memories.deinit();
            result.memories = filtered;
        }
        
        // Filter by user
        if (query.user_id) |user_id| {
            var filtered = std.ArrayList(Memory).init(result.memories.allocator);
            for (result.memories.items) |memory| {
                if (memory.user_id == user_id) {
                    try filtered.append(memory);
                }
            }
            result.memories.deinit();
            result.memories = filtered;
        }
    }
    
    fn includeRelatedMemories(self: *Self, result: *MemoryQueryResult, query: MemoryQuery) !void {
        // For each memory in results, find related memories
        for (result.memories.items) |memory| {
            const related_nodes = try self.memora.queryRelated(memory.id, query.max_depth);
            defer related_nodes.deinit();
            
            for (related_nodes.items) |node| {
                if (node.id != memory.id) { // Don't include the original memory
                    if (try self.getMemory(node.id)) |related_memory| {
                        try result.related_memories.append(related_memory);
                    }
                }
            }
            
            // Get edges for relationships - we need to query the graph directly
            if (self.memora.graph_index.getOutgoingEdges(memory.id)) |edges| {
                for (edges) |edge| {
                    const relation = MemoryRelation.fromEdge(edge);
                    try result.relationships.append(relation);
                }
            }
        }
    }
    
    fn sortAndLimitResults(self: *Self, result: *MemoryQueryResult, query: MemoryQuery) !void {
        _ = self;
        
        // Limit results
        if (result.memories.items.len > query.limit) {
            result.memories.shrinkAndFree(query.limit);
        }
        
        if (result.similarity_scores.items.len > query.limit) {
            result.similarity_scores.shrinkAndFree(query.limit);
        }
    }
    
    /// Load memory content from log by scanning for memory_content entries
    fn loadContentFromLog(self: *Self, memory_id: u64) !?[]const u8 {
        var iter = self.memora.append_log.iterator();
        
        // Scan through log entries to find the content for this memory ID
        while (iter.next()) |entry| {
            if (entry.getEntryType() == .memory_content) {
                if (entry.asMemoryContent()) |mem_content| {
                    if (mem_content.memory_id == memory_id) {
                        return mem_content.content;
                    }
                }
            }
        }
        
        return null;
    }

    pub fn generateEmbedding(self: *Self, content: []const u8) !([128]f32) {
        _ = self;
        
        // Simplified embedding generation for now
        // In production, this would use a real embedding model
        var embedding = [_]f32{0.0} ** 128;
        
        // Simple hash-based embedding
        var hash: u64 = 0;
        for (content) |byte| {
            hash = hash *% 31 +% byte;
        }
        
        // Convert hash to normalized embedding
        var prng = std.Random.DefaultPrng.init(hash);
        const random = prng.random();
        
        for (&embedding) |*dim| {
            dim.* = random.float(f32) * 2.0 - 1.0; // Range [-1, 1]
        }
        
        // Normalize
        var magnitude: f32 = 0.0;
        for (embedding) |dim| {
            magnitude += dim * dim;
        }
        magnitude = @sqrt(magnitude);
        
        if (magnitude > 0.0) {
            for (&embedding) |*dim| {
                dim.* /= magnitude;
            }
        }
        
        return embedding;
    }
    
    /// Load existing memories from snapshots and log during initialization
    pub fn loadExistingMemories(self: *Self) !void {
        std.debug.print("🧠 MemoryManager: Loading existing memories...\n", .{});
        
        var max_memory_id: u64 = 0;
        var loaded_files = std.StringHashMap(void).init(self.allocator);
        defer loaded_files.deinit();
        
        // First, load memory content from ALL snapshots (not just the latest)
        const all_snapshots = try self.memora.snapshot_manager.listSnapshots();
        defer all_snapshots.deinit();
        
        std.debug.print("🧠 Found {} snapshots to scan for memories\n", .{all_snapshots.items.len});
        
        for (all_snapshots.items, 0..) |snapshot_id, i| {
            std.debug.print("🧠 [{}/{}] Checking snapshot {} for memories...\n", .{ i + 1, all_snapshots.items.len, snapshot_id });
            
            if (try self.memora.snapshot_manager.loadSnapshot(snapshot_id)) |snapshot_info| {
                defer snapshot_info.deinit();
                
                if (snapshot_info.memory_content_files.items.len > 0) {
                    std.debug.print("🧠 Snapshot {} has {} memory content files\n", .{ snapshot_id, snapshot_info.memory_content_files.items.len });
                    
                    const memory_contents = try self.memora.snapshot_manager.loadMemoryContents(&snapshot_info);
                    defer {
                        // Free the allocated content strings
                        for (memory_contents.items) |memory_content| {
                            self.allocator.free(memory_content.content);
                        }
                        memory_contents.deinit();
                    }
                    
                    // Track which files we've loaded from snapshots
                    for (snapshot_info.memory_content_files.items) |file_path| {
                        try loaded_files.put(file_path, {});
                    }
                    
                    // Load memory contents from this snapshot
                    for (memory_contents.items) |memory_content| {
                        // Only add if we don't already have this memory ID (avoid duplicates)
                        if (!self.memory_content.contains(memory_content.memory_id)) {
                            const content_copy = try self.allocator.dupe(u8, memory_content.content);
                            try self.memory_content.put(memory_content.memory_id, content_copy);
                            
                            // CRITICAL FIX: Also recreate the node in the graph index
                            // Check if the node already exists in the graph index
                            if (self.memora.graph_index.getNode(memory_content.memory_id) == null) {
                                // Create a Memory object with default metadata (we only have content from snapshots)
                                var memory = Memory.init(memory_content.memory_id, MemoryType.fact, memory_content.content);
                                
                                // Convert to node and insert into graph index
                                const node = memory.toNode();
                                try self.memora.insertNode(node);
                                
                                std.debug.print("🧠   Recreated node {} in graph index\n", .{memory_content.memory_id});
                            }
                            
                            // CRITICAL FIX: Also recreate vector embedding if it doesn't exist
                            if (self.memora.vector_index.getVector(memory_content.memory_id) == null) {
                                const embedding = try self.generateEmbedding(memory_content.content);
                                const vector = types.Vector.init(memory_content.memory_id, &embedding);
                                try self.memora.insertVector(vector);
                                try self.embedding_cache.put(memory_content.memory_id, embedding);
                                
                                std.debug.print("🧠   Recreated vector embedding {} for semantic search\n", .{memory_content.memory_id});
                            }
                        }
                        max_memory_id = @max(max_memory_id, memory_content.memory_id);
                    }
                    
                    std.debug.print("🧠 ✅ Loaded {} memories from snapshot {}\n", .{ memory_contents.items.len, snapshot_id });
                } else {
                    std.debug.print("🧠 Snapshot {} has no memory content files\n", .{snapshot_id});
                }
            } else {
                std.debug.print("🧠 ❌ Failed to load snapshot {}\n", .{snapshot_id});
            }
        }
        
        // CRITICAL FIX: Also scan for orphaned memory content files that exist but aren't referenced by snapshots
        const memory_contents_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.memora.snapshot_manager.base_path, "memory_contents" });
        defer self.allocator.free(memory_contents_path);
        
        var dir = std.fs.cwd().openDir(memory_contents_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("Memory contents directory not found, skipping orphaned file scan\n", .{});
                // Continue to the next section
                // Then load any additional memory content entries from log
                var iter = self.memora.append_log.iterator();
                while (iter.next()) |entry| {
                    if (entry.getEntryType() == .memory_content) {
                        if (entry.asMemoryContent()) |mem_content| {
                            // Only add if we don't already have this memory ID from snapshots
                            if (!self.memory_content.contains(mem_content.memory_id)) {
                                const content_copy = try self.allocator.dupe(u8, mem_content.content);
                                try self.memory_content.put(mem_content.memory_id, content_copy);
                            }
                            
                            // Track the maximum memory ID
                            max_memory_id = @max(max_memory_id, mem_content.memory_id);
                        }
                    }
                }
                
                // Set the next memory ID to be one higher than the maximum found
                if (max_memory_id > 0) {
                    self.next_memory_id = max_memory_id + 1;
                }
                
                std.debug.print("Loaded {} total memories from snapshots and log, next ID: {}\n", .{ self.memory_content.count(), self.next_memory_id });
                return;
            },
            else => return err,
        };
        defer dir.close();
        
        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
                const relative_path = try std.fmt.allocPrint(self.allocator, "memory_contents/{s}", .{entry.name});
                defer self.allocator.free(relative_path);
                
                // Check if this file was already loaded from a snapshot
                if (!loaded_files.contains(relative_path)) {
                    std.debug.print("Found orphaned memory content file: {s}\n", .{relative_path});
                    
                    // Load this orphaned file directly
                    const file_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.memora.snapshot_manager.base_path, relative_path });
                    defer self.allocator.free(file_path);
                    
                    const orphaned_contents = try self.memora.snapshot_manager.readMemoryContentFile(file_path);
                    defer {
                        // Free the allocated content strings
                        for (orphaned_contents.items) |memory_content| {
                            self.allocator.free(memory_content.content);
                        }
                        orphaned_contents.deinit();
                    }
                    
                    // Load memory contents from this orphaned file
                    for (orphaned_contents.items) |memory_content| {
                        // Only add if we don't already have this memory ID (avoid duplicates)
                        if (!self.memory_content.contains(memory_content.memory_id)) {
                            const content_copy = try self.allocator.dupe(u8, memory_content.content);
                            try self.memory_content.put(memory_content.memory_id, content_copy);
                            
                            // Also recreate the node in the graph index
                            if (self.memora.graph_index.getNode(memory_content.memory_id) == null) {
                                // Create a Memory object with default metadata
                                var memory = Memory.init(memory_content.memory_id, MemoryType.fact, memory_content.content);
                                
                                // Convert to node and insert into graph index
                                const node = memory.toNode();
                                try self.memora.insertNode(node);
                                
                                std.debug.print("🧠   Recreated node {} from orphaned file\n", .{memory_content.memory_id});
                            }
                            
                            // CRITICAL FIX: Also recreate vector embedding if it doesn't exist
                            if (self.memora.vector_index.getVector(memory_content.memory_id) == null) {
                                const embedding = try self.generateEmbedding(memory_content.content);
                                const vector = types.Vector.init(memory_content.memory_id, &embedding);
                                try self.memora.insertVector(vector);
                                try self.embedding_cache.put(memory_content.memory_id, embedding);
                                
                                std.debug.print("🧠   Recreated vector embedding {} from orphaned file\n", .{memory_content.memory_id});
                            }
                        }
                        max_memory_id = @max(max_memory_id, memory_content.memory_id);
                    }
                    
                    std.debug.print("Loaded {} memories from orphaned file {s}\n", .{orphaned_contents.items.len, entry.name});
                }
            }
        }
        
        // Then load any additional memory content entries from log
        var iter = self.memora.append_log.iterator();
        while (iter.next()) |entry| {
            if (entry.getEntryType() == .memory_content) {
                if (entry.asMemoryContent()) |mem_content| {
                    // Only add if we don't already have this memory ID from snapshots
                    if (!self.memory_content.contains(mem_content.memory_id)) {
                        const content_copy = try self.allocator.dupe(u8, mem_content.content);
                        try self.memory_content.put(mem_content.memory_id, content_copy);
                    }
                    
                    // Track the maximum memory ID
                    max_memory_id = @max(max_memory_id, mem_content.memory_id);
                }
            }
        }
        
        // DO NOT create placeholder content for nodes without memory content entries
        // This was causing the "[Recovered memory ID ...]" problem
        // If a memory node exists but has no content, it means the data was lost and should not be recovered with placeholders
        
        // Set the next memory ID to be one higher than the maximum found
        if (max_memory_id > 0) {
            self.next_memory_id = max_memory_id + 1;
        }
        
        std.debug.print("🧠 Loaded {} total memories from snapshots and log, next ID: {}\n", .{ self.memory_content.count(), self.next_memory_id });
        
        // Debug: Show what's actually in the graph after loading
        std.debug.print("🔍 DEBUG: Graph state after loading:\n", .{});
        
        // Count and show nodes by type
        var memory_nodes: u32 = 0;
        var concept_nodes: u32 = 0;
        var total_nodes: u32 = 0;
        
        var node_iter = self.memora.graph_index.nodes.iterator();
        while (node_iter.next()) |entry| {
            const node_id = entry.key_ptr.*;
            total_nodes += 1;
            
            if (node_id >= 0x8000000000000000) {
                concept_nodes += 1;
                if (concept_nodes <= 5) { // Show first 5 concept nodes
                    std.debug.print("🔍   Concept node: {} (label: '{s}')\n", .{ node_id, entry.value_ptr.getLabelAsString() });
                }
            } else {
                memory_nodes += 1;
                if (memory_nodes <= 5) { // Show first 5 memory nodes
                    std.debug.print("🔍   Memory node: {} (label: '{s}')\n", .{ node_id, entry.value_ptr.getLabelAsString() });
                }
            }
        }
        
        std.debug.print("🔍 Total nodes: {} (memory: {}, concept: {})\n", .{ total_nodes, memory_nodes, concept_nodes });
        
        // Count and show edges
        var total_edges: u32 = 0;
        var concept_edges: u32 = 0;
        
        var edge_iter = self.memora.graph_index.outgoing_edges.iterator();
        while (edge_iter.next()) |entry| {
            const edges_list = entry.value_ptr.*;
            for (edges_list.items) |edge| {
                total_edges += 1;
                
                // Check if this edge involves concept nodes
                if (edge.from >= 0x8000000000000000 or edge.to >= 0x8000000000000000) {
                    concept_edges += 1;
                    if (concept_edges <= 5) { // Show first 5 concept edges
                        std.debug.print("🔍   Concept edge: {} -> {} (kind: {})\n", .{ edge.from, edge.to, edge.kind });
                    }
                }
            }
        }
        
        std.debug.print("🔍 Total edges: {} (concept-related: {})\n", .{ total_edges, concept_edges });
        
        // Show vector count
        const vector_count = self.memora.vector_index.getVectorCount();
        std.debug.print("🔍 Total vectors: {}\n", .{vector_count});
    }
    
    /// Load memory contents from snapshot data during database restoration
    pub fn loadMemoryContentsFromSnapshot(self: *Self, memory_contents: []const types.MemoryContent) !void {
        var max_memory_id: u64 = 0;
        
        // Clear existing content cache
        var iterator = self.memory_content.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.memory_content.clearAndFree();
        
        // Load memory contents from snapshot
        for (memory_contents) |memory_content| {
            const content_copy = try self.allocator.dupe(u8, memory_content.content);
            try self.memory_content.put(memory_content.memory_id, content_copy);
            max_memory_id = @max(max_memory_id, memory_content.memory_id);
        }
        
        // Update next_memory_id to prevent ID collisions
        if (max_memory_id > 0) {
            self.next_memory_id = max_memory_id + 1;
        }
        
        std.debug.print("Loaded {} memory contents from snapshot, next ID: {}\n", .{ memory_contents.len, self.next_memory_id });
    }
};

// Tests
test "MemoryManager basic operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Clean up test data
    std.fs.cwd().deleteTree("test_memory_manager") catch {};
    defer std.fs.cwd().deleteTree("test_memory_manager") catch {};
    
    // Create test database
    const config = main.MemoraConfig{
        .data_path = "test_memory_manager",
        .auto_snapshot_interval = 100,
        .enable_persistent_indexes = false,
    };
    
    var memora_db = try Memora.init(allocator, config, null);
    defer memora_db.deinit();
    
    // Create memory manager
    var memory_manager = MemoryManager.init(allocator, &memora_db);
    defer memory_manager.deinit();
    
    // Store a memory
    const memory_id = try memory_manager.storeMemory(
        MemoryType.experience,
        "User prefers concise explanations",
        .{ .confidence = MemoryConfidence.high, .importance = MemoryImportance.high }
    );
    
    try std.testing.expect(memory_id == 1);
    
    // Retrieve the memory
    const retrieved = try memory_manager.getMemory(memory_id);
    try std.testing.expect(retrieved != null);
    try std.testing.expect(retrieved.?.memory_type == MemoryType.experience);
    try std.testing.expect(retrieved.?.confidence == MemoryConfidence.high);
    
    // Create a relationship
    const memory_id2 = try memory_manager.storeMemory(
        MemoryType.preference,
        "User likes technical details",
        .{}
    );
    
    try memory_manager.createRelationship(memory_id, memory_id2, MemoryRelationType.similar_to, .{});
    
    // Query memories
    var query = MemoryQuery.init();
    query.memory_types = &[_]MemoryType{MemoryType.experience};
    query.include_related = true;
    
    var results = try memory_manager.queryMemories(query);
    defer results.deinit();
    
    try std.testing.expect(results.memories.items.len >= 1);
}

test "MemoryManager session management" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Clean up test data
    std.fs.cwd().deleteTree("test_memory_sessions") catch {};
    defer std.fs.cwd().deleteTree("test_memory_sessions") catch {};
    
    // Create test database
    const config = main.MemoraConfig{
        .data_path = "test_memory_sessions",
        .auto_snapshot_interval = 100,
        .enable_persistent_indexes = false,
    };
    
    var memora_db = try Memora.init(allocator, config, null);
    defer memora_db.deinit();
    
    // Create memory manager
    var memory_manager = MemoryManager.init(allocator, &memora_db);
    defer memory_manager.deinit();
    
    // Create a session
    const session_id = try memory_manager.createSession(1, "Programming Help", "User learning Zig");
    try std.testing.expect(session_id == 1);
    
    // Get current session
    const session = memory_manager.getCurrentSession();
    try std.testing.expect(session != null);
    try std.testing.expectEqualStrings("Programming Help", session.?.getTitleAsString());
    
    // Store memory in session
    const memory_id = try memory_manager.storeMemory(
        MemoryType.context,
        "User is learning Zig programming",
        .{ .session_id = session_id }
    );
    
    try std.testing.expect(memory_id == 1);
    
    // Verify memory is associated with session
    const memory = try memory_manager.getMemory(memory_id);
    try std.testing.expect(memory.?.session_id == session_id);
} 