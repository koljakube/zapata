const std = @import("std");
const assert = std.debug.assert;

const wren = @import("./wren.zig");
const Vm = @import("./vm.zig").Vm;
const Configuration = @import("./vm.zig").Configuration;
const ErrorType = @import("./vm.zig").ErrorType;
const WrenError = @import("./error.zig").WrenError;

const call = @import("./call.zig");
const Receiver = call.Receiver;
const CallHandle = call.CallHandle;
const Method = call.Method;

const EmptyUserData = struct {};

const testing = std.testing;

/// Handle for freestanding functions (function objects saved in variables).
pub fn FunctionHandle(comptime module: []const u8, comptime function: []const u8, comptime Ret: anytype, comptime Args: anytype) type {
    return struct {
        const Self = @This();

        const Function = Method(Ret, Args);

        method: Function,

        pub fn init(vm: *Vm) Self {
            const slot_index = 0;

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

            const receiver = Receiver.init(vm, module, function);
            const call_handle = CallHandle.init(vm, buffer[0..]);
            const method = Function.init(receiver, call_handle);
            return Self{ .method = method };
        }

        pub fn deinit(self: Self) void {
            self.method.call_handle.deinit();
            self.method.receiver.deinit();
        }

        pub fn call(self: Self, args: anytype) !Ret {
            return self.method.call(args);
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
        \\var addTwo = Fn.new { |n|
        \\  return n + 2
        \\}
    );

    const signature = FunctionHandle("test", "addTwo", i32, .{i32});
    const funcHandle = signature.init(&vm);
    defer funcHandle.deinit();
    const res = try funcHandle.call(.{5});
    testing.expectEqual(@as(i32, 7), res);
}

test "many parameters" {
    var config = Configuration{};
    config.errorFn = printError;
    config.writeFn = print;
    var vm: Vm = undefined;
    try config.newVmInPlace(EmptyUserData, &vm, null);

    try vm.interpret("test",
        \\var sum3 = Fn.new { |a, b, c|
        \\  return a + b + c
        \\}
    );

    const signature = FunctionHandle("test", "sum3", f64, .{ i32, u32, f32 });
    const funcHandle = signature.init(&vm);
    defer funcHandle.deinit();
    const res = try funcHandle.call(.{ -3, 3, 23.5 });
    testing.expectEqual(@as(f64, 23.5), res);
}

test "string parameters" {
    var config = Configuration{};
    config.errorFn = printError;
    config.writeFn = print;
    var vm: Vm = undefined;
    try config.newVmInPlace(EmptyUserData, &vm, null);

    try vm.interpret("test",
        \\var concat = Fn.new { |s1, s2|
        \\  return s1 + s2
        \\}
    );

    const signature = FunctionHandle("test", "concat", []const u8, .{ []const u8, []const u8 });
    const funcHandle = signature.init(&vm);
    defer funcHandle.deinit();
    const res = try funcHandle.call(.{ "kum", "quat" });
    testing.expectEqualStrings("kumquat", res);
}
