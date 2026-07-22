const std = @import("std");
const lazily = @import("lazily");

const Context = lazily.Context;
const Compute = lazily.Compute;
const deinitSlotValue = lazily.deinitSlotValue;
const expectEventLog = lazily.expectEventLog;
const initCellFn = lazily.initCellFn;
const initSlotFn = lazily.initSlotFn;
const OwnedString = lazily.OwnedString;
const slotEventLog = lazily.slotEventLog;
const String = lazily.String;

fn getHello(ctx: *Context) !String {
    try (try slotEventLog(ctx)).append("hello|");
    return "Hello";
}
pub const hello = initCellFn(
    String,
    getHello,
    null,
);

fn getName(ctx: *Context) !String {
    try (try slotEventLog(ctx)).append("name|");
    return "World";
}
pub const name = initCellFn(
    String,
    getName,
    null,
);

fn getGreeting(c: *Compute) !OwnedString {
    const ctx = c.untracked();
    try (try slotEventLog(ctx)).append("greeting|");
    return OwnedString.managed(std.fmt.allocPrint(
        ctx.allocator,
        "{s} {s}!",
        .{ c.get(try hello(ctx)), c.get(try name(ctx)) },
    ) catch unreachable);
}
pub const greeting = initSlotFn(
    OwnedString,
    getGreeting,
    deinitSlotValue(OwnedString, null),
);

fn getResponse(_ctx: *Context) !String {
    try (try slotEventLog(_ctx)).append("response|");
    return "How are you?";
}
pub const response = initCellFn(
    String,
    getResponse,
    null,
);

fn getGreetingAndResponse(c: *Compute) !OwnedString {
    const _ctx = c.untracked();
    try (try slotEventLog(_ctx)).append("greetingAndResponse|");
    const g = (try greeting(_ctx)).value;
    if (_ctx.getSlot(getGreeting)) |s| c.trackSlot(s);
    return OwnedString.managed(
        std.fmt.allocPrint(
            _ctx.allocator,
            "{s} {s}",
            .{ g, c.get(try response(_ctx)) },
        ) catch unreachable,
    );
}
pub const greetingAndResponse = initSlotFn(
    OwnedString,
    getGreetingAndResponse,
    deinitSlotValue(OwnedString, null),
);

test "examples/cells: initCellFn and initSlotFn with dependencies example" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    try std.testing.expectEqual(0, (try slotEventLog(ctx)).items.len);

    try std.testing.expectEqualStrings(
        "Hello World!",
        (try greeting(ctx)).value,
    );
    try std.testing.expectEqual(null, ctx.getSlot(getGreetingAndResponse));

    try expectEventLog(ctx, "greeting|hello|name|");
    try std.testing.expectEqualStrings(
        "Hello World! How are you?",
        (try greetingAndResponse(ctx)).value,
    );

    try expectEventLog(ctx, "greeting|hello|name|greetingAndResponse|response|");
    try std.testing.expectEqualStrings(
        "Hello World! How are you?",
        (try greetingAndResponse(ctx)).value,
    );

    (try name(ctx)).set("You");

    try expectEventLog(ctx, "greeting|hello|name|greetingAndResponse|response|");
    try std.testing.expectEqualStrings("You", (try name(ctx)).get());
    try expectEventLog(ctx, "greeting|hello|name|greetingAndResponse|response|");

    try std.testing.expectEqualStrings("Hello You!", (try greeting(ctx)).value);

    try std.testing.expectEqualStrings(
        "Hello You! How are you?",
        (try greetingAndResponse(ctx)).value,
    );
    try expectEventLog(ctx, "greeting|hello|name|greetingAndResponse|response|greeting|greetingAndResponse|");
}
