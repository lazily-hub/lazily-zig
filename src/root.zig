//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
pub const cell = @import("./lazily/cell.zig").cell;
pub const CellFn = @import("./lazily/cell.zig").CellFn;
pub const Cell = @import("./lazily/cell.zig").Cell;
pub const initCellFn = @import("./lazily/cell.zig").initCellFn;
pub const Context = @import("./lazily/context.zig").Context;
pub const ipc = @import("./lazily/ipc.zig");
pub const CapabilityHandshake = ipc.CapabilityHandshake;
pub const Codec = ipc.Codec;
pub const Delta = ipc.Delta;
pub const DeltaApplyStatus = ipc.DeltaApplyStatus;
pub const DeltaOp = ipc.DeltaOp;
pub const EdgeSnapshot = ipc.EdgeSnapshot;
pub const IpcMessage = ipc.IpcMessage;
pub const IpcValue = ipc.IpcValue;
pub const NodeId = ipc.NodeId;
pub const NodeSnapshot = ipc.NodeSnapshot;
pub const NodeState = ipc.NodeState;
pub const PeerId = ipc.PeerId;
pub const ShmBlobRef = ipc.ShmBlobRef;
pub const Snapshot = ipc.Snapshot;
pub const Owned = @import("./lazily/context.zig").Owned;
pub const OwnedString = @import("./lazily/context.zig").OwnedString;
pub const Slot = @import("./lazily/context.zig").Slot;
pub const String = @import("./lazily/context.zig").String;
pub const valueFnCacheKey = @import("./lazily/context.zig").valueFnCacheKey;
pub const ValueFn = @import("./lazily/context.zig").ValueFn;
pub const deinitSlotValue = @import("./lazily/slot.zig").deinitSlotValue;
pub const slot = @import("./lazily/slot.zig").slot;
pub const slotKeyed = @import("./lazily/slot.zig").slotKeyed;
pub const initSlotFn = @import("./lazily/slot.zig").initSlotFn;
pub const StringView = @import("./lazily/slot.zig").StringView;
pub const slotEventLog = @import("./lazily/test.zig").slotEventLog;
pub const expectEventLog = @import("./lazily/test.zig").expectEventLog;

test {
    std.testing.refAllDecls(@This());
}
