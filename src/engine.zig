const std = @import("std");
const Allocator = std.mem.Allocator;
const html_escape = @import("html_escape.zig");

/// A single segment of a parsed template.
pub const Segment = union(enum) {
    literal: []const u8,
    variable: []const u8,
    raw_variable: []const u8,
    conditional: Conditional,
    loop: Loop,
    comment: void,
    with_block: WithBlock,
    raw_block: []const u8,
    yield: []const u8, // name: "" for default {{{yield}}}, "head" for {{{yield_head}}}, etc.
    piped_variable: PipedVariable,

    pub const Pipe = struct {
        name: []const u8,
        arg: []const u8, // "" if no arg
        arg2: []const u8, // "" if no second arg (used by pluralize)
    };

    pub const PipedVariable = struct {
        path: []const u8,
        pipes: []const Pipe,
        is_raw: bool,
    };

    pub const Conditional = struct {
        condition: []const u8,
        then_body: []const Segment,
        else_body: []const Segment,
    };

    pub const Loop = struct {
        collection: []const u8,
        body: []const Segment,
    };

    pub const WithBlock = struct {
        binding: []const u8,
        body: []const Segment,
    };
};

/// Parse result from an inner parse call.
const ParseResult = struct {
    segments: []const Segment,
    consumed: usize,
};

/// Compile a template string into segments at comptime.
pub fn parse(comptime source: []const u8) []const Segment {
    comptime {
        @setEvalBranchQuota(100_000);
        const result = parseInner(source, null);
        return result.segments;
    }
}

/// Recursive inner parser. When `end_marker` is set, stops at that closing tag.
fn parseInner(comptime source: []const u8, comptime end_marker: ?[]const u8) ParseResult {
    comptime {
        @setEvalBranchQuota(100_000);

        // Pass 1: count segments
        const count = countSegments(source, end_marker);

        // Pass 2: build segments
        var segments: [count.n]Segment = undefined;
        var seg_idx: usize = 0;
        var pos: usize = 0;

        while (pos < source.len) {
            // Check for end marker
            if (end_marker) |marker| {
                if (pos + marker.len <= source.len and
                    eql(source[pos .. pos + marker.len], marker))
                {
                    break;
                }
            }

            // Look for next tag
            if (findTag(source, pos)) |tag| {
                // Literal before the tag
                if (tag.start > pos) {
                    segments[seg_idx] = .{ .literal = source[pos..tag.start] };
                    seg_idx += 1;
                }

                // Process the tag
                const tag_result = processTag(source, tag);
                segments[seg_idx] = tag_result.segment;
                seg_idx += 1;
                pos = tag_result.next_pos;
            } else {
                // Rest is literal
                const end_pos = if (end_marker) |marker|
                    indexOf(source, marker, pos) orelse source.len
                else
                    source.len;
                if (end_pos > pos) {
                    segments[seg_idx] = .{ .literal = source[pos..end_pos] };
                    seg_idx += 1;
                }
                pos = end_pos;
            }
        }

        const final = segments;
        return .{
            .segments = &final,
            .consumed = if (end_marker) |marker|
                pos + marker.len
            else
                pos,
        };
    }
}

/// A located tag in the source.
const TagInfo = struct {
    start: usize, // position of first '{'
    content: []const u8, // trimmed content between delimiters
    end: usize, // position after last '}'
    is_raw: bool, // triple-brace {{{...}}}
    is_raw_block: bool, // quad-brace {{{{raw}}}} block
};

/// Find the next template tag starting from `pos`.
fn findTag(comptime source: []const u8, comptime pos: usize) ?TagInfo {
    comptime {
        var i = pos;
        while (i + 1 < source.len) : (i += 1) {
            if (source[i] == '{' and source[i + 1] == '{') {
                // Quad brace? {{{{raw}}}} block
                if (i + 3 < source.len and source[i + 2] == '{' and source[i + 3] == '{') {
                    // Expect {{{{raw}}}} opening
                    const open_end = indexOf(source, "}}}}", i + 4) orelse
                        @compileError("Unclosed quad-brace opening tag");
                    const tag_name = trim(source[i + 4 .. open_end]);
                    if (!eql(tag_name, "raw")) {
                        @compileError("Only {{{{raw}}}} is supported, got {{{{" ++ tag_name ++ "}}}}");
                    }
                    const content_start = open_end + 4;
                    // Find {{{{/raw}}}}
                    const close = indexOf(source, "{{{{/raw}}}}", content_start) orelse
                        @compileError("Unclosed {{{{raw}}}} block — missing {{{{/raw}}}}");
                    return .{
                        .start = i,
                        .content = source[content_start..close],
                        .end = close + "{{{{/raw}}}}".len,
                        .is_raw = false,
                        .is_raw_block = true,
                    };
                }
                // Triple brace?
                if (i + 2 < source.len and source[i + 2] == '{') {
                    // Find closing }}}
                    const close = indexOf(source, "}}}", i + 3) orelse
                        @compileError("Unclosed triple-brace tag");
                    return .{
                        .start = i,
                        .content = trim(source[i + 3 .. close]),
                        .end = close + 3,
                        .is_raw = true,
                        .is_raw_block = false,
                    };
                }
                // Double brace
                const close = indexOf(source, "}}", i + 2) orelse
                    @compileError("Unclosed tag");
                return .{
                    .start = i,
                    .content = trim(source[i + 2 .. close]),
                    .end = close + 2,
                    .is_raw = false,
                    .is_raw_block = false,
                };
            }
        }
        return null;
    }
}

/// Tag processing result.
const TagResult = struct {
    segment: Segment,
    next_pos: usize,
};

/// Process a single tag and return the resulting segment.
fn processTag(comptime source: []const u8, comptime tag: TagInfo) TagResult {
    comptime {
        const content = tag.content;

        // Raw block: {{{{raw}}}}...{{{{/raw}}}}
        if (tag.is_raw_block) {
            return .{ .segment = .{ .raw_block = content }, .next_pos = tag.end };
        }

        // Raw variable: {{{name}}} — check for yield / yield_*
        if (tag.is_raw) {
            if (eql(content, "yield")) {
                return .{ .segment = .{ .yield = "" }, .next_pos = tag.end };
            }
            if (startsWith(content, "yield_")) {
                return .{ .segment = .{ .yield = content[6..] }, .next_pos = tag.end };
            }
            // Check for pipe syntax: {{{name | upper}}}
            if (indexOf(content, "|", 0)) |_| {
                return .{ .segment = .{ .piped_variable = parsePipedVariable(content, true) }, .next_pos = tag.end };
            }
            return .{ .segment = .{ .raw_variable = content }, .next_pos = tag.end };
        }

        // Comment: {{! ... }}
        if (content.len > 0 and content[0] == '!') {
            return .{ .segment = .{ .comment = {} }, .next_pos = tag.end };
        }

        // Partial inclusion: {{> name}} — should be pre-processed
        if (content.len > 0 and content[0] == '>') {
            const partial_name = trim(content[1..]);
            @compileError("Unresolved partial: {{> " ++ partial_name ++ "}} — use templateWithPartials() to inline partials before parsing");
        }

        // Block tags: {{#if ...}}, {{#each ...}}, {{#with ...}}
        if (content.len > 1 and content[0] == '#') {
            const rest = trim(content[1..]);

            if (startsWith(rest, "if ")) {
                const cond = trim(rest[3..]);
                const else_marker = "{{else}}";
                const end_marker_str = "{{/if}}";

                // Parse then-body (from tag.end to either {{else}} or {{/if}})
                const after_tag = source[tag.end..];
                const else_pos = indexOf(after_tag, else_marker, 0);
                const end_pos = indexOf(after_tag, end_marker_str, 0) orelse
                    @compileError("Unclosed {{#if}} block — missing {{/if}}");

                if (else_pos) |ep| {
                    if (ep < end_pos) {
                        // Has else branch
                        const then_result = parseInner(after_tag[0..ep], null);
                        const else_start = ep + else_marker.len;
                        const else_result = parseInner(after_tag[else_start..end_pos], null);
                        return .{
                            .segment = .{ .conditional = .{
                                .condition = cond,
                                .then_body = then_result.segments,
                                .else_body = else_result.segments,
                            } },
                            .next_pos = tag.end + end_pos + end_marker_str.len,
                        };
                    }
                }

                // No else branch
                const then_result = parseInner(after_tag[0..end_pos], null);
                const empty: [0]Segment = .{};
                return .{
                    .segment = .{ .conditional = .{
                        .condition = cond,
                        .then_body = then_result.segments,
                        .else_body = &empty,
                    } },
                    .next_pos = tag.end + end_pos + end_marker_str.len,
                };
            }

            if (startsWith(rest, "each ")) {
                const collection = trim(rest[5..]);
                const end_marker_str = "{{/each}}";

                const after_tag = source[tag.end..];
                const end_pos = indexOf(after_tag, end_marker_str, 0) orelse
                    @compileError("Unclosed {{#each}} block — missing {{/each}}");

                const body_result = parseInner(after_tag[0..end_pos], null);
                return .{
                    .segment = .{ .loop = .{
                        .collection = collection,
                        .body = body_result.segments,
                    } },
                    .next_pos = tag.end + end_pos + end_marker_str.len,
                };
            }

            if (startsWith(rest, "with ")) {
                const binding = trim(rest[5..]);
                const end_marker_str = "{{/with}}";

                const after_tag = source[tag.end..];
                const end_pos = indexOf(after_tag, end_marker_str, 0) orelse
                    @compileError("Unclosed {{#with}} block — missing {{/with}}");

                const body_result = parseInner(after_tag[0..end_pos], null);
                return .{
                    .segment = .{ .with_block = .{
                        .binding = binding,
                        .body = body_result.segments,
                    } },
                    .next_pos = tag.end + end_pos + end_marker_str.len,
                };
            }

            @compileError("Unknown block tag: {{#" ++ rest ++ "}}");
        }

        // Variable: {{name}} or piped: {{name | upper}}
        if (indexOf(content, "|", 0)) |_| {
            return .{ .segment = .{ .piped_variable = parsePipedVariable(content, false) }, .next_pos = tag.end };
        }
        return .{ .segment = .{ .variable = content }, .next_pos = tag.end };
    }
}

/// Count segments (pass 1) — mirrors the logic of parseInner but only counts.
const CountResult = struct { n: usize, consumed: usize };

fn countSegments(comptime source: []const u8, comptime end_marker: ?[]const u8) CountResult {
    comptime {
        var n: usize = 0;
        var pos: usize = 0;

        while (pos < source.len) {
            if (end_marker) |marker| {
                if (pos + marker.len <= source.len and
                    eql(source[pos .. pos + marker.len], marker))
                {
                    break;
                }
            }

            if (findTag(source, pos)) |tag| {
                if (tag.start > pos) n += 1; // literal
                n += 1; // the tag itself

                // For block tags, skip past the closing tag
                const content = tag.content;
                if (!tag.is_raw and !tag.is_raw_block and content.len > 1 and content[0] == '#') {
                    const rest = trim(content[1..]);
                    if (startsWith(rest, "if ")) {
                        const after_tag = source[tag.end..];
                        const end_pos = indexOf(after_tag, "{{/if}}", 0) orelse
                            @compileError("Unclosed {{#if}} block");
                        pos = tag.end + end_pos + "{{/if}}".len;
                    } else if (startsWith(rest, "each ")) {
                        const after_tag = source[tag.end..];
                        const end_pos = indexOf(after_tag, "{{/each}}", 0) orelse
                            @compileError("Unclosed {{#each}} block");
                        pos = tag.end + end_pos + "{{/each}}".len;
                    } else if (startsWith(rest, "with ")) {
                        const after_tag = source[tag.end..];
                        const end_pos = indexOf(after_tag, "{{/with}}", 0) orelse
                            @compileError("Unclosed {{#with}} block");
                        pos = tag.end + end_pos + "{{/with}}".len;
                    } else {
                        @compileError("Unknown block tag");
                    }
                } else {
                    pos = tag.end;
                }
            } else {
                const end_pos = if (end_marker) |marker|
                    indexOf(source, marker, pos) orelse source.len
                else
                    source.len;
                if (end_pos > pos) n += 1;
                pos = end_pos;
            }
        }

        return .{
            .n = n,
            .consumed = if (end_marker) |marker|
                pos + marker.len
            else
                pos,
        };
    }
}

// ── Comptime string helpers ────────────────────────────────────────────

fn eql(comptime a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn indexOf(comptime haystack: []const u8, comptime needle: []const u8, comptime start: usize) ?usize {
    if (needle.len == 0) return start;
    if (start + needle.len > haystack.len) return null;
    var i = start;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (eql(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn startsWith(comptime s: []const u8, comptime prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    return eql(s[0..prefix.len], prefix);
}

fn trim(comptime s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t' or s[start] == '\n' or s[start] == '\r')) {
        start += 1;
    }
    var end: usize = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\n' or s[end - 1] == '\r')) {
        end -= 1;
    }
    return s[start..end];
}

/// Parse a piped variable expression like "name | upper | truncate:20" at comptime.
fn parsePipedVariable(comptime content: []const u8, comptime is_raw: bool) Segment.PipedVariable {
    comptime {
        // Split on first '|' → field path + pipe chain
        const pipe_pos = indexOf(content, "|", 0).?;
        const path = trim(content[0..pipe_pos]);
        const pipe_str = trim(content[pipe_pos + 1 ..]);

        // Count pipes (split on '|')
        const pipe_count = countChar(pipe_str, '|') + 1;
        var pipes: [pipe_count]Segment.Pipe = undefined;
        var pi: usize = 0;
        var rest: []const u8 = pipe_str;

        while (rest.len > 0) {
            const next_pipe = indexOf(rest, "|", 0);
            const this_pipe = if (next_pipe) |np| trim(rest[0..np]) else trim(rest);
            rest = if (next_pipe) |np| rest[np + 1 ..] else "";

            // Parse name:arg or name:"arg1":"arg2" or just name
            const colon_pos = indexOf(this_pipe, ":", 0);
            if (colon_pos) |cp| {
                const name = trim(this_pipe[0..cp]);
                const args_part = this_pipe[cp + 1 ..];
                // Check for quoted args: "arg1":"arg2"
                if (args_part.len > 0 and args_part[0] == '"') {
                    // Parse first quoted arg
                    const first_end = indexOf(args_part, "\"", 1) orelse
                        @compileError("Unclosed quote in pipe arg: " ++ this_pipe);
                    const first_arg = args_part[1..first_end];
                    // Check for second quoted arg after ":"
                    const after_first = args_part[first_end + 1 ..];
                    if (after_first.len > 0 and after_first[0] == ':' and after_first.len > 1 and after_first[1] == '"') {
                        const second_end = indexOf(after_first, "\"", 2) orelse
                            @compileError("Unclosed quote in pipe second arg: " ++ this_pipe);
                        const second_arg = after_first[2..second_end];
                        pipes[pi] = .{ .name = name, .arg = first_arg, .arg2 = second_arg };
                    } else {
                        pipes[pi] = .{ .name = name, .arg = first_arg, .arg2 = "" };
                    }
                } else {
                    pipes[pi] = .{ .name = name, .arg = trim(args_part), .arg2 = "" };
                }
            } else {
                pipes[pi] = .{ .name = this_pipe, .arg = "", .arg2 = "" };
            }
            pi += 1;
        }

        const final = pipes;
        return .{
            .path = path,
            .pipes = &final,
            .is_raw = is_raw,
        };
    }
}

/// Count occurrences of a character in a comptime string.
fn countChar(comptime s: []const u8, comptime ch: u8) usize {
    comptime {
        var count: usize = 0;
        for (s) |c| {
            if (c == ch) count += 1;
        }
        return count;
    }
}

// ── Public API ─────────────────────────────────────────────────────────

/// Internal: generate a template type from pre-parsed segments.
fn makeTemplateType(comptime segments: []const Segment) type {
    return struct {
        pub fn render(allocator: Allocator, data: anytype) ![]const u8 {
            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(allocator);
            try renderSegments(segments, data, &buf, allocator, null, {});
            return buf.toOwnedSlice(allocator);
        }

        pub fn renderWithYield(allocator: Allocator, data: anytype, yield_content: []const u8) ![]const u8 {
            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(allocator);
            try renderSegments(segments, data, &buf, allocator, yield_content, {});
            return buf.toOwnedSlice(allocator);
        }

        /// Render with both a main yield content and named yield blocks.
        /// `named_yields` is a struct with fields for each named yield
        /// (e.g. `.{ .head = "<link ...>", .scripts = "<script ...>" }`).
        pub fn renderWithYieldAndNamed(allocator: Allocator, data: anytype, yield_content: []const u8, named_yields: anytype) ![]const u8 {
            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(allocator);
            try renderSegments(segments, data, &buf, allocator, yield_content, named_yields);
            return buf.toOwnedSlice(allocator);
        }

        /// Render with named yields using a struct that has `.content` for the
        /// main yield and additional fields for named yields.
        pub fn renderWithNamedYields(allocator: Allocator, data: anytype, yields: anytype) ![]const u8 {
            const content = if (@hasField(@TypeOf(yields), "content")) yields.content else "";
            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(allocator);
            try renderSegments(segments, data, &buf, allocator, content, yields);
            return buf.toOwnedSlice(allocator);
        }
    };
}

/// Compile a template at comptime and return a type with a `render` method.
///
/// Usage:
/// ```
/// const tmpl = pidgn.template(@embedFile("templates/index.html.pidgn"));
///
/// fn handler(ctx: *pidgn.Context) !void {
///     try ctx.render(tmpl, .ok, .{ .title = "Hello" });
/// }
/// ```
pub fn template(comptime source: []const u8) type {
    return makeTemplateType(comptime parse(source));
}

/// Compile a template with partials inlined at comptime.
///
/// Usage:
/// ```
/// const Page = pidgn.templateWithPartials(
///     @embedFile("templates/page.html.pidgn"),
///     .{
///         .header = @embedFile("templates/partials/header.html.pidgn"),
///         .footer = @embedFile("templates/partials/footer.html.pidgn"),
///     },
/// );
/// ```
pub fn templateWithPartials(comptime source: []const u8, comptime partials: anytype) type {
    const processed = comptime preprocessPartials(source, partials);
    return makeTemplateType(comptime parse(processed));
}

/// Pre-process partial inclusions by replacing `{{> name}}` or `{{> name key="value" ...}}`
/// with the partial's source, optionally substituting literal arguments.
fn preprocessPartials(comptime source: []const u8, comptime partials: anytype) []const u8 {
    comptime {
        @setEvalBranchQuota(200_000);

        const partial_tag_open = "{{>";
        const partial_tag_close = "}}";

        // Pass 1: compute total output length
        var total_len: usize = 0;
        var scan_pos: usize = 0;

        while (scan_pos < source.len) {
            if (indexOf(source, partial_tag_open, scan_pos)) |tag_start| {
                // Add literal before this tag
                total_len += tag_start - scan_pos;

                const content_start = tag_start + partial_tag_open.len;
                const tag_end_offset = indexOf(source, partial_tag_close, content_start) orelse
                    @compileError("Unclosed partial tag {{> ...");
                const tag_content = trim(source[content_start..tag_end_offset]);

                // Split name from args
                const name_and_args = splitPartialNameAndArgs(tag_content);
                const name = name_and_args.name;

                // Look up partial source
                const partial_source = @field(partials, name);

                // Apply argument substitution if there are args
                if (name_and_args.args.len > 0) {
                    const substituted = substituteArgs(partial_source, name_and_args.args);
                    total_len += substituted.len;
                } else {
                    total_len += partial_source.len;
                }

                scan_pos = tag_end_offset + partial_tag_close.len;
            } else {
                total_len += source.len - scan_pos;
                break;
            }
        }

        // Pass 2: build output
        var result: [total_len]u8 = undefined;
        var out_pos: usize = 0;
        scan_pos = 0;

        while (scan_pos < source.len) {
            if (indexOf(source, partial_tag_open, scan_pos)) |tag_start| {
                // Copy literal before this tag
                const lit_len = tag_start - scan_pos;
                if (lit_len > 0) {
                    @memcpy(result[out_pos..][0..lit_len], source[scan_pos..tag_start]);
                    out_pos += lit_len;
                }

                const content_start = tag_start + partial_tag_open.len;
                const tag_end_offset = indexOf(source, partial_tag_close, content_start).?;
                const tag_content = trim(source[content_start..tag_end_offset]);

                const name_and_args = splitPartialNameAndArgs(tag_content);
                const name = name_and_args.name;

                // Copy partial source (with substitution if needed)
                const partial_source = @field(partials, name);
                if (name_and_args.args.len > 0) {
                    const substituted = substituteArgs(partial_source, name_and_args.args);
                    @memcpy(result[out_pos..][0..substituted.len], substituted);
                    out_pos += substituted.len;
                } else {
                    @memcpy(result[out_pos..][0..partial_source.len], partial_source);
                    out_pos += partial_source.len;
                }

                scan_pos = tag_end_offset + partial_tag_close.len;
            } else {
                const remaining = source.len - scan_pos;
                @memcpy(result[out_pos..][0..remaining], source[scan_pos..]);
                out_pos += remaining;
                break;
            }
        }

        const final = result;
        return &final;
    }
}

/// Split partial tag content into name and remaining args string.
/// E.g. `button type="primary" label="Click"` → name="button", args=`type="primary" label="Click"`
const PartialNameAndArgs = struct {
    name: []const u8,
    args: []const u8,
};

fn splitPartialNameAndArgs(comptime content: []const u8) PartialNameAndArgs {
    comptime {
        // Find first space to split name from args
        var i: usize = 0;
        while (i < content.len) : (i += 1) {
            if (content[i] == ' ' or content[i] == '\t') {
                const args = trim(content[i..]);
                return .{ .name = content[0..i], .args = args };
            }
        }
        return .{ .name = content, .args = "" };
    }
}

/// Substitute `{{key}}` placeholders in source with values from `key="value"` args string.
fn substituteArgs(comptime source: []const u8, comptime args_str: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(200_000);

        // Parse all key="value" pairs from args_str
        const max_args = 16;
        var keys: [max_args][]const u8 = undefined;
        var vals: [max_args][]const u8 = undefined;
        var arg_count: usize = 0;

        var apos: usize = 0;
        while (apos < args_str.len) {
            // Skip whitespace
            while (apos < args_str.len and (args_str[apos] == ' ' or args_str[apos] == '\t')) {
                apos += 1;
            }
            if (apos >= args_str.len) break;

            // Find '='
            const eq_pos = indexOf(args_str, "=", apos) orelse
                @compileError("Partial argument missing '=': " ++ args_str[apos..]);
            const key = trim(args_str[apos..eq_pos]);

            // Expect '"' after '='
            var vstart = eq_pos + 1;
            while (vstart < args_str.len and (args_str[vstart] == ' ' or args_str[vstart] == '\t')) {
                vstart += 1;
            }
            if (vstart >= args_str.len or args_str[vstart] != '"')
                @compileError("Partial argument value must be quoted: " ++ key);
            vstart += 1; // skip opening quote

            // Find closing quote
            const vend = indexOf(args_str, "\"", vstart) orelse
                @compileError("Unclosed quote in partial argument: " ++ key);
            const val = args_str[vstart..vend];

            keys[arg_count] = key;
            vals[arg_count] = val;
            arg_count += 1;
            apos = vend + 1;
        }

        // Now replace all occurrences of {{key}} with val in source
        var current: []const u8 = source;
        for (0..arg_count) |ai| {
            const pattern = "{{" ++ keys[ai] ++ "}}";
            current = replaceAll(current, pattern, vals[ai]);
        }
        return current;
    }
}

/// Comptime string replace: replace all occurrences of `pattern` with `replacement` in `source`.
fn replaceAll(comptime source: []const u8, comptime pattern: []const u8, comptime replacement: []const u8) []const u8 {
    comptime {
        if (pattern.len == 0) return source;

        // Pass 1: count occurrences
        var count: usize = 0;
        var cpos: usize = 0;
        while (cpos + pattern.len <= source.len) {
            if (eql(source[cpos..][0..pattern.len], pattern)) {
                count += 1;
                cpos += pattern.len;
            } else {
                cpos += 1;
            }
        }

        if (count == 0) return source;

        // Compute output length
        const out_len = source.len - (count * pattern.len) + (count * replacement.len);
        var result: [out_len]u8 = undefined;
        var out_pos: usize = 0;
        var spos: usize = 0;

        while (spos < source.len) {
            if (spos + pattern.len <= source.len and eql(source[spos..][0..pattern.len], pattern)) {
                @memcpy(result[out_pos..][0..replacement.len], replacement);
                out_pos += replacement.len;
                spos += pattern.len;
            } else {
                result[out_pos] = source[spos];
                out_pos += 1;
                spos += 1;
            }
        }

        const final = result;
        return &final;
    }
}

/// Walk the comptime segment tree at runtime, rendering into a buffer.
fn renderSegments(comptime segments: []const Segment, data: anytype, buf: *std.ArrayList(u8), allocator: Allocator, yield_content: ?[]const u8, named_yields: anytype) !void {
    const NamedYieldsType = @TypeOf(named_yields);
    inline for (segments) |seg| {
        switch (seg) {
            .literal => |text| {
                try buf.appendSlice(allocator, text);
            },
            .variable => |path| {
                const value = resolveField(data, path);
                const str = try renderValue(value, allocator);
                try html_escape.appendEscaped(buf, allocator, str);
            },
            .raw_variable => |path| {
                const value = resolveField(data, path);
                const str = try renderValue(value, allocator);
                try buf.appendSlice(allocator, str);
            },
            .conditional => |cond| {
                const truthy = resolveBool(data, cond.condition);
                if (truthy) {
                    try renderSegments(cond.then_body, data, buf, allocator, yield_content, named_yields);
                } else {
                    try renderSegments(cond.else_body, data, buf, allocator, yield_content, named_yields);
                }
            },
            .loop => |lp| {
                const slice = resolveSlice(data, lp.collection);
                for (slice) |item| {
                    try renderSegments(lp.body, item, buf, allocator, yield_content, named_yields);
                }
            },
            .comment => {},
            .with_block => |wb| {
                const scoped_data = resolveField(data, wb.binding);
                try renderSegments(wb.body, scoped_data, buf, allocator, yield_content, named_yields);
            },
            .raw_block => |text| {
                try buf.appendSlice(allocator, text);
            },
            .piped_variable => |pv| {
                const value = resolveField(data, pv.path);
                var str = try renderValue(value, allocator);
                // Apply each pipe in sequence
                inline for (pv.pipes) |pipe| {
                    str = try applyPipe(allocator, str, pipe);
                }
                if (pv.is_raw) {
                    try buf.appendSlice(allocator, str);
                } else {
                    try html_escape.appendEscaped(buf, allocator, str);
                }
            },
            .yield => |name| {
                if (name.len == 0) {
                    // Default yield — use yield_content
                    if (yield_content) |yc| {
                        try buf.appendSlice(allocator, yc);
                    }
                } else {
                    // Named yield — look up in named_yields struct
                    if (NamedYieldsType != void and NamedYieldsType != @TypeOf(.{})) {
                        if (@hasField(NamedYieldsType, name)) {
                            const val = @field(named_yields, name);
                            try buf.appendSlice(allocator, val);
                        }
                        // If field doesn't exist, produce empty output
                    }
                }
            },
        }
    }
}

// ── Field resolution ───────────────────────────────────────────────────

/// Resolve a dotted field path on a struct at comptime.
/// E.g. resolveField(data, "user.name") → @field(@field(data, "user"), "name")
inline fn resolveField(data: anytype, comptime path: []const u8) @TypeOf(resolveFieldType(data, path)) {
    const dot = comptime indexOf(path, ".", 0);
    if (comptime dot) |d| {
        return resolveField(@field(data, path[0..d]), path[d + 1 ..]);
    } else {
        return @field(data, path);
    }
}

/// Helper to let the compiler infer the resolved type for the return annotation.
inline fn resolveFieldType(data: anytype, comptime path: []const u8) @TypeOf(blk: {
    const dot = comptime indexOf(path, ".", 0);
    if (comptime dot) |d| {
        break :blk resolveFieldType(@field(data, path[0..d]), path[d + 1 ..]);
    } else {
        break :blk @field(data, path);
    }
}) {
    const dot = comptime indexOf(path, ".", 0);
    if (comptime dot) |d| {
        return resolveFieldType(@field(data, path[0..d]), path[d + 1 ..]);
    } else {
        return @field(data, path);
    }
}

/// Resolve a field to a bool for conditionals.
/// Supports: bool, ?T (null → false), slices (empty → false).
inline fn resolveBool(data: anytype, comptime path: []const u8) bool {
    const value = resolveField(data, path);
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    if (T == bool) return value;

    if (info == .optional) {
        return value != null;
    }

    // Slice: non-empty is truthy
    if (info == .pointer and info.pointer.size == .slice) {
        return value.len > 0;
    }

    // Fallback: any non-void value is truthy
    return true;
}

/// Resolve a field to a slice for iteration.
inline fn resolveSlice(data: anytype, comptime path: []const u8) ResolveSliceReturn(@TypeOf(resolveField(data, path))) {
    const value = resolveField(data, path);
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    // Already a slice
    if (info == .pointer and info.pointer.size == .slice) {
        return value;
    }

    // Pointer to array
    if (info == .pointer and info.pointer.size == .one) {
        const child_info = @typeInfo(info.pointer.child);
        if (child_info == .array) {
            return @as([]const child_info.array.child, value);
        }
    }

    @compileError("{{#each " ++ path ++ "}} requires a slice or pointer-to-array field");
}

fn ResolveSliceReturn(comptime T: type) type {
    const info = @typeInfo(T);
    if (info == .pointer and info.pointer.size == .slice) {
        return T;
    }
    if (info == .pointer and info.pointer.size == .one) {
        const child_info = @typeInfo(info.pointer.child);
        if (child_info == .array) {
            return []const child_info.array.child;
        }
    }
    @compileError("{{#each}} requires a slice or pointer-to-array field, got " ++ @typeName(T));
}

/// Coerce a value to a string for output.
/// Supports []const u8, *const [N]u8, and integer types.
inline fn coerceToString(value: anytype) []const u8 {
    const T = @TypeOf(value);
    if (T == []const u8) return value;
    if (T == []u8) return value;

    const info = @typeInfo(T);
    if (info == .pointer and info.pointer.size == .one) {
        const child = @typeInfo(info.pointer.child);
        if (child == .array and child.array.child == u8) {
            return value;
        }
    }

    if (info == .int or info == .comptime_int) {
        // For integer types, use a sentinel approach — this is handled at
        // runtime via the valueToIntStr path. We should not reach here for ints
        // when using the piped path, but for plain {{var}} we need the runtime path.
        @compileError("Integer template variables require pipe syntax or use valueToIntStr; got " ++ @typeName(T));
    }

    @compileError("Template variable must be []const u8, got " ++ @typeName(T));
}

/// Check at comptime whether a type is a string-like type.
fn isStringType(comptime T: type) bool {
    if (T == []const u8) return true;
    if (T == []u8) return true;
    const info = @typeInfo(T);
    if (info == .pointer and info.pointer.size == .one) {
        const child = @typeInfo(info.pointer.child);
        if (child == .array and child.array.child == u8) return true;
    }
    return false;
}

/// Check at comptime whether a type is an integer type.
fn isIntType(comptime T: type) bool {
    const info = @typeInfo(T);
    return info == .int or info == .comptime_int;
}

/// Render a value to a string, supporting both string and integer types.
/// For integers, allocates a formatted string via the allocator.
/// Returns the string representation.
inline fn renderValue(value: anytype, allocator: Allocator) ![]const u8 {
    const T = @TypeOf(value);
    if (comptime isStringType(T)) {
        return coerceToString(value);
    }
    if (comptime isIntType(T)) {
        return std.fmt.allocPrint(allocator, "{d}", .{value});
    }
    @compileError("Template variable must be []const u8 or integer, got " ++ @typeName(T));
}

// ── Date formatting support ────────────────────────────────────────────

const DateTime = struct {
    year: u16,
    month: u4,
    day: u5,
    hour: u5,
    minute: u6,
    second: u6,
};

fn timestampToDateTime(ts: i64) DateTime {
    const epoch = std.time.epoch;
    const es = epoch.EpochSeconds{ .secs = @intCast(ts) };
    const day_secs = es.getDaySeconds();
    const epoch_day = es.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return .{
        .year = year_day.year,
        .month = @intFromEnum(month_day.month),
        .day = month_day.day_index + 1,
        .hour = day_secs.getHoursIntoDay(),
        .minute = day_secs.getMinutesIntoHour(),
        .second = @intCast(@mod(ts, 60)),
    };
}

const month_names = [_][]const u8{
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
};

fn formatTimestamp(allocator: Allocator, ts: i64, comptime pattern: []const u8) ![]const u8 {
    const dt = timestampToDateTime(ts);

    var buf: [64]u8 = undefined;
    var pos: usize = 0;

    comptime var i: usize = 0;
    inline while (i < pattern.len) {
        if (comptime i + 4 <= pattern.len and eql(pattern[i .. i + 4], "YYYY")) {
            const digits = digitsBuf4(dt.year);
            if (pos + 4 > buf.len) return error.BufferOverflow;
            @memcpy(buf[pos..][0..4], &digits);
            pos += 4;
            i += 4;
        } else if (comptime i + 3 <= pattern.len and eql(pattern[i .. i + 3], "MMM")) {
            const name = month_names[@as(usize, dt.month) - 1];
            if (pos + 3 > buf.len) return error.BufferOverflow;
            @memcpy(buf[pos..][0..3], name[0..3]);
            pos += 3;
            i += 3;
        } else if (comptime i + 2 <= pattern.len and eql(pattern[i .. i + 2], "MM")) {
            const digits = digitsBuf2(dt.month);
            if (pos + 2 > buf.len) return error.BufferOverflow;
            @memcpy(buf[pos..][0..2], &digits);
            pos += 2;
            i += 2;
        } else if (comptime i + 2 <= pattern.len and eql(pattern[i .. i + 2], "DD")) {
            const digits = digitsBuf2(dt.day);
            if (pos + 2 > buf.len) return error.BufferOverflow;
            @memcpy(buf[pos..][0..2], &digits);
            pos += 2;
            i += 2;
        } else if (comptime i + 2 <= pattern.len and eql(pattern[i .. i + 2], "HH")) {
            const digits = digitsBuf2(dt.hour);
            if (pos + 2 > buf.len) return error.BufferOverflow;
            @memcpy(buf[pos..][0..2], &digits);
            pos += 2;
            i += 2;
        } else if (comptime i + 2 <= pattern.len and eql(pattern[i .. i + 2], "mm")) {
            const digits = digitsBuf2(dt.minute);
            if (pos + 2 > buf.len) return error.BufferOverflow;
            @memcpy(buf[pos..][0..2], &digits);
            pos += 2;
            i += 2;
        } else if (comptime i + 2 <= pattern.len and eql(pattern[i .. i + 2], "ss")) {
            const digits = digitsBuf2(dt.second);
            if (pos + 2 > buf.len) return error.BufferOverflow;
            @memcpy(buf[pos..][0..2], &digits);
            pos += 2;
            i += 2;
        } else {
            if (pos + 1 > buf.len) return error.BufferOverflow;
            buf[pos] = pattern[i];
            pos += 1;
            i += 1;
        }
    }

    return allocator.dupe(u8, buf[0..pos]);
}

fn digitsBuf2(val: anytype) [2]u8 {
    const v: u8 = @intCast(val);
    return .{ '0' + v / 10, '0' + v % 10 };
}

fn digitsBuf4(val: u16) [4]u8 {
    return .{
        '0' + @as(u8, @intCast(val / 1000)),
        '0' + @as(u8, @intCast(val % 1000 / 100)),
        '0' + @as(u8, @intCast(val % 100 / 10)),
        '0' + @as(u8, @intCast(val % 10)),
    };
}

/// Apply a single pipe transformation to the input string at runtime.
fn applyPipe(allocator: Allocator, input: []const u8, comptime pipe: Segment.Pipe) ![]const u8 {
    if (comptime eql(pipe.name, "truncate")) {
        const n = comptime std.fmt.parseInt(usize, pipe.arg, 10) catch
            @compileError("truncate pipe requires a numeric argument, got: " ++ pipe.arg);
        if (input.len > n) {
            const result = try allocator.alloc(u8, n + 3);
            @memcpy(result[0..n], input[0..n]);
            @memcpy(result[n..][0..3], "...");
            return result;
        }
        return input;
    }

    if (comptime eql(pipe.name, "upper")) {
        const result = try allocator.alloc(u8, input.len);
        for (input, 0..) |c, i| {
            result[i] = if (c >= 'a' and c <= 'z') c - 32 else c;
        }
        return result;
    }

    if (comptime eql(pipe.name, "lower")) {
        const result = try allocator.alloc(u8, input.len);
        for (input, 0..) |c, i| {
            result[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        }
        return result;
    }

    if (comptime eql(pipe.name, "default")) {
        if (input.len == 0) {
            return pipe.arg;
        }
        return input;
    }

    if (comptime eql(pipe.name, "pluralize")) {
        const singular = pipe.arg;
        const plural = pipe.arg2;
        // Parse input as integer count
        const count = std.fmt.parseInt(i64, input, 10) catch 0;
        const word = if (count == 1) singular else plural;
        return std.fmt.allocPrint(allocator, "{d} {s}", .{ count, word });
    }

    if (comptime eql(pipe.name, "format_date")) {
        const ts = std.fmt.parseInt(i64, input, 10) catch return input;
        return formatTimestamp(allocator, ts, pipe.arg);
    }

    // Unknown pipe — passthrough
    return input;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "literal only" {
    const T = template("Hello, world!");
    const result = try T.render(std.testing.allocator, .{});
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Hello, world!", result);
}

test "variable interpolation" {
    const T = template("Hello, {{name}}!");
    const result = try T.render(std.testing.allocator, .{ .name = "World" });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Hello, World!", result);
}

test "variable HTML escaping" {
    const T = template("{{content}}");
    const result = try T.render(std.testing.allocator, .{ .content = "<script>alert('xss')</script>" });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("&lt;script&gt;alert(&#x27;xss&#x27;)&lt;/script&gt;", result);
}

test "raw variable no escaping" {
    const T = template("{{{content}}}");
    const result = try T.render(std.testing.allocator, .{ .content = "<b>bold</b>" });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<b>bold</b>", result);
}

test "comment produces no output" {
    const T = template("before{{! this is a comment }}after");
    const result = try T.render(std.testing.allocator, .{});
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("beforeafter", result);
}

test "conditional true branch" {
    const T = template("{{#if show}}visible{{/if}}");
    const result = try T.render(std.testing.allocator, .{ .show = true });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("visible", result);
}

test "conditional false branch" {
    const T = template("{{#if show}}visible{{/if}}");
    const result = try T.render(std.testing.allocator, .{ .show = false });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "conditional with else" {
    const T = template("{{#if logged_in}}welcome{{else}}login{{/if}}");
    const result_t = try T.render(std.testing.allocator, .{ .logged_in = true });
    defer std.testing.allocator.free(result_t);
    try std.testing.expectEqualStrings("welcome", result_t);

    const result_f = try T.render(std.testing.allocator, .{ .logged_in = false });
    defer std.testing.allocator.free(result_f);
    try std.testing.expectEqualStrings("login", result_f);
}

test "loop iteration" {
    const Item = struct { name: []const u8 };
    const items = [_]Item{
        .{ .name = "Alice" },
        .{ .name = "Bob" },
    };
    const T = template("{{#each items}}{{name}} {{/each}}");
    const result = try T.render(std.testing.allocator, .{ .items = @as([]const Item, &items) });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Alice Bob ", result);
}

test "dot notation" {
    const T = template("{{user.name}}");
    const result = try T.render(std.testing.allocator, .{ .user = .{ .name = "Alice" } });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Alice", result);
}

test "optional truthiness" {
    const T = template("{{#if maybe}}yes{{else}}no{{/if}}");
    const result_some = try T.render(std.testing.allocator, .{ .maybe = @as(?[]const u8, "hi") });
    defer std.testing.allocator.free(result_some);
    try std.testing.expectEqualStrings("yes", result_some);

    const result_null = try T.render(std.testing.allocator, .{ .maybe = @as(?[]const u8, null) });
    defer std.testing.allocator.free(result_null);
    try std.testing.expectEqualStrings("no", result_null);
}

test "slice truthiness" {
    const Item = struct { x: []const u8 };
    const empty: []const Item = &.{};
    const T = template("{{#if items}}has items{{else}}empty{{/if}}");

    const result_empty = try T.render(std.testing.allocator, .{ .items = empty });
    defer std.testing.allocator.free(result_empty);
    try std.testing.expectEqualStrings("empty", result_empty);

    const items = [_]Item{.{ .x = "a" }};
    const result_full = try T.render(std.testing.allocator, .{ .items = @as([]const Item, &items) });
    defer std.testing.allocator.free(result_full);
    try std.testing.expectEqualStrings("has items", result_full);
}

test "full template" {
    const Route = struct { href: []const u8, label: []const u8 };
    const routes = [_]Route{
        .{ .href = "/about", .label = "About" },
        .{ .href = "/api", .label = "API" },
    };
    const T = template(
        \\<h1>{{title}}</h1>
        \\<p>Hello, {{name}}!</p>
        \\{{#if show_routes}}<ul>
        \\{{#each routes}}<li><a href="{{href}}">{{label}}</a></li>
        \\{{/each}}</ul>{{/if}}
    );
    const result = try T.render(std.testing.allocator, .{
        .title = "Test",
        .name = "World",
        .show_routes = true,
        .routes = @as([]const Route, &routes),
    });
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "<h1>Test</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Hello, World!") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "/about") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "API") != null);
}

test "with block basic usage" {
    const T = template("{{#with user}}{{name}} — {{email}}{{/with}}");
    const result = try T.render(std.testing.allocator, .{
        .user = .{ .name = "Alice", .email = "alice@example.com" },
    });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Alice — alice@example.com", result);
}

test "with block dot path" {
    const T = template("{{#with profile.address}}{{city}}{{/with}}");
    const result = try T.render(std.testing.allocator, .{
        .profile = .{ .address = .{ .city = "Portland" } },
    });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Portland", result);
}

test "raw block passthrough" {
    const T = template("before{{{{raw}}}}This {{will not}} be processed: {{{nor this}}}{{{{/raw}}}}after");
    const result = try T.render(std.testing.allocator, .{});
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("beforeThis {{will not}} be processed: {{{nor this}}}after", result);
}

test "yield renders empty when no yield_content" {
    const T = template("before{{{yield}}}after");
    const result = try T.render(std.testing.allocator, .{});
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("beforeafter", result);
}

test "renderWithYield injects content" {
    const T = template("<main>{{{yield}}}</main>");
    const result = try T.renderWithYield(std.testing.allocator, .{}, "<p>Hello</p>");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<main><p>Hello</p></main>", result);
}

test "templateWithPartials inlines partials" {
    const T = templateWithPartials("{{> header}}<main>{{content}}</main>{{> footer}}", .{
        .header = "<header>Nav</header>",
        .footer = "<footer>End</footer>",
    });
    const result = try T.render(std.testing.allocator, .{ .content = "Hello" });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<header>Nav</header><main>Hello</main><footer>End</footer>", result);
}

test "layout and content two-step rendering" {
    const Layout = template("<html><body>{{{yield}}}</body></html>");
    const Content = template("<h1>{{title}}</h1>");

    // Render content first
    const content = try Content.render(std.testing.allocator, .{ .title = "Home" });
    defer std.testing.allocator.free(content);

    // Render layout with content injected
    const result = try Layout.renderWithYield(std.testing.allocator, .{}, content);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<html><body><h1>Home</h1></body></html>", result);
}

test "named yield renders content" {
    const T = template("<head>{{{yield_head}}}</head><body>{{{yield}}}</body>");
    const result = try T.renderWithYieldAndNamed(
        std.testing.allocator,
        .{},
        "<p>Main</p>",
        .{ .head = "<link rel=\"stylesheet\">" },
    );
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<head><link rel=\"stylesheet\"></head><body><p>Main</p></body>", result);
}

test "named yield missing name produces empty output" {
    const T = template("<head>{{{yield_head}}}</head><body>{{{yield}}}</body>");
    // No .head field provided — should produce empty for that slot
    const result = try T.renderWithYieldAndNamed(
        std.testing.allocator,
        .{},
        "<p>Main</p>",
        .{},
    );
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<head></head><body><p>Main</p></body>", result);
}

test "renderWithNamedYields combines main and named" {
    const T = template("<head>{{{yield_head}}}</head><body>{{{yield}}}</body><script>{{{yield_scripts}}}</script>");
    const result = try T.renderWithNamedYields(
        std.testing.allocator,
        .{},
        .{
            .content = "<p>Body</p>",
            .head = "<title>Test</title>",
            .scripts = "app.init();",
        },
    );
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<head><title>Test</title></head><body><p>Body</p></body><script>app.init();</script>", result);
}

test "partial with literal arguments" {
    const T = templateWithPartials(
        "before{{> button type=\"primary\" label=\"Click Me\"}}after",
        .{ .button = "<button class=\"{{type}}\">{{label}}</button>" },
    );
    const result = try T.render(std.testing.allocator, .{});
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("before<button class=\"primary\">Click Me</button>after", result);
}

test "partial with arguments preserves other variables" {
    const T = templateWithPartials(
        "{{> greeting name=\"World\"}}",
        .{ .greeting = "<p>Hello, {{name}}! Today is {{day}}.</p>" },
    );
    // {{name}} is substituted by the partial arg, {{day}} remains a template variable
    const result = try T.render(std.testing.allocator, .{ .day = "Monday" });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<p>Hello, World! Today is Monday.</p>", result);
}

test "backward compatibility: existing render still works" {
    // Ensure all the old render/renderWithYield still work unchanged
    const T = template("Hello {{name}}!");
    const result = try T.render(std.testing.allocator, .{ .name = "World" });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Hello World!", result);

    const Layout = template("<div>{{{yield}}}</div>");
    const result2 = try Layout.renderWithYield(std.testing.allocator, .{}, "inner");
    defer std.testing.allocator.free(result2);
    try std.testing.expectEqualStrings("<div>inner</div>", result2);
}

test "pipe: truncate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const T = template("{{title | truncate:5}}");
    const result = try T.render(alloc, .{ .title = "Hello World" });
    try std.testing.expectEqualStrings("Hello...", result);
}

test "pipe: truncate no-op when short enough" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const T = template("{{title | truncate:20}}");
    const result = try T.render(alloc, .{ .title = "Hello" });
    try std.testing.expectEqualStrings("Hello", result);
}

test "pipe: upper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const T = template("{{name | upper}}");
    const result = try T.render(alloc, .{ .name = "hello" });
    try std.testing.expectEqualStrings("HELLO", result);
}

test "pipe: lower" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const T = template("{{name | lower}}");
    const result = try T.render(alloc, .{ .name = "HELLO" });
    try std.testing.expectEqualStrings("hello", result);
}

test "pipe: default on empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const T = template("{{name | default:\"N/A\"}}");
    const result = try T.render(alloc, .{ .name = "" });
    try std.testing.expectEqualStrings("N/A", result);
}

test "pipe: default on non-empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const T = template("{{name | default:\"N/A\"}}");
    const result = try T.render(alloc, .{ .name = "Alice" });
    try std.testing.expectEqualStrings("Alice", result);
}

test "pipe: chaining upper then truncate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const T = template("{{val | upper | truncate:3}}");
    const result = try T.render(alloc, .{ .val = "hello" });
    try std.testing.expectEqualStrings("HEL...", result);
}

test "integer rendering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const T = template("Count: {{count}}");
    const result = try T.render(alloc, .{ .count = @as(u32, 42) });
    try std.testing.expectEqualStrings("Count: 42", result);
}

test "integer rendering with raw variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const T = template("Count: {{{count}}}");
    const result = try T.render(alloc, .{ .count = @as(i32, -7) });
    try std.testing.expectEqualStrings("Count: -7", result);
}

test "pipe: pluralize singular" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const T = template("{{count | pluralize:\"item\":\"items\"}}");
    const result = try T.render(alloc, .{ .count = "1" });
    try std.testing.expectEqualStrings("1 item", result);
}

test "pipe: pluralize plural" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const T = template("{{count | pluralize:\"item\":\"items\"}}");
    const result = try T.render(alloc, .{ .count = "3" });
    try std.testing.expectEqualStrings("3 items", result);
}

test "pipe: pluralize with integer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const T = template("{{count | pluralize:\"item\":\"items\"}}");
    const result = try T.render(alloc, .{ .count = @as(u32, 1) });
    try std.testing.expectEqualStrings("1 item", result);
}

test "pipe: raw variable with pipe" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const T = template("{{{name | upper}}}");
    const result = try T.render(alloc, .{ .name = "hello" });
    try std.testing.expectEqualStrings("HELLO", result);
}

test "pipe: HTML escaping with escaped variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const T = template("{{name | upper}}");
    const result = try T.render(alloc, .{ .name = "<b>" });
    try std.testing.expectEqualStrings("&lt;B&gt;", result);
}

test "pipe: format_date YYYY-MM-DD" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // 2023-11-14T12:00:00 UTC = 1699963200
    const T = template("{{created_at | format_date:\"YYYY-MM-DD\"}}");
    const result = try T.render(alloc, .{ .created_at = "1699963200" });
    try std.testing.expectEqualStrings("2023-11-14", result);
}

test "pipe: format_date YYYY-MM-DD HH:mm:ss" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const T = template("{{created_at | format_date:\"YYYY-MM-DD HH:mm:ss\"}}");
    const result = try T.render(alloc, .{ .created_at = "1699963200" });
    try std.testing.expectEqualStrings("2023-11-14 12:00:00", result);
}

test "pipe: format_date MMM DD, YYYY" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const T = template("{{created_at | format_date:\"MMM DD, YYYY\"}}");
    const result = try T.render(alloc, .{ .created_at = "1699963200" });
    try std.testing.expectEqualStrings("Nov 14, 2023", result);
}

test "pipe: format_date with integer input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Integer is coerced to string by renderValue, then format_date parses it
    const T = template("{{created_at | format_date:\"YYYY-MM-DD\"}}");
    const result = try T.render(alloc, .{ .created_at = @as(i64, 1699963200) });
    try std.testing.expectEqualStrings("2023-11-14", result);
}

test "pipe: format_date non-numeric passthrough" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const T = template("{{val | format_date:\"YYYY-MM-DD\"}}");
    const result = try T.render(alloc, .{ .val = "not-a-number" });
    try std.testing.expectEqualStrings("not-a-number", result);
}
