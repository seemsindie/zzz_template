# pidgn_template

Compile-time template engine for the pidgn web framework.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.16.0-orange.svg)](https://ziglang.org/)

A Mustache-like template engine that parses templates entirely at comptime. Templates are compiled into a sequence of segments with zero runtime parsing overhead. Supports variables, conditionals, loops, partials, layouts, pipes, and automatic HTML escaping.

## Features

- **Comptime compilation** -- templates are parsed at compile time into typed segments
- **Variables** -- `{{name}}` with automatic HTML escaping, `{{{name}}}` for raw output
- **Dot notation** -- `{{user.name}}` for nested field access
- **Conditionals** -- `{{#if cond}}...{{else}}...{{/if}}`
- **Loops** -- `{{#each items}}...{{/each}}` with access to loop items
- **With blocks** -- `{{#with binding}}...{{/with}}` for scoped context
- **Partials** -- embed reusable template fragments
- **Layouts** -- `{{{yield}}}` and named yields (`{{{yield_head}}}`) for layout inheritance
- **Pipes** -- `{{value | upcase}}`, `{{value | truncate:20}}`, `{{count | pluralize:item:items}}`
- **Comments** -- `{{! this is a comment }}`
- **Raw blocks** -- emit literal template syntax without processing
- **HTML escaping** -- all `{{variables}}` are HTML-escaped by default to prevent XSS

## Quick Start

```zig
const pidgn = @import("pidgn");

// Compile template at comptime
const Template = pidgn.template(
    \\<h1>Hello, {{name}}!</h1>
    \\{{#if show_email}}
    \\  <p>Email: {{email}}</p>
    \\{{/if}}
    \\{{#each posts}}
    \\  <article>{{title}}</article>
    \\{{/each}}
);

// Render at runtime
fn handler(ctx: *pidgn.Context) !void {
    try ctx.render(Template, .ok, .{
        .name = "Alice",
        .show_email = true,
        .email = "alice@example.com",
        .posts = &.{
            .{ .title = "First Post" },
            .{ .title = "Second Post" },
        },
    });
}
```

### Layouts

```zig
const Layout = pidgn.template(
    \\<html>
    \\<head>{{{yield_head}}}</head>
    \\<body>
    \\  <nav>...</nav>
    \\  {{{yield}}}
    \\</body>
    \\</html>
);

const Page = pidgn.template(
    \\<h1>{{title}}</h1>
    \\<p>{{body}}</p>
);

fn handler(ctx: *pidgn.Context) !void {
    try ctx.renderWithLayout(Layout, Page, .ok, .{
        .title = "My Page",
        .body = "Page content here.",
    });
}
```

### Pipes

```zig
// Single pipe
{{name | upcase}}

// Pipe with argument
{{description | truncate:100}}

// Pipe with two arguments
{{count | pluralize:item:items}}

// Chained pipes
{{name | downcase | truncate:20}}
```

### HTML Escaping

Double-brace variables are automatically HTML-escaped:

```
{{user_input}}     <!-- escaped: &lt;script&gt; becomes visible text -->
{{{raw_html}}}     <!-- raw: HTML rendered as-is (use with trusted content only) -->
```

## Template Syntax Reference

| Syntax | Description |
|--------|-------------|
| `{{var}}` | HTML-escaped variable |
| `{{{var}}}` | Raw (unescaped) variable |
| `{{obj.field}}` | Dot notation for nested access |
| `{{#if cond}}...{{/if}}` | Conditional block |
| `{{#if cond}}...{{else}}...{{/if}}` | Conditional with else |
| `{{#each items}}...{{/each}}` | Loop over collection |
| `{{#with binding}}...{{/with}}` | Scoped context block |
| `{{! comment }}` | Comment (not rendered) |
| `{{{yield}}}` | Default layout yield point |
| `{{{yield_name}}}` | Named layout yield point |
| `{{var \| pipe}}` | Pipe transformation |
| `{{var \| pipe:arg}}` | Pipe with argument |

## Building

```bash
zig build        # Build
zig build test   # Run tests
```

## Documentation

Full documentation available at [docs.pidgn.dev](https://docs.pidgn.dev) under the Templates section.

## Ecosystem

| Package | Description |
|---------|-------------|
| [pidgn.zig](https://github.com/seemsindie/pidgn) | Core web framework |
| [pidgn_db](https://github.com/seemsindie/pidgn_db) | Database ORM (SQLite + PostgreSQL) |
| [pidgn_jobs](https://github.com/seemsindie/pidgn_jobs) | Background job processing |
| [pidgn_mailer](https://github.com/seemsindie/pidgn_mailer) | Email sending |
| [pidgn_template](https://github.com/seemsindie/pidgn_template) | Template engine |
| [pidgn_cli](https://github.com/seemsindie/pidgn_cli) | CLI tooling |

## Requirements

- Zig 0.16.0-dev.2535+b5bd49460 or later

## License

MIT License -- Copyright (c) 2026 Ivan Stamenkovic
