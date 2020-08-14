const std = @import("std");
const assert = std.debug.assert;

const wren = @import("./wren.zig");
const Vm = @import("./vm.zig").Vm;
const Configuration = @import("./vm.zig").Configuration;
const ErrorType = @import("./vm.zig").ErrorType;
const WrenError = @import("./error.zig").WrenError;

const EmptyUserData = struct {};

const testing = std.testing;

/// Handle for method call receivers. Pretty much just a fancy wrapper around wrenGetVariable/WrenHandle.
pub const Receiver = struct {
    const Self = @This();

    vm: *Vm,
    module: []const u8,
    handle: *wren.Handle,

    pub fn init(vm: *Vm, module: []const u8, name: []const u8) Self {
        const slot_index = 0;
        vm.ensureSlots(1);
        vm.getVariable(module, name, slot_index);
        const handle = vm.getSlot(*wren.Handle, 0);
        return Self{ .vm = vm, .module = module, .handle = handle };
    }

    pub fn deinit(self: Self) void {
        wren.releaseHandle(self.vm.vm, self.handle);
    }

    pub fn setSlot(self: Self, slot_index: u32) void {
        self.vm.setSlotHandle(0, self.handle);
    }
};

fn printError(vm: *Vm, error_type: ErrorType, module: ?[]const u8, line: ?u32, message: []const u8) void {
    std.debug.print("error_type={}, module={}, line={}, message={}\n", .{ error_type, module, line, message });
}

fn print(vm: *Vm, msg: []const u8) void {
    std.debug.print("{}", .{msg});
}

test "can create receiver" {
    var config = Configuration{};
    config.errorFn = printError;
    config.writeFn = print;
    var vm: Vm = undefined;
    try config.newVmInPlace(EmptyUserData, &vm, null);

    try vm.interpret("test",
        \\class Foo {
        \\}
    );

    _ = vm.makeReceiver("test", "Foo");
}

/// Handle for methods of any kind. Even free-standing functions in wren are just calling `call()` on a function object.
pub const CallHandle = struct {
    const Self = @This();

    vm: *Vm,
    handle: *wren.Handle,

    pub fn init(vm: *Vm, method: []const u8) Self {
        const slot_index = 0;
        vm.ensureSlots(1);

        const handle = wren.makeCallHandle(vm.vm, @ptrCast([*c]const u8, method));
        assert(handle != null);

        return Self{
            .vm = vm,
            .handle = @ptrCast(*wren.Handle, handle),
        };
    }

    pub fn deinit(self: Self) void {
        wren.releaseHandle(self.vm.vm, self.handle);
    }

    pub fn call(self: Self) !void {
        const res = wren.call(self.vm.vm, self.handle);
        if (res == .WREN_RESULT_COMPILE_ERROR) {
            return WrenError.CompileError;
        }
        if (res == .WREN_RESULT_RUNTIME_ERROR) {
            return WrenError.RuntimeError;
        }
    }
};

pub fn Method(comptime Ret: anytype, comptime Args: anytype) type {
    if (@typeInfo(@TypeOf(Args)) != .Struct) {
        @compileError("call argument types must be passed as a tuple");
    }

    return struct {
        const Self = @This();

        receiver: Receiver,
        call_handle: CallHandle,

        pub fn init(receiver: Receiver, call_handle: CallHandle) Self {
            return Self{ .receiver = receiver, .call_handle = call_handle };
        }

        pub fn call(self: Self, args: anytype) !Ret {
            if (@typeInfo(@TypeOf(args)) != .Struct) {
                @compileError("call arguments must be passed as a tuple");
            }
            assert(args.len == Args.len);

            const vm = self.receiver.vm;

            vm.ensureSlots(Args.len + 1);

            self.receiver.setSlot(0);

            comptime var slot_index: u32 = 1;
            inline for (Args) |Arg| {
                vm.setSlot(slot_index, args[slot_index - 1]);
                slot_index += 1;
            }

            try self.call_handle.call();

            if (Ret != void) {
                return vm.getSlot(Ret, 0);
            }
        }
    };
}

test "call a free function" {
    var config = Configuration{};
    config.errorFn = printError;
    config.writeFn = print;
    var vm: Vm = undefined;
    try config.newVmInPlace(EmptyUserData, &vm, null);
    defer vm.deinit();

    try vm.interpret("test",
        \\var add = Fn.new { |a, b|
        \\  return a + b
        \\}
    );

    const receiver = vm.makeReceiver("test", "add");
    defer receiver.deinit();
    const call_handle = vm.makeCallHandle("call(_,_)");
    defer call_handle.deinit();
    const method = Method(i32, .{ i32, i32 }).init(receiver, call_handle);
    testing.expectEqual(@as(i32, 42), try method.call(.{ 23, 19 }));
}

test "call a static method" {
    var config = Configuration{};
    config.errorFn = printError;
    config.writeFn = print;
    var vm: Vm = undefined;
    try config.newVmInPlace(EmptyUserData, &vm, null);
    defer vm.deinit();

    try vm.interpret("test",
        \\class Foo {
        \\  static test() {
        \\    return "hello"
        \\  }
        \\}
    );

    const receiver = vm.makeReceiver("test", "Foo");
    defer receiver.deinit();
    const call_handle = vm.makeCallHandle("test()");
    defer call_handle.deinit();
    const method = Method([]const u8, .{}).init(receiver, call_handle);
    testing.expectEqualStrings("hello", try method.call(.{}));
}

test "call an instance method" {
    var config = Configuration{};
    config.errorFn = printError;
    config.writeFn = print;
    var vm: Vm = undefined;
    try config.newVmInPlace(EmptyUserData, &vm, null);
    defer vm.deinit();

    try vm.interpret("test",
        \\class Multiplier {
        \\  construct new(n) {
        \\    _n = n
        \\  }
        \\  n=(n) {
        \\    _n = n
        \\  }
        \\  *(m) {
        \\    return _n * m
        \\  }
        \\  formatted(m) {
        \\    return "%(_n) * %(m) = %(this * m)"
        \\  }
        \\}
        \\
        \\var mult = Multiplier.new(3)
    );

    const receiver = vm.makeReceiver("test", "mult");
    defer receiver.deinit();

    const op_times_sig = vm.makeCallHandle("*(_)");
    defer op_times_sig.deinit();
    const op_times = Method(i32, .{i32}).init(receiver, op_times_sig);
    testing.expectEqual(@as(i32, 9), try op_times.call(.{3}));

    const setter_sig = vm.makeCallHandle("n=(_)");
    defer setter_sig.deinit();
    const setter = Method(void, .{i32}).init(receiver, setter_sig);
    try setter.call(.{5});

    const formatted_sig = vm.makeCallHandle("formatted(_)");
    defer formatted_sig.deinit();
    const formatted = Method([]const u8, .{f32}).init(receiver, formatted_sig);
    testing.expectEqualStrings("5 * 1.1 = 5.5", try formatted.call(.{1.1}));
}

test "non-comptime identifiers" {
    var config = Configuration{};
    config.errorFn = printError;
    config.writeFn = print;
    var vm: Vm = undefined;
    try config.newVmInPlace(EmptyUserData, &vm, null);
    defer vm.deinit();

    try vm.interpret("test",
        \\class Foo {
        \\  static test() {
        \\    return "hello"
        \\  }
        \\}
    );

    var identifier: [4]u8 = [_]u8{ 'F', 'o', 'o', 0 };
    var id = identifier[0..];
    const receiver = vm.makeReceiver("test", id);
    defer receiver.deinit();

    var signature = "test()";
    var sig = signature[0..];
    const call_handle = vm.makeCallHandle(sig);
    defer call_handle.deinit();
    const method = Method([]const u8, .{}).init(receiver, call_handle);
    testing.expectEqualStrings("hello", try method.call(.{}));
}
