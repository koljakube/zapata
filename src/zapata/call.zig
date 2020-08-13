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
        wren.releaseHandle(self.vm, self.handle);
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
        @compileError("call arguments must be passed as a tuple");
    }

    return struct {
        const Self = @This();

        receiver: Receiver,
        call_handle: CallHandle,

        pub fn init(receiver: Receiver, call_handle: CallHandle) Self {
            return Self{ .receiver = receiver, .call_handle = call_handle };
        }

        pub fn call(self: Self, args: anytype) !Ret {
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

            return vm.getSlot(Ret, 0);
        }
    };
}

test "call a free function" {
    var config = Configuration{};
    config.errorFn = printError;
    config.writeFn = print;
    var vm: Vm = undefined;
    try config.newVmInPlace(EmptyUserData, &vm, null);

    try vm.interpret("test",
        \\var add = Fn.new { |a, b|
        \\  return a + b
        \\}
    );

    const receiver = vm.makeReceiver("test", "add");
    const call_handle = vm.makeCallHandle("call(_,_)");
    const method = Method(i32, .{ i32, i32 }).init(receiver, call_handle);
    testing.expectEqual(@as(i32, 42), try method.call(.{ 23, 19 }));
}
