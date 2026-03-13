//! Max messenger channel — uses the Max Bot API with long-polling or webhooks.
//!
//! Implements the Channel vtable interface for the Max (VK Teams successor)
//! messaging platform. Supports inline keyboards, draft streaming via
//! message editing, typing indicators, and attachment forwarding.

const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const config_types = @import("../config_types.zig");
const max_api = @import("max_api.zig");
const max_ingress = @import("max_ingress.zig");
const thread_stacks = @import("../thread_stacks.zig");
const streaming = @import("../streaming.zig");
const Atomic = @import("../portable_atomic.zig").Atomic;

const log = std.log.scoped(.max);

// ════════════════════════════════════════════════════════════════════════════
// Constants
// ════════════════════════════════════════════════════════════════════════════

pub const MAX_MESSAGE_LEN: usize = 4000;
const CONTINUATION_MARKER = "\n\n\u{23EC}";
const TYPING_INTERVAL_NS: u64 = 4 * std.time.ns_per_s;
const TYPING_SLEEP_STEP_NS: u64 = 100 * std.time.ns_per_ms;
const DRAFT_MIN_EDIT_INTERVAL_MS: i64 = 500;
const DRAFT_MIN_DELTA_CHARS: usize = 100;

// ════════════════════════════════════════════════════════════════════════════
// Attachment parsing (legacy markers)
// ════════════════════════════════════════════════════════════════════════════

const AttachmentKind = enum {
    image,
    document,
    video,
    audio,

    fn apiFileType(self: AttachmentKind) []const u8 {
        return switch (self) {
            .image => "photo",
            .document => "file",
            .video => "video",
            .audio => "file",
        };
    }

    fn markerPrefix(self: AttachmentKind) []const u8 {
        return switch (self) {
            .image => "[IMAGE:",
            .document => "[DOCUMENT:",
            .video => "[VIDEO:",
            .audio => "[AUDIO:",
        };
    }
};

const ParsedAttachment = struct {
    kind: AttachmentKind,
    target: []const u8,
};

const ParsedMessage = struct {
    attachments: []ParsedAttachment,
    remaining_text: []const u8,
    remaining_owned: []u8,
    attachments_owned: []ParsedAttachment,

    fn deinit(self: *const ParsedMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.remaining_owned);
        allocator.free(self.attachments_owned);
    }
};

fn parseMarkerKind(kind_str: []const u8) ?AttachmentKind {
    if (std.ascii.eqlIgnoreCase(kind_str, "image") or std.ascii.eqlIgnoreCase(kind_str, "photo"))
        return .image;
    if (std.ascii.eqlIgnoreCase(kind_str, "document") or std.ascii.eqlIgnoreCase(kind_str, "file"))
        return .document;
    if (std.ascii.eqlIgnoreCase(kind_str, "video"))
        return .video;
    if (std.ascii.eqlIgnoreCase(kind_str, "audio") or std.ascii.eqlIgnoreCase(kind_str, "voice"))
        return .audio;
    return null;
}

fn parseAttachmentMarkers(allocator: std.mem.Allocator, text: []const u8) !ParsedMessage {
    var attachments: std.ArrayListUnmanaged(ParsedAttachment) = .empty;
    errdefer attachments.deinit(allocator);

    var remaining: std.ArrayListUnmanaged(u8) = .empty;
    errdefer remaining.deinit(allocator);

    var cursor: usize = 0;
    while (cursor < text.len) {
        const open_pos = std.mem.indexOfPos(u8, text, cursor, "[") orelse {
            try remaining.appendSlice(allocator, text[cursor..]);
            break;
        };

        try remaining.appendSlice(allocator, text[cursor..open_pos]);

        const close_pos = std.mem.indexOfPos(u8, text, open_pos, "]") orelse {
            try remaining.appendSlice(allocator, text[open_pos..]);
            break;
        };

        const marker = text[open_pos + 1 .. close_pos];

        if (std.mem.indexOf(u8, marker, ":")) |colon_pos| {
            const kind_str = marker[0..colon_pos];
            const target_raw = marker[colon_pos + 1 ..];
            const target = std.mem.trim(u8, target_raw, " ");

            if (target.len > 0) {
                if (parseMarkerKind(kind_str)) |kind| {
                    try attachments.append(allocator, .{
                        .kind = kind,
                        .target = target,
                    });
                    cursor = close_pos + 1;
                    continue;
                }
            }
        }

        try remaining.appendSlice(allocator, text[open_pos .. close_pos + 1]);
        cursor = close_pos + 1;
    }

    const trimmed = std.mem.trim(u8, remaining.items, " \t\n\r");
    const remaining_owned = try allocator.dupe(u8, trimmed);
    errdefer allocator.free(remaining_owned);

    const final_attachments = try attachments.toOwnedSlice(allocator);
    remaining.deinit(allocator);

    return .{
        .attachments = final_attachments,
        .remaining_text = remaining_owned,
        .remaining_owned = remaining_owned,
        .attachments_owned = final_attachments,
    };
}

// ════════════════════════════════════════════════════════════════════════════
// Draft State (streaming via message editing)
// ════════════════════════════════════════════════════════════════════════════

const DraftState = struct {
    mid: ?[]u8 = null,
    buffer: std.ArrayListUnmanaged(u8) = .empty,
    last_edit_ms: i64 = 0,
    last_edit_len: usize = 0,

    fn deinit(self: *DraftState, allocator: std.mem.Allocator) void {
        if (self.mid) |m| allocator.free(m);
        self.buffer.deinit(allocator);
    }
};

// ════════════════════════════════════════════════════════════════════════════
// Pending Interaction (inline keyboard callbacks)
// ════════════════════════════════════════════════════════════════════════════

const PendingInteractionOption = struct {
    id: []const u8,
    label: []const u8,
    submit_text: []const u8,

    fn deinit(self: *const PendingInteractionOption, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.label);
        allocator.free(self.submit_text);
    }
};

const PendingInteraction = struct {
    created_at: u64,
    expires_at: u64,
    chat_id: []const u8,
    options: []PendingInteractionOption,

    fn deinit(self: *const PendingInteraction, allocator: std.mem.Allocator) void {
        allocator.free(self.chat_id);
        for (self.options) |opt| opt.deinit(allocator);
        allocator.free(self.options);
    }
};

// ════════════════════════════════════════════════════════════════════════════
// Typing Task
// ════════════════════════════════════════════════════════════════════════════

const TypingTask = struct {
    max_channel: *MaxChannel,
    chat_id: []const u8,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
};

fn typingLoop(task: *TypingTask) void {
    while (!task.stop_requested.load(.acquire)) {
        task.max_channel.api().sendTypingAction(
            task.max_channel.allocator,
            task.chat_id,
        ) catch {};

        var elapsed: u64 = 0;
        while (elapsed < TYPING_INTERVAL_NS and !task.stop_requested.load(.acquire)) {
            std.Thread.sleep(TYPING_SLEEP_STEP_NS);
            elapsed += TYPING_SLEEP_STEP_NS;
        }
    }
}

// ════════════════════════════════════════════════════════════════════════════
// MaxChannel
// ════════════════════════════════════════════════════════════════════════════

pub const MaxChannel = struct {
    allocator: std.mem.Allocator,
    bot_token: []const u8,
    account_id: []const u8 = "default",
    allow_from: []const []const u8,
    group_allow_from: []const []const u8,
    group_policy: []const u8,
    proxy: ?[]const u8 = null,
    mode: config_types.MaxListenerMode = .polling,
    webhook_url: ?[]const u8 = null,
    webhook_secret: ?[]const u8 = null,
    interactive: config_types.MaxInteractiveConfig = .{},
    require_mention: bool = false,
    streaming_enabled: bool = true,

    bot_username: ?[]const u8 = null,
    bot_user_id: ?[]const u8 = null,
    marker: ?[]u8 = null,
    running: bool = false,

    typing_mu: std.Thread.Mutex = .{},
    typing_handles: std.StringHashMapUnmanaged(*TypingTask) = .empty,

    interaction_mu: std.Thread.Mutex = .{},
    pending_interactions: std.StringHashMapUnmanaged(PendingInteraction) = .empty,
    interaction_seq: Atomic(u64) = Atomic(u64).init(1),

    draft_mu: std.Thread.Mutex = .{},
    draft_buffers: std.StringHashMapUnmanaged(DraftState) = .empty,

    // ── Construction ─────────────────────────────────────────────────

    pub fn initFromConfig(allocator: std.mem.Allocator, cfg: config_types.MaxConfig) MaxChannel {
        return .{
            .allocator = allocator,
            .bot_token = cfg.bot_token,
            .allow_from = cfg.allow_from,
            .group_allow_from = cfg.group_allow_from,
            .group_policy = cfg.group_policy,
            .account_id = cfg.account_id,
            .proxy = cfg.proxy,
            .mode = cfg.mode,
            .webhook_url = cfg.webhook_url,
            .webhook_secret = cfg.webhook_secret,
            .interactive = cfg.interactive,
            .require_mention = cfg.require_mention,
            .streaming_enabled = cfg.streaming,
        };
    }

    pub fn channelName(_: *const MaxChannel) []const u8 {
        return "max";
    }

    pub fn api(self: *const MaxChannel) max_api.Client {
        return .{
            .allocator = self.allocator,
            .bot_token = self.bot_token,
            .proxy = self.proxy,
        };
    }

    pub fn healthCheck(self: *MaxChannel) bool {
        if (comptime builtin.is_test) return true;
        return self.api().getMeOk();
    }

    // ── Authorization ────────────────────────────────────────────────

    pub fn isUserAllowed(self: *const MaxChannel, sender_id: []const u8) bool {
        return root.isAllowed(self.allow_from, sender_id);
    }

    pub fn isGroupUserAllowed(self: *const MaxChannel, sender_id: []const u8) bool {
        if (self.group_allow_from.len == 0) {
            return self.isUserAllowed(sender_id);
        }
        return root.isAllowed(self.group_allow_from, sender_id);
    }

    fn isAuthorized(self: *const MaxChannel, sender_id: []const u8, is_group: bool) bool {
        if (is_group) {
            if (std.mem.eql(u8, self.group_policy, "open")) return true;
            if (std.mem.eql(u8, self.group_policy, "disabled")) return false;
            return self.isGroupUserAllowed(sender_id);
        }
        return self.isUserAllowed(sender_id);
    }

    // ── Fetch bot identity ───────────────────────────────────────────

    fn fetchBotIdentity(self: *MaxChannel) void {
        if (self.bot_username != null) return;
        if (comptime builtin.is_test) return;
        const info = self.api().fetchBotInfo(self.allocator) orelse return;
        defer info.deinit(self.allocator);
        if (info.username) |u| {
            self.bot_username = self.allocator.dupe(u8, u) catch null;
        }
        if (info.user_id) |uid| {
            self.bot_user_id = self.allocator.dupe(u8, uid) catch null;
        }
    }

    // ── Send (text + attachments) ────────────────────────────────────

    pub fn sendMessage(self: *MaxChannel, target: []const u8, text: []const u8) !void {
        const parsed = try parseAttachmentMarkers(self.allocator, text);
        defer parsed.deinit(self.allocator);

        try self.sendTextChunked(target, parsed.remaining_text);

        for (parsed.attachments) |att| {
            self.sendAttachment(target, att) catch |err| {
                log.warn("max sendAttachment failed: {}", .{err});
            };
        }
    }

    fn sendTextChunked(self: *MaxChannel, target: []const u8, text: []const u8) !void {
        if (text.len == 0) return;

        var it = root.splitMessage(text, MAX_MESSAGE_LEN - CONTINUATION_MARKER.len);
        var chunk_index: usize = 0;
        while (it.next()) |chunk| {
            const has_more = it.remaining.len > 0;
            const body = if (has_more) blk: {
                var buf: std.ArrayListUnmanaged(u8) = .empty;
                defer buf.deinit(self.allocator);
                try buf.appendSlice(self.allocator, chunk);
                try buf.appendSlice(self.allocator, CONTINUATION_MARKER);
                const owned = try allocatorDupeSlice(self.allocator, buf.items);
                const body_json = try max_api.buildTextMessageBody(self.allocator, owned, "markdown");
                self.allocator.free(owned);
                break :blk body_json;
            } else blk: {
                break :blk try max_api.buildTextMessageBody(self.allocator, chunk, "markdown");
            };
            defer self.allocator.free(body);

            const resp = try self.api().sendMessage(self.allocator, target, body);
            self.allocator.free(resp);

            chunk_index += 1;
        }
    }

    fn sendAttachment(self: *MaxChannel, target: []const u8, att: ParsedAttachment) !void {
        if (comptime builtin.is_test) return;

        const upload_resp = try self.api().uploadFile(self.allocator, att.kind.apiFileType(), att.target);
        defer self.allocator.free(upload_resp);

        const token = max_api.Client.parseUploadToken(self.allocator, upload_resp) orelse return;
        defer self.allocator.free(token);

        // Build body with attachment token
        var body: std.ArrayListUnmanaged(u8) = .empty;
        defer body.deinit(self.allocator);
        try body.appendSlice(self.allocator, "{\"text\":\"\",\"attachments\":[{\"type\":\"");
        try body.appendSlice(self.allocator, att.kind.apiFileType());
        try body.appendSlice(self.allocator, "\",\"payload\":{\"token\":");
        try root.json_util.appendJsonString(&body, self.allocator, token);
        try body.appendSlice(self.allocator, "}}]}");

        const resp = try self.api().sendMessage(self.allocator, target, body.items);
        self.allocator.free(resp);
    }

    // ── sendRich (inline keyboards) ──────────────────────────────────

    pub fn sendRichPayload(self: *MaxChannel, target: []const u8, payload: root.Channel.OutboundPayload) !void {
        if (payload.choices.len > 0 and self.interactive.enabled) {
            const choices = try self.allocator.alloc([]const u8, payload.choices.len);
            defer self.allocator.free(choices);
            for (payload.choices, 0..) |choice, i| {
                choices[i] = choice.label;
            }

            const keyboard_json = try max_api.buildInlineKeyboardJson(self.allocator, choices);
            defer self.allocator.free(keyboard_json);

            const body_json = try max_api.buildTextWithKeyboardBody(
                self.allocator,
                payload.text,
                keyboard_json,
                "markdown",
            );
            defer self.allocator.free(body_json);

            const resp = try self.api().sendMessage(self.allocator, target, body_json);
            defer self.allocator.free(resp);

            // Parse message ID and register pending interaction
            if (max_api.Client.parseSentMessageMid(self.allocator, resp)) |meta| {
                defer meta.deinit(self.allocator);
                if (meta.mid) |mid| {
                    self.registerPendingInteraction(target, mid, payload.choices) catch |err| {
                        log.warn("max registerPendingInteraction failed: {}", .{err});
                    };
                }
            }
            return;
        }

        // Fall back to plain send
        const parsed = try parseAttachmentMarkers(self.allocator, payload.text);
        defer parsed.deinit(self.allocator);
        try self.sendTextChunked(target, parsed.remaining_text);

        for (parsed.attachments) |att| {
            self.sendAttachment(target, att) catch |err| {
                log.warn("max sendAttachment failed: {}", .{err});
            };
        }

        for (payload.attachments) |att| {
            const kind: AttachmentKind = switch (att.kind) {
                .image => .image,
                .document => .document,
                .video => .video,
                .audio, .voice => .audio,
            };
            self.sendAttachment(target, .{ .kind = kind, .target = att.target }) catch |err| {
                log.warn("max sendAttachment failed: {}", .{err});
            };
        }
    }

    // ── Pending interactions ──────────────────────────────────────────

    fn registerPendingInteraction(
        self: *MaxChannel,
        chat_id: []const u8,
        mid: []const u8,
        choices: []const root.Channel.OutboundChoice,
    ) !void {
        const now = root.nowEpochSecs();
        const ttl = self.interactive.ttl_secs;

        var options = try self.allocator.alloc(PendingInteractionOption, choices.len);
        var built: usize = 0;
        errdefer {
            for (options[0..built]) |opt| opt.deinit(self.allocator);
            self.allocator.free(options);
        }

        for (choices, 0..) |choice, i| {
            options[i] = .{
                .id = try self.allocator.dupe(u8, choice.id),
                .label = try self.allocator.dupe(u8, choice.label),
                .submit_text = try self.allocator.dupe(u8, choice.submit_text),
            };
            built += 1;
        }

        const key = try self.allocator.dupe(u8, mid);
        errdefer self.allocator.free(key);

        const chat_id_dup = try self.allocator.dupe(u8, chat_id);
        errdefer self.allocator.free(chat_id_dup);

        self.interaction_mu.lock();
        defer self.interaction_mu.unlock();

        // Expire stale interactions
        self.expireInteractionsLocked(now);

        try self.pending_interactions.put(self.allocator, key, .{
            .created_at = now,
            .expires_at = now + ttl,
            .chat_id = chat_id_dup,
            .options = options,
        });
    }

    fn expireInteractionsLocked(self: *MaxChannel, now: u64) void {
        var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
        defer to_remove.deinit(self.allocator);

        var it = self.pending_interactions.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.expires_at < now) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.pending_interactions.fetchRemove(key)) |removed| {
                removed.value.deinit(self.allocator);
                self.allocator.free(@constCast(removed.key));
            }
        }
    }

    fn lookupInteractionByPayload(self: *MaxChannel, payload: []const u8) ?struct {
        submit_text: []u8,
        callback_notification: []u8,
    } {
        self.interaction_mu.lock();
        defer self.interaction_mu.unlock();

        const now = root.nowEpochSecs();
        self.expireInteractionsLocked(now);

        // Search all pending interactions for a matching option
        var interactions_it = self.pending_interactions.iterator();
        while (interactions_it.next()) |entry| {
            const interaction = entry.value_ptr;
            for (interaction.options) |opt| {
                if (std.mem.eql(u8, opt.label, payload)) {
                    const submit = self.allocator.dupe(u8, opt.submit_text) catch return null;
                    const notif = self.allocator.dupe(u8, opt.label) catch {
                        self.allocator.free(submit);
                        return null;
                    };
                    return .{
                        .submit_text = submit,
                        .callback_notification = notif,
                    };
                }
            }
        }

        return null;
    }

    fn deinitPendingInteractions(self: *MaxChannel) void {
        self.interaction_mu.lock();
        var interactions = self.pending_interactions;
        self.pending_interactions = .empty;
        self.interaction_mu.unlock();

        var it = interactions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(@constCast(entry.key_ptr.*));
        }
        interactions.deinit(self.allocator);
    }

    // ── Draft streaming (sendEvent) ──────────────────────────────────

    fn ensureDraftStateLocked(self: *MaxChannel, target: []const u8, now_ms: i64) !*DraftState {
        const gop = try self.draft_buffers.getOrPut(self.allocator, target);
        if (!gop.found_existing) {
            const key_copy = try self.allocator.dupe(u8, target);
            gop.key_ptr.* = key_copy;
            gop.value_ptr.* = .{
                .last_edit_ms = now_ms,
            };
        }
        return gop.value_ptr;
    }

    fn clearDraftForTarget(self: *MaxChannel, target: []const u8) void {
        if (self.draft_buffers.fetchRemove(target)) |entry| {
            var state = entry.value;
            state.deinit(self.allocator);
            self.allocator.free(@constCast(entry.key));
        }
    }

    fn deinitDraftBuffers(self: *MaxChannel) void {
        self.draft_mu.lock();
        var buffers = self.draft_buffers;
        self.draft_buffers = .empty;
        self.draft_mu.unlock();

        var it = buffers.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(@constCast(entry.key_ptr.*));
        }
        buffers.deinit(self.allocator);
    }

    fn handleSendEventChunk(self: *MaxChannel, target: []const u8, message: []const u8) !void {
        if (message.len == 0) return;

        const now_ms = std.time.milliTimestamp();

        self.draft_mu.lock();
        defer self.draft_mu.unlock();

        const state = try self.ensureDraftStateLocked(target, now_ms);
        try state.buffer.appendSlice(self.allocator, message);

        // Rate-limit edits
        const elapsed = now_ms - state.last_edit_ms;
        const delta = state.buffer.items.len -| state.last_edit_len;

        if (elapsed < DRAFT_MIN_EDIT_INTERVAL_MS or delta < DRAFT_MIN_DELTA_CHARS) {
            return;
        }

        // Flush: send or edit
        if (state.mid == null) {
            // Send initial message
            const body = max_api.buildTextMessageBody(
                self.allocator,
                state.buffer.items,
                "markdown",
            ) catch return;
            defer self.allocator.free(body);

            const resp = self.api().sendMessage(self.allocator, target, body) catch return;
            defer self.allocator.free(resp);

            if (max_api.Client.parseSentMessageMid(self.allocator, resp)) |meta| {
                if (meta.mid) |mid| {
                    state.mid = mid;
                } else {
                    meta.deinit(self.allocator);
                }
            }
        } else {
            // Edit existing message
            const body = max_api.buildTextMessageBody(
                self.allocator,
                state.buffer.items,
                "markdown",
            ) catch return;
            defer self.allocator.free(body);

            const resp = self.api().editMessage(self.allocator, state.mid.?, body) catch return;
            self.allocator.free(resp);
        }

        state.last_edit_ms = now_ms;
        state.last_edit_len = state.buffer.items.len;
    }

    fn handleSendEventFinal(self: *MaxChannel, target: []const u8, message: []const u8) !void {
        // Clean up draft state
        {
            self.draft_mu.lock();
            defer self.draft_mu.unlock();
            self.clearDraftForTarget(target);
        }

        // Send final message through normal path
        if (message.len > 0) {
            try self.sendMessage(target, message);
        }
    }

    // ── Typing indicator ─────────────────────────────────────────────

    pub fn startTyping(self: *MaxChannel, chat_id: []const u8) !void {
        if (chat_id.len == 0) return;
        try self.stopTyping(chat_id);

        const key_copy = try self.allocator.dupe(u8, chat_id);
        errdefer self.allocator.free(key_copy);

        const task = try self.allocator.create(TypingTask);
        errdefer self.allocator.destroy(task);
        task.* = .{
            .max_channel = self,
            .chat_id = key_copy,
        };

        if (comptime !builtin.is_test) {
            task.thread = try std.Thread.spawn(
                .{ .stack_size = thread_stacks.AUXILIARY_LOOP_STACK_SIZE },
                typingLoop,
                .{task},
            );
        }

        self.typing_mu.lock();
        defer self.typing_mu.unlock();
        try self.typing_handles.put(self.allocator, key_copy, task);
    }

    pub fn stopTyping(self: *MaxChannel, chat_id: []const u8) !void {
        var removed_key: ?[]u8 = null;
        var removed_task: ?*TypingTask = null;

        self.typing_mu.lock();
        if (self.typing_handles.fetchRemove(chat_id)) |entry| {
            removed_key = @constCast(entry.key);
            removed_task = entry.value;
        }
        self.typing_mu.unlock();

        if (removed_task) |task| {
            task.stop_requested.store(true, .release);
            if (task.thread) |t| t.join();
            self.allocator.destroy(task);
        }
        if (removed_key) |key| {
            self.allocator.free(key);
        }
    }

    fn stopAllTyping(self: *MaxChannel) void {
        self.typing_mu.lock();
        var handles = self.typing_handles;
        self.typing_handles = .empty;
        self.typing_mu.unlock();

        var it = handles.iterator();
        while (it.next()) |entry| {
            const task = entry.value_ptr.*;
            task.stop_requested.store(true, .release);
            if (task.thread) |t| t.join();
            self.allocator.destroy(task);
            self.allocator.free(@constCast(entry.key_ptr.*));
        }
        handles.deinit(self.allocator);
    }

    // ── Process update ───────────────────────────────────────────────

    pub fn processUpdate(self: *MaxChannel, allocator: std.mem.Allocator, update_obj: std.json.Value) ?root.ChannelMessage {
        const parsed = max_ingress.parseUpdate(allocator, update_obj) orelse return null;

        switch (parsed) {
            .message => |msg| {
                defer msg.deinit(allocator);

                const sender_id = msg.sender.identity();
                if (!self.isAuthorized(sender_id, msg.chat.isGroup())) {
                    log.warn("ignoring message from unauthorized user: {s}", .{sender_id});
                    return null;
                }

                // Build content with attachment markers
                var content_buf: std.ArrayListUnmanaged(u8) = .empty;
                defer content_buf.deinit(allocator);

                if (msg.text) |text| {
                    content_buf.appendSlice(allocator, text) catch return null;
                }

                // Append attachment markers
                const min_len = @min(msg.attachment_urls.len, msg.attachment_types.len);
                for (0..min_len) |i| {
                    const prefix = max_ingress.attachmentMarkerPrefix(msg.attachment_types[i]) orelse continue;
                    if (content_buf.items.len > 0) {
                        content_buf.appendSlice(allocator, "\n") catch continue;
                    }
                    content_buf.appendSlice(allocator, prefix) catch continue;
                    content_buf.appendSlice(allocator, msg.attachment_urls[i]) catch continue;
                    content_buf.appendSlice(allocator, "]") catch continue;
                }

                if (content_buf.items.len == 0) return null;

                const id_owned = allocator.dupe(u8, msg.mid orelse "unknown") catch return null;
                errdefer allocator.free(id_owned);
                const sender_owned = allocator.dupe(u8, sender_id) catch {
                    allocator.free(id_owned);
                    return null;
                };
                errdefer allocator.free(sender_owned);
                const content_owned = allocator.dupe(u8, content_buf.items) catch {
                    allocator.free(id_owned);
                    allocator.free(sender_owned);
                    return null;
                };
                errdefer allocator.free(content_owned);
                const reply_target = allocator.dupe(u8, msg.chat.chat_id) catch {
                    allocator.free(id_owned);
                    allocator.free(sender_owned);
                    allocator.free(content_owned);
                    return null;
                };
                errdefer allocator.free(reply_target);
                const first_name: ?[]const u8 = if (msg.sender.name) |n|
                    (allocator.dupe(u8, n) catch null)
                else
                    null;

                return .{
                    .id = id_owned,
                    .sender = sender_owned,
                    .content = content_owned,
                    .channel = "max",
                    .timestamp = msg.timestamp,
                    .reply_target = reply_target,
                    .first_name = first_name,
                    .is_group = msg.chat.isGroup(),
                };
            },
            .callback => |cb| {
                defer cb.deinit(allocator);

                // Try to match against pending interaction
                const selection = self.lookupInteractionByPayload(cb.payload);
                const content_text = if (selection) |sel| sel.submit_text else blk: {
                    break :blk allocator.dupe(u8, cb.payload) catch return null;
                };
                const notification = if (selection) |sel| sel.callback_notification else null;

                // Answer the callback (best-effort)
                self.api().answerCallback(allocator, cb.callback_id, notification) catch {};
                if (notification) |n| allocator.free(n);

                const id_owned = allocator.dupe(u8, cb.callback_id) catch {
                    allocator.free(content_text);
                    return null;
                };
                errdefer allocator.free(id_owned);
                const sender_owned = allocator.dupe(u8, cb.sender.identity()) catch {
                    allocator.free(id_owned);
                    allocator.free(content_text);
                    return null;
                };
                errdefer allocator.free(sender_owned);
                const reply_target = allocator.dupe(u8, cb.chat_id) catch {
                    allocator.free(id_owned);
                    allocator.free(sender_owned);
                    allocator.free(content_text);
                    return null;
                };

                return .{
                    .id = id_owned,
                    .sender = sender_owned,
                    .content = content_text,
                    .channel = "max",
                    .timestamp = root.nowEpochSecs(),
                    .reply_target = reply_target,
                };
            },
            .bot_started => |bs| {
                defer bs.deinit(allocator);

                // Build /start content
                var start_content: std.ArrayListUnmanaged(u8) = .empty;
                defer start_content.deinit(allocator);
                start_content.appendSlice(allocator, "/start") catch return null;
                if (bs.payload) |payload| {
                    start_content.appendSlice(allocator, " ") catch return null;
                    start_content.appendSlice(allocator, payload) catch return null;
                }

                const id_owned = allocator.dupe(u8, "bot_started") catch return null;
                errdefer allocator.free(id_owned);
                const sender_owned = allocator.dupe(u8, bs.sender.identity()) catch {
                    allocator.free(id_owned);
                    return null;
                };
                errdefer allocator.free(sender_owned);
                const content_owned = allocator.dupe(u8, start_content.items) catch {
                    allocator.free(id_owned);
                    allocator.free(sender_owned);
                    return null;
                };
                errdefer allocator.free(content_owned);
                const reply_target = allocator.dupe(u8, bs.chat_id) catch {
                    allocator.free(id_owned);
                    allocator.free(sender_owned);
                    allocator.free(content_owned);
                    return null;
                };
                errdefer allocator.free(reply_target);

                const first_name: ?[]const u8 = if (bs.sender.name) |n|
                    (allocator.dupe(u8, n) catch null)
                else
                    null;

                return .{
                    .id = id_owned,
                    .sender = sender_owned,
                    .content = content_owned,
                    .channel = "max",
                    .timestamp = root.nowEpochSecs(),
                    .reply_target = reply_target,
                    .first_name = first_name,
                };
            },
            .ignored => return null,
        }
    }

    // ── Poll updates ─────────────────────────────────────────────────

    pub fn pollUpdates(self: *MaxChannel, allocator: std.mem.Allocator) ![]root.ChannelMessage {
        const resp = try self.api().getUpdates(
            allocator,
            if (self.marker) |m| m else null,
            "30",
        );
        defer allocator.free(resp);

        // Update marker
        if (max_ingress.parseUpdatesMarker(allocator, resp)) |new_marker| {
            if (self.marker) |old| self.allocator.free(old);
            self.marker = new_marker;
        }

        // Parse updates array
        var parsed_resp = max_ingress.parseUpdatesArray(resp, allocator) orelse return &.{};
        defer parsed_resp.deinit();

        if (parsed_resp.value != .object) return &.{};
        const updates_val = parsed_resp.value.object.get("updates") orelse return &.{};
        if (updates_val != .array) return &.{};

        var messages: std.ArrayListUnmanaged(root.ChannelMessage) = .empty;
        errdefer {
            for (messages.items) |*msg| msg.deinit(allocator);
            messages.deinit(allocator);
        }

        for (updates_val.array.items) |update_obj| {
            if (self.processUpdate(allocator, update_obj)) |msg| {
                try messages.append(allocator, msg);
            }
        }

        return messages.toOwnedSlice(allocator) catch &.{};
    }

    // ── VTable wrappers ──────────────────────────────────────────────

    fn vtableStart(ptr: *anyopaque) anyerror!void {
        const self: *MaxChannel = @ptrCast(@alignCast(ptr));
        // Fetch bot identity
        self.fetchBotIdentity();
        self.running = true;
    }

    fn vtableStop(ptr: *anyopaque) void {
        const self: *MaxChannel = @ptrCast(@alignCast(ptr));
        self.running = false;
        self.stopAllTyping();
        self.deinitPendingInteractions();
        self.deinitDraftBuffers();
        if (self.marker) |m| {
            self.allocator.free(m);
            self.marker = null;
        }
        if (self.bot_username) |name| {
            self.allocator.free(name);
            self.bot_username = null;
        }
        if (self.bot_user_id) |uid| {
            self.allocator.free(uid);
            self.bot_user_id = null;
        }
    }

    fn vtableSend(ptr: *anyopaque, target: []const u8, message: []const u8, _: []const []const u8) anyerror!void {
        const self: *MaxChannel = @ptrCast(@alignCast(ptr));
        try self.sendMessage(target, message);
    }

    fn vtableSendEvent(
        ptr: *anyopaque,
        target: []const u8,
        message: []const u8,
        _: []const []const u8,
        stage: root.Channel.OutboundStage,
    ) anyerror!void {
        const self: *MaxChannel = @ptrCast(@alignCast(ptr));
        if (!self.streaming_enabled) {
            if (stage == .final and message.len > 0) {
                return vtableSend(ptr, target, message, &.{});
            }
            return;
        }

        switch (stage) {
            .chunk => try self.handleSendEventChunk(target, message),
            .final => try self.handleSendEventFinal(target, message),
        }
    }

    fn vtableSendRich(ptr: *anyopaque, target: []const u8, payload: root.Channel.OutboundPayload) anyerror!void {
        const self: *MaxChannel = @ptrCast(@alignCast(ptr));
        try self.sendRichPayload(target, payload);
    }

    fn vtableName(ptr: *anyopaque) []const u8 {
        const self: *MaxChannel = @ptrCast(@alignCast(ptr));
        return self.channelName();
    }

    fn vtableHealthCheck(ptr: *anyopaque) bool {
        const self: *MaxChannel = @ptrCast(@alignCast(ptr));
        return self.healthCheck();
    }

    fn vtableStartTyping(ptr: *anyopaque, recipient: []const u8) anyerror!void {
        const self: *MaxChannel = @ptrCast(@alignCast(ptr));
        try self.startTyping(recipient);
    }

    fn vtableStopTyping(ptr: *anyopaque, recipient: []const u8) anyerror!void {
        const self: *MaxChannel = @ptrCast(@alignCast(ptr));
        try self.stopTyping(recipient);
    }

    // ── Streaming sink (for processMessageStreaming) ──────────────

    pub const StreamCtx = struct {
        max_ptr: *MaxChannel,
        chat_id: []const u8,
        filter: streaming.TagFilter = undefined,
    };

    fn streamCallback(ctx_ptr: *anyopaque, event: streaming.Event) void {
        if (event.stage != .chunk or event.text.len == 0) return;
        const ctx: *StreamCtx = @ptrCast(@alignCast(ctx_ptr));
        ctx.max_ptr.handleSendEventChunk(ctx.chat_id, event.text) catch {};
    }

    /// Build a streaming sink backed by the given context.
    /// Returns null if streaming is disabled. Caller owns the lifetime of `ctx`.
    /// Chunks are filtered through a TagFilter to strip tool_call markup.
    pub fn makeSink(self: *MaxChannel, ctx: *StreamCtx) ?streaming.Sink {
        if (!self.streaming_enabled) return null;
        const raw = streaming.Sink{
            .callback = streamCallback,
            .ctx = @ptrCast(ctx),
        };
        ctx.filter = streaming.TagFilter.init(raw);
        return ctx.filter.sink();
    }

    pub const vtable = root.Channel.VTable{
        .start = &vtableStart,
        .stop = &vtableStop,
        .send = &vtableSend,
        .sendEvent = &vtableSendEvent,
        .sendRich = &vtableSendRich,
        .name = &vtableName,
        .healthCheck = &vtableHealthCheck,
        .startTyping = &vtableStartTyping,
        .stopTyping = &vtableStopTyping,
    };

    pub fn channel(self: *MaxChannel) root.Channel {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    // ── Bus (unused, required by channel manager) ────────────────────

    pub fn setBus(_: *MaxChannel, _: anytype) void {}
};

fn allocatorDupeSlice(allocator: std.mem.Allocator, slice: []const u8) ![]u8 {
    return allocator.dupe(u8, slice);
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

fn testChannel() MaxChannel {
    return .{
        .allocator = std.testing.allocator,
        .bot_token = "test-token",
        .allow_from = &.{},
        .group_allow_from = &.{},
        .group_policy = "allowlist",
    };
}

fn testChannelWithAllowFrom(allow: []const []const u8) MaxChannel {
    return .{
        .allocator = std.testing.allocator,
        .bot_token = "test-token",
        .allow_from = allow,
        .group_allow_from = &.{},
        .group_policy = "allowlist",
    };
}

fn parseTestJson(allocator: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json, .{});
}

test "channelName returns max" {
    var ch = testChannel();
    try std.testing.expectEqualStrings("max", ch.channelName());
}

test "vtable channel returns valid interface" {
    var ch = testChannel();
    const iface = ch.channel();
    try std.testing.expectEqualStrings("max", iface.name());
}

test "healthCheck returns true in test mode" {
    var ch = testChannel();
    try std.testing.expect(ch.healthCheck());
}

test "isUserAllowed wildcard" {
    const list = [_][]const u8{"*"};
    var ch = testChannelWithAllowFrom(&list);
    try std.testing.expect(ch.isUserAllowed("anyone"));
}

test "isUserAllowed exact match" {
    const list = [_][]const u8{ "alice", "bob" };
    var ch = testChannelWithAllowFrom(&list);
    try std.testing.expect(ch.isUserAllowed("alice"));
    try std.testing.expect(ch.isUserAllowed("bob"));
    try std.testing.expect(!ch.isUserAllowed("eve"));
}

test "isUserAllowed case insensitive" {
    const list = [_][]const u8{"Alice"};
    var ch = testChannelWithAllowFrom(&list);
    try std.testing.expect(ch.isUserAllowed("alice"));
    try std.testing.expect(ch.isUserAllowed("ALICE"));
    try std.testing.expect(ch.isUserAllowed("Alice"));
}

test "isUserAllowed empty list denies" {
    var ch = testChannel();
    try std.testing.expect(!ch.isUserAllowed("anyone"));
}

test "isGroupUserAllowed falls back to allow_from when group list empty" {
    const list = [_][]const u8{ "alice", "bob" };
    var ch = testChannelWithAllowFrom(&list);
    try std.testing.expect(ch.isGroupUserAllowed("alice"));
    try std.testing.expect(!ch.isGroupUserAllowed("eve"));
}

test "isGroupUserAllowed uses group_allow_from when non-empty" {
    const allow = [_][]const u8{"alice"};
    const group_allow = [_][]const u8{"bob"};
    var ch = MaxChannel{
        .allocator = std.testing.allocator,
        .bot_token = "test-token",
        .allow_from = &allow,
        .group_allow_from = &group_allow,
        .group_policy = "allowlist",
    };
    try std.testing.expect(!ch.isGroupUserAllowed("alice"));
    try std.testing.expect(ch.isGroupUserAllowed("bob"));
}

test "isGroupUserAllowed wildcard" {
    const group_allow = [_][]const u8{"*"};
    var ch = MaxChannel{
        .allocator = std.testing.allocator,
        .bot_token = "test-token",
        .allow_from = &.{},
        .group_allow_from = &group_allow,
        .group_policy = "allowlist",
    };
    try std.testing.expect(ch.isGroupUserAllowed("anyone"));
}

test "processUpdate message_created produces ChannelMessage" {
    const allocator = std.testing.allocator;
    const allow = [_][]const u8{"*"};
    var ch = testChannelWithAllowFrom(&allow);
    const json =
        \\{"update_type":"message_created","timestamp":1710000000,
        \\"message":{"sender":{"user_id":"42","name":"Alice","username":"alice"},
        \\"recipient":{"chat_id":"100","chat_type":"dialog"},
        \\"body":{"mid":"msg-1","text":"Hello"}}}
    ;
    var parsed = try parseTestJson(allocator, json);
    defer parsed.deinit();

    const msg = ch.processUpdate(allocator, parsed.value) orelse return error.TestUnexpectedResult;
    defer msg.deinit(allocator);

    try std.testing.expectEqualStrings("msg-1", msg.id);
    try std.testing.expectEqualStrings("alice", msg.sender);
    try std.testing.expectEqualStrings("Hello", msg.content);
    try std.testing.expectEqualStrings("max", msg.channel);
    try std.testing.expectEqualStrings("100", msg.reply_target.?);
    try std.testing.expectEqualStrings("Alice", msg.first_name.?);
    try std.testing.expect(!msg.is_group);
    try std.testing.expectEqual(@as(u64, 1710000000), msg.timestamp);
}

test "processUpdate message_created group chat" {
    const allocator = std.testing.allocator;
    const allow = [_][]const u8{"*"};
    var ch = MaxChannel{
        .allocator = allocator,
        .bot_token = "test-token",
        .allow_from = &allow,
        .group_allow_from = &allow,
        .group_policy = "allowlist",
    };
    const json =
        \\{"update_type":"message_created","timestamp":1710000001,
        \\"message":{"sender":{"user_id":"42","name":"Alice","username":"alice"},
        \\"recipient":{"chat_id":"200","chat_type":"chat"},
        \\"body":{"mid":"msg-2","text":"Group msg"}}}
    ;
    var parsed = try parseTestJson(allocator, json);
    defer parsed.deinit();

    const msg = ch.processUpdate(allocator, parsed.value) orelse return error.TestUnexpectedResult;
    defer msg.deinit(allocator);

    try std.testing.expectEqualStrings("200", msg.reply_target.?);
    try std.testing.expect(msg.is_group);
}

test "processUpdate unauthorized user returns null" {
    const allocator = std.testing.allocator;
    const allow = [_][]const u8{"bob"};
    var ch = testChannelWithAllowFrom(&allow);
    const json =
        \\{"update_type":"message_created","timestamp":1710000000,
        \\"message":{"sender":{"user_id":"42","name":"Alice","username":"alice"},
        \\"recipient":{"chat_id":"100","chat_type":"dialog"},
        \\"body":{"mid":"msg-1","text":"Hello"}}}
    ;
    var parsed = try parseTestJson(allocator, json);
    defer parsed.deinit();

    try std.testing.expect(ch.processUpdate(allocator, parsed.value) == null);
}

test "processUpdate message_callback maps to ChannelMessage" {
    const allocator = std.testing.allocator;
    const allow = [_][]const u8{"*"};
    var ch = testChannelWithAllowFrom(&allow);
    const json =
        \\{"update_type":"message_callback","callback_id":"cb-1",
        \\"callback":{"payload":"opt1","user":{"user_id":"42","name":"Alice"},
        \\"message":{"recipient":{"chat_id":"100"}}}}
    ;
    var parsed = try parseTestJson(allocator, json);
    defer parsed.deinit();

    const msg = ch.processUpdate(allocator, parsed.value) orelse return error.TestUnexpectedResult;
    defer msg.deinit(allocator);

    try std.testing.expectEqualStrings("cb-1", msg.id);
    try std.testing.expectEqualStrings("42", msg.sender);
    try std.testing.expectEqualStrings("opt1", msg.content);
    try std.testing.expectEqualStrings("max", msg.channel);
    try std.testing.expectEqualStrings("100", msg.reply_target.?);
}

test "processUpdate bot_started with payload" {
    const allocator = std.testing.allocator;
    const allow = [_][]const u8{"*"};
    var ch = testChannelWithAllowFrom(&allow);
    const json =
        \\{"update_type":"bot_started","chat_id":"100",
        \\"user":{"user_id":"42","name":"Alice"},"payload":"deep-link-data"}
    ;
    var parsed = try parseTestJson(allocator, json);
    defer parsed.deinit();

    const msg = ch.processUpdate(allocator, parsed.value) orelse return error.TestUnexpectedResult;
    defer msg.deinit(allocator);

    try std.testing.expectEqualStrings("/start deep-link-data", msg.content);
    try std.testing.expectEqualStrings("max", msg.channel);
    try std.testing.expectEqualStrings("100", msg.reply_target.?);
    try std.testing.expectEqualStrings("Alice", msg.first_name.?);
}

test "processUpdate bot_started without payload" {
    const allocator = std.testing.allocator;
    const allow = [_][]const u8{"*"};
    var ch = testChannelWithAllowFrom(&allow);
    const json =
        \\{"update_type":"bot_started","chat_id":"200",
        \\"user":{"user_id":"99","name":"Bob"}}
    ;
    var parsed = try parseTestJson(allocator, json);
    defer parsed.deinit();

    const msg = ch.processUpdate(allocator, parsed.value) orelse return error.TestUnexpectedResult;
    defer msg.deinit(allocator);

    try std.testing.expectEqualStrings("/start", msg.content);
}

test "processUpdate ignored type returns null" {
    const allocator = std.testing.allocator;
    const allow = [_][]const u8{"*"};
    var ch = testChannelWithAllowFrom(&allow);
    const json =
        \\{"update_type":"bot_stopped","chat_id":"100",
        \\"user":{"user_id":"42","name":"Alice"}}
    ;
    var parsed = try parseTestJson(allocator, json);
    defer parsed.deinit();

    try std.testing.expect(ch.processUpdate(allocator, parsed.value) == null);
}

test "processUpdate with attachments includes markers" {
    const allocator = std.testing.allocator;
    const allow = [_][]const u8{"*"};
    var ch = testChannelWithAllowFrom(&allow);
    const json =
        \\{"update_type":"message_created","timestamp":1710000000,
        \\"message":{"sender":{"user_id":"42","name":"Alice","username":"alice"},
        \\"recipient":{"chat_id":"100","chat_type":"dialog"},
        \\"body":{"mid":"msg-3","text":"Check this",
        \\"attachments":[{"type":"image","payload":{"url":"https://example.com/photo.jpg"}}]}}}
    ;
    var parsed = try parseTestJson(allocator, json);
    defer parsed.deinit();

    const msg = ch.processUpdate(allocator, parsed.value) orelse return error.TestUnexpectedResult;
    defer msg.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, msg.content, "[IMAGE:") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg.content, "https://example.com/photo.jpg") != null);
}

test "sendTextChunked sends short message in single call" {
    var ch = testChannel();
    // In test mode, sendMessage is mocked so this should not error
    try ch.sendTextChunked("100", "Hello world");
}

test "text splitting at MAX_MESSAGE_LEN boundary" {
    const effective_max = MAX_MESSAGE_LEN - CONTINUATION_MARKER.len;
    var it = root.splitMessage("a" ** 5000, effective_max);
    const chunk1 = it.next().?;
    try std.testing.expect(chunk1.len <= effective_max);
    try std.testing.expect(it.next() != null);
}

test "CONTINUATION_MARKER is correct" {
    try std.testing.expect(CONTINUATION_MARKER.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, CONTINUATION_MARKER, "\u{23EC}") != null);
}

test "vtableSendEvent chunk accumulates in draft buffer" {
    var ch = testChannel();
    defer ch.deinitDraftBuffers();

    try ch.channel().sendEvent("12345", "Hello ", &.{}, .chunk);
    try ch.channel().sendEvent("12345", "world", &.{}, .chunk);

    ch.draft_mu.lock();
    defer ch.draft_mu.unlock();
    const draft = ch.draft_buffers.get("12345") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Hello world", draft.buffer.items);
}

test "vtableSendEvent final cleans up draft state" {
    var ch = testChannel();
    defer ch.deinitDraftBuffers();

    try ch.channel().sendEvent("12345", "chunk data", &.{}, .chunk);

    {
        ch.draft_mu.lock();
        defer ch.draft_mu.unlock();
        try std.testing.expect(ch.draft_buffers.get("12345") != null);
    }

    try ch.channel().sendEvent("12345", "", &.{}, .final);

    {
        ch.draft_mu.lock();
        defer ch.draft_mu.unlock();
        try std.testing.expect(ch.draft_buffers.get("12345") == null);
    }
}

test "vtableSendEvent chunk assigns unique entry per chat" {
    var ch = testChannel();
    defer ch.deinitDraftBuffers();

    try ch.channel().sendEvent("111", "a", &.{}, .chunk);
    try ch.channel().sendEvent("222", "b", &.{}, .chunk);

    ch.draft_mu.lock();
    defer ch.draft_mu.unlock();
    const d1 = ch.draft_buffers.get("111") orelse return error.TestUnexpectedResult;
    const d2 = ch.draft_buffers.get("222") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a", d1.buffer.items);
    try std.testing.expectEqualStrings("b", d2.buffer.items);
}

test "vtableSendEvent disabled streaming is noop" {
    var ch = testChannel();
    ch.streaming_enabled = false;
    defer ch.deinitDraftBuffers();

    try ch.channel().sendEvent("12345", "data", &.{}, .chunk);

    ch.draft_mu.lock();
    defer ch.draft_mu.unlock();
    try std.testing.expect(ch.draft_buffers.get("12345") == null);
}

test "vtableSendEvent empty chunk is ignored" {
    var ch = testChannel();
    defer ch.deinitDraftBuffers();

    try ch.channel().sendEvent("12345", "", &.{}, .chunk);

    ch.draft_mu.lock();
    defer ch.draft_mu.unlock();
    try std.testing.expect(ch.draft_buffers.get("12345") == null);
}

test "vtableSendEvent final on nonexistent chat is safe" {
    var ch = testChannel();
    defer ch.deinitDraftBuffers();

    try ch.channel().sendEvent("nonexistent", "", &.{}, .final);
}

test "parseAttachmentMarkers extracts image marker" {
    const allocator = std.testing.allocator;
    const parsed = try parseAttachmentMarkers(allocator, "Check [IMAGE:/tmp/photo.png] this");
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), parsed.attachments.len);
    try std.testing.expect(parsed.attachments[0].kind == .image);
    try std.testing.expectEqualStrings("/tmp/photo.png", parsed.attachments[0].target);
    try std.testing.expectEqualStrings("Check  this", parsed.remaining_text);
}

test "parseAttachmentMarkers handles multiple markers" {
    const allocator = std.testing.allocator;
    const parsed = try parseAttachmentMarkers(allocator, "[IMAGE:a.png] text [DOCUMENT:b.pdf]");
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), parsed.attachments.len);
    try std.testing.expect(parsed.attachments[0].kind == .image);
    try std.testing.expect(parsed.attachments[1].kind == .document);
    try std.testing.expectEqualStrings("text", parsed.remaining_text);
}

test "parseAttachmentMarkers preserves non-marker brackets" {
    const allocator = std.testing.allocator;
    const parsed = try parseAttachmentMarkers(allocator, "hello [world] there");
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), parsed.attachments.len);
    try std.testing.expectEqualStrings("hello [world] there", parsed.remaining_text);
}

test "parseAttachmentMarkers video and audio" {
    const allocator = std.testing.allocator;
    const parsed = try parseAttachmentMarkers(allocator, "[VIDEO:v.mp4][AUDIO:a.mp3]");
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), parsed.attachments.len);
    try std.testing.expect(parsed.attachments[0].kind == .video);
    try std.testing.expect(parsed.attachments[1].kind == .audio);
}

test "MAX_MESSAGE_LEN is 4000" {
    try std.testing.expectEqual(@as(usize, 4000), MAX_MESSAGE_LEN);
}

test "vtable constant has all required methods" {
    const v = MaxChannel.vtable;
    try std.testing.expect(v.start == &MaxChannel.vtableStart);
    try std.testing.expect(v.stop == &MaxChannel.vtableStop);
    try std.testing.expect(v.send == &MaxChannel.vtableSend);
    try std.testing.expect(v.name == &MaxChannel.vtableName);
    try std.testing.expect(v.healthCheck == &MaxChannel.vtableHealthCheck);
    try std.testing.expect(v.sendEvent != null);
    try std.testing.expect(v.sendRich != null);
}

test "channel interface healthCheck dispatches correctly" {
    var ch = testChannel();
    const iface = ch.channel();
    try std.testing.expect(iface.healthCheck());
}

test "initFromConfig sets all fields" {
    const cfg = config_types.MaxConfig{
        .bot_token = "my-token",
        .account_id = "prod",
        .proxy = "http://proxy:8080",
        .streaming = false,
        .require_mention = true,
    };
    const ch = MaxChannel.initFromConfig(std.testing.allocator, cfg);
    try std.testing.expectEqualStrings("my-token", ch.bot_token);
    try std.testing.expectEqualStrings("prod", ch.account_id);
    try std.testing.expectEqualStrings("http://proxy:8080", ch.proxy.?);
    try std.testing.expect(!ch.streaming_enabled);
    try std.testing.expect(ch.require_mention);
}

test "send invokes sendMessage without error" {
    var ch = testChannel();
    // Test mode: API calls are mocked, so this should succeed
    try ch.sendMessage("100", "Hello, world!");
}

test "sendRichPayload without choices falls back to send" {
    var ch = testChannel();
    try ch.sendRichPayload("100", .{ .text = "just text" });
}

test "isAuthorized open group policy allows everyone" {
    const allow = [_][]const u8{"bob"};
    var ch = MaxChannel{
        .allocator = std.testing.allocator,
        .bot_token = "test-token",
        .allow_from = &allow,
        .group_allow_from = &.{},
        .group_policy = "open",
    };
    try std.testing.expect(ch.isAuthorized("eve", true));
    // But DM still restricted
    try std.testing.expect(!ch.isAuthorized("eve", false));
    try std.testing.expect(ch.isAuthorized("bob", false));
}

test "isAuthorized disabled group policy denies everyone" {
    const allow = [_][]const u8{"*"};
    var ch = MaxChannel{
        .allocator = std.testing.allocator,
        .bot_token = "test-token",
        .allow_from = &allow,
        .group_allow_from = &.{},
        .group_policy = "disabled",
    };
    try std.testing.expect(!ch.isAuthorized("alice", true));
    // DM still allowed
    try std.testing.expect(ch.isAuthorized("alice", false));
}

test "DraftState accumulation" {
    const allocator = std.testing.allocator;
    var state = DraftState{};
    defer state.deinit(allocator);

    try state.buffer.appendSlice(allocator, "Hello ");
    try state.buffer.appendSlice(allocator, "world");
    try std.testing.expectEqualStrings("Hello world", state.buffer.items);
}

test "vtableStop cleans up all resources" {
    var ch = testChannel();
    MaxChannel.vtableStart(@ptrCast(&ch)) catch {};
    MaxChannel.vtableStop(@ptrCast(&ch));

    // After stop, all state should be cleaned
    try std.testing.expect(ch.marker == null);
    try std.testing.expect(!ch.running);
}

test "AttachmentKind apiFileType mapping" {
    try std.testing.expectEqualStrings("photo", AttachmentKind.image.apiFileType());
    try std.testing.expectEqualStrings("file", AttachmentKind.document.apiFileType());
    try std.testing.expectEqualStrings("video", AttachmentKind.video.apiFileType());
    try std.testing.expectEqualStrings("file", AttachmentKind.audio.apiFileType());
}

test "pollUpdates returns empty in test mode" {
    const allocator = std.testing.allocator;
    var ch = testChannel();
    const messages = try ch.pollUpdates(allocator);
    defer {
        for (messages) |*msg| {
            var m = msg.*;
            m.deinit(allocator);
        }
        if (messages.len > 0) allocator.free(messages);
    }
    try std.testing.expectEqual(@as(usize, 0), messages.len);
}

test {
    @import("std").testing.refAllDecls(@This());
}
