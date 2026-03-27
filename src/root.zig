//! pidgn_template - Standalone Template Engine from the Pidgn Web Framework
//!
//! A comptime Mustache-like template engine with HTML escaping, conditionals,
//! loops, partials, pipes, and named yield blocks.

const engine = @import("engine.zig");

pub const template = engine.template;
pub const templateWithPartials = engine.templateWithPartials;
pub const parse = engine.parse;
pub const Segment = engine.Segment;
pub const html_escape = @import("html_escape.zig");

test {
    _ = engine;
    _ = html_escape;
}
