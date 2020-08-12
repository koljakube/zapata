const std = @import("std");
const assert = std.debug.assert;

const wren = @import("./wren.zig");
const Vm = @import("./vm.zig").Vm;
const Configuration = @import("./vm.zig").Configuration;
const ErrorType = @import("./vm.zig").ErrorType;
const WrenError = @import("./error.zig").WrenError;

const EmptyUserData = struct {};

const testing = std.testing;

/// Handle for freestanding functions (function objects saved in variables).
pub fn FunctionHandle(comptime module: []const u8, comptime function: []const u8, comptime Ret: anytype, comptime Args: anytype) type {
    if (@typeInfo(@TypeOf(Args)) != .Struct) {
        @compileError("call arguments must be passed as a tuple");
    }
    return struct {
        const Self = @This();

        vm: *Vm,
        functionHandle: *wren.Handle,
        callHandle: *wren.Handle,

        pub fn init(vm: *Vm) Self {
            const slot_index = 0;
            vm.ensureSlots(1);

            const fun = "call";
            // Tradeoff: maximum signature length or dynamic allocation. I chose the former.
            var buffer: [64]u8 = undefined;
            assert(fun.len + 2 + 2 * Args.len - 1 < buffer.len);
            std.mem.copy(u8, buffer[0..], fun);

            // TODO: Don't eff this up. Write a patch for wren to detect '\0's in signatures.
            var index: u16 = fun.len;
            buffer[index] = '(';
            index += 1;
            // index += 1;
            inline for (Args) |a| {
                buffer[index] = '_';
                buffer[index + 1] = ',';
                index += 2;
            }
            buffer[index - 1] = ')';
            buffer[index] = 0;

            vm.getVariable(module, "Fn", slot_index);
            const callHandle = wren.makeCallHandle(vm.vm, @ptrCast([*c]const u8, &buffer[0]));
            assert(callHandle != null);

            vm.getVariable(module, function, slot_index);
            const functionHandle = wren.getSlotHandle(vm.vm, @intCast(c_int, slot_index));
            assert(functionHandle != null);

            return Self{
                .vm = vm,
                .functionHandle = @ptrCast(*wren.Handle, functionHandle),
                .callHandle = @ptrCast(*wren.Handle, callHandle),
            };
        }

        pub fn deinit(self: Self) void {
            wren.releaseHandle(self.vm.vm, self.functionHandle);
            wren.releaseHandle(self.vm.vm, self.callHandle);
        }

        /// Method call receiver always goes into slot zero!
        pub fn call(self: Self, args: anytype) !Ret {
            assert(args.len == Args.len);
            self.vm.ensureSlots(Args.len + 1);

            self.vm.setSlotHandle(0, self.functionHandle);

            comptime var slot_index: u32 = 1;
            inline for (Args) |Arg| {
                self.vm.setSlot(slot_index, args[slot_index - 1]);
                slot_index += 1;
            }

            const res = wren.call(self.vm.vm, self.callHandle);
            if (res == .WREN_RESULT_COMPILE_ERROR) {
                return WrenError.CompileError;
            }
            if (res == .WREN_RESULT_RUNTIME_ERROR) {
                return WrenError.RuntimeError;
            }

            return switch (@typeInfo(Ret)) {
                .Int => return self.vm.getSlotNumber(Ret, 0),
                else => @compileError("unsupported return type " ++ @typeName(Ret)),
            };
        }
    };
}

fn printError(vm: *Vm, error_type: ErrorType, module: ?[]const u8, line: ?u32, message: []const u8) void {
    std.debug.print("error_type={}, module={}, line={}, message={}\n", .{ error_type, module, line, message });
}

fn print(vm: *Vm, msg: []const u8) void {
    std.debug.print("{}", .{msg});
}

test "function handle" {
    var config = Configuration{};
    config.errorFn = printError;
    config.writeFn = print;
    var vm: Vm = undefined;
    try config.newVmInPlace(EmptyUserData, &vm, null);

    try vm.interpret("test",
        \\ var addTwo = Fn.new { |n|
        \\   return n + 2
        \\ }
    );

    const signature = FunctionHandle("test", "addTwo", i32, .{i32});
    const funcHandle = signature.init(&vm);
    defer funcHandle.deinit();
    const res = try funcHandle.call(.{5});
    testing.expectEqual(@as(i32, 7), res);
}
