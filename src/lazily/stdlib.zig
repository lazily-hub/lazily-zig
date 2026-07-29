const std = @import("std");
const ParkingMutex = @import("parking_mutex.zig").ParkingMutex;

pub const TimerError = error{ DeadlineOverflow, ClockRegression };

pub fn checkedDeadline(now: u64, duration: u64) TimerError!u64 {
    return std.math.add(u64, now, duration) catch error.DeadlineOverflow;
}

pub const TimerOutcome = enum { pending, fired };

pub const TimerObservation = struct {
    outcome: TimerOutcome,
    deadline: ?u64 = null,
    fired_at: ?u64 = null,
};

pub const Timer = struct {
    mutex: ParkingMutex = .{},
    deadline: u64,
    last_now: u64,
    fired_at: ?u64 = null,

    pub fn start(now: u64, duration: u64) TimerError!Timer {
        return .{ .deadline = try checkedDeadline(now, duration), .last_now = now };
    }

    pub fn observe(self: *Timer, now: u64) TimerError!TimerObservation {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.fired_at) |fired_at| {
            return .{ .outcome = .fired, .fired_at = fired_at };
        }
        if (now < self.last_now) return error.ClockRegression;
        self.last_now = now;
        if (now >= self.deadline) {
            self.fired_at = now;
            return .{ .outcome = .fired, .fired_at = now };
        }
        return .{ .outcome = .pending, .deadline = self.deadline };
    }
};

pub const OperationState = enum { pending, completed, unavailable };

pub const Operation = struct {
    state: OperationState,
    value: ?[]const u8 = null,
};

pub const Cancellation = enum { pending, cancelled, unavailable };

pub const OperationAdapter = struct {
    context: *anyopaque,
    run_fn: *const fn (*anyopaque) Operation,

    pub fn run(self: OperationAdapter) Operation {
        return self.run_fn(self.context);
    }
};

pub const CancellationAdapter = struct {
    context: *anyopaque,
    run_fn: *const fn (*anyopaque) Cancellation,

    pub fn run(self: CancellationAdapter) Cancellation {
        return self.run_fn(self.context);
    }
};

pub const TimeoutOutcome = enum { pending, completed, timed_out, cancelled, unavailable };

pub const TimeoutObservation = struct {
    outcome: TimeoutOutcome,
    deadline: ?u64 = null,
    value: ?[]const u8 = null,
    reason: ?[]const u8 = null,
};

pub const Timeout = struct {
    mutex: ParkingMutex = .{},
    deadline: u64,
    last_now: u64,
    terminal: ?TimeoutObservation = null,

    pub fn start(now: u64, duration: u64) TimerError!Timeout {
        return .{ .deadline = try checkedDeadline(now, duration), .last_now = now };
    }

    pub fn poll(
        self: *Timeout,
        now: u64,
        operation_adapter: OperationAdapter,
        cancellation_adapter: CancellationAdapter,
    ) TimeoutObservation {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.terminal) |terminal| return terminal;
        if (now < self.last_now) {
            return self.latch(.{ .outcome = .unavailable, .reason = "clock_regression" });
        }
        self.last_now = now;
        if (now >= self.deadline) return self.latch(.{ .outcome = .timed_out });

        const operation = operation_adapter.run();
        const cancellation = cancellation_adapter.run();
        switch (operation.state) {
            .completed => return self.latch(.{
                .outcome = .completed,
                .value = operation.value orelse "",
            }),
            .unavailable => return self.latch(.{
                .outcome = .unavailable,
                .reason = "operation_unavailable",
            }),
            .pending => {},
        }
        return switch (cancellation) {
            .cancelled => self.latch(.{ .outcome = .cancelled }),
            .unavailable => self.latch(.{
                .outcome = .unavailable,
                .reason = "cancellation_unavailable",
            }),
            .pending => .{ .outcome = .pending, .deadline = self.deadline },
        };
    }

    fn latch(self: *Timeout, observation: TimeoutObservation) TimeoutObservation {
        self.terminal = observation;
        return observation;
    }
};

pub const BarrierOutcome = enum { pending, satisfied, timed_out, cancelled, disposed, unavailable };

pub const BarrierObservation = struct {
    outcome: BarrierOutcome,
    reason: ?[]const u8 = null,
    revision: u64,
    generation: u64,
};

pub const RevisionBarrier = struct {
    mutex: ParkingMutex = .{},
    revision: u64,
    required_revision: u64,
    generation: u64 = 0,
    deadline: ?u64,
    last_now: ?u64 = null,
    terminal: ?BarrierOutcome = null,
    terminal_reason: ?[]const u8 = null,

    pub fn init(revision: u64, required_revision: u64, deadline: ?u64) RevisionBarrier {
        return .{
            .revision = revision,
            .required_revision = required_revision,
            .deadline = deadline,
        };
    }

    pub fn observe(
        self: *RevisionBarrier,
        now: u64,
        predicate: bool,
        cancellation_adapter: CancellationAdapter,
    ) BarrierObservation {
        self.mutex.lock();
        if (self.terminal != null) {
            const observation = self.snapshot();
            self.mutex.unlock();
            return observation;
        }
        if (!self.acceptNow(now)) {
            const observation = self.latch(.unavailable, "clock_regression");
            self.mutex.unlock();
            return observation;
        }
        if (self.deadline) |deadline| {
            if (now >= deadline) {
                const observation = self.latch(.timed_out, null);
                self.mutex.unlock();
                return observation;
            }
        }
        if (predicate and self.revision >= self.required_revision) {
            const observation = self.latch(.satisfied, null);
            self.mutex.unlock();
            return observation;
        }
        self.mutex.unlock();

        const cancellation = cancellation_adapter.run();
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.terminal != null) return self.snapshot();
        return switch (cancellation) {
            .cancelled => self.latch(.cancelled, null),
            .unavailable => self.latch(.unavailable, "cancellation_unavailable"),
            .pending => self.snapshot(),
        };
    }

    pub fn registerRecheck(
        self: *RevisionBarrier,
        now: u64,
        observed_revision: u64,
        predicate: bool,
    ) BarrierObservation {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.terminal != null) return self.snapshot();
        if (!self.acceptNow(now)) {
            return self.latch(.unavailable, "clock_regression");
        }
        if (self.deadline) |deadline| {
            if (now >= deadline) return self.latch(.timed_out, null);
        }
        self.acceptRevision(observed_revision);
        if (predicate and self.revision >= self.required_revision) {
            return self.latch(.satisfied, null);
        }
        return self.snapshot();
    }

    pub fn advance(self: *RevisionBarrier, revision: u64, predicate: bool) BarrierObservation {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.terminal != null) return self.snapshot();
        self.acceptRevision(revision);
        if (predicate and self.revision >= self.required_revision) {
            return self.latch(.satisfied, null);
        }
        return self.snapshot();
    }

    pub fn dispose(self: *RevisionBarrier) BarrierObservation {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.terminal == null) return self.latch(.disposed, null);
        return self.snapshot();
    }

    pub fn receipt(self: *RevisionBarrier, _: []const u8) BarrierObservation {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.snapshot();
    }

    fn acceptRevision(self: *RevisionBarrier, revision: u64) void {
        if (revision > self.revision) {
            self.revision = revision;
            self.generation += 1;
        }
    }

    fn acceptNow(self: *RevisionBarrier, now: u64) bool {
        if (self.last_now) |last_now| {
            if (now < last_now) return false;
        }
        self.last_now = now;
        return true;
    }

    fn latch(
        self: *RevisionBarrier,
        outcome: BarrierOutcome,
        reason: ?[]const u8,
    ) BarrierObservation {
        self.terminal = outcome;
        self.terminal_reason = reason;
        return self.snapshot();
    }

    fn snapshot(self: *RevisionBarrier) BarrierObservation {
        return .{
            .outcome = self.terminal orelse .pending,
            .reason = self.terminal_reason,
            .revision = self.revision,
            .generation = self.generation,
        };
    }
};
