//! Focused facade for Lazily's synchronous reactive Core.
//!
//! The package exposes this file as the `lazily_core` module and the existing
//! `lazily` root module exposes it as `.core`. All declarations alias the same
//! implementation modules used by the root import, preserving type identity.

const std = @import("std");

pub const Source = @import("lazily/cell.zig").Source;
pub const Computed = @import("lazily/cell.zig").Computed;
pub const source = @import("lazily/cell.zig").source;
pub const computed = @import("lazily/cell.zig").computed;
pub const computedRippleWhen = @import("lazily/cell.zig").computedRippleWhen;

pub const Compute = @import("lazily/context.zig").Compute;
pub const Context = @import("lazily/context.zig").Context;
pub const TeardownScope = Context.TeardownScope;

pub const Effect = @import("lazily/effect.zig").Effect;
pub const effect = @import("lazily/effect.zig").effect;

test "core facade exposes the focused public surface" {
    std.testing.refAllDecls(@This());
}
