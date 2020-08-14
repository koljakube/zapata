const std = @import("std");

const wren = @import("./wren.zig");
const Vm = @import("./vm.zig").Vm;
const Configuration = @import("./vm.zig").Configuration;

pub fn Handle(comptime T: type) type {
    return struct {
        const Self = @This();

        vm: *Vm,
        handle: *wren.Handle,

        pub fn init(vm: *Vm, handle: *wren.Handle) Self {
            return Self{ .vm = vm, .handle = handle };
        }

        pub fn get(self: *Self, slot_index: u32) T {
            comptime const ti = @typeInfo(T);
            return switch (ti) {
                .Int => {
                    self.vm.setSlotHandle(T, slot_index, self);
                    return self.vm.getSlotNumber(T, slot_index);
                },
                else => @compileError("not a valid handle type"),
            };
        }

        pub fn set(self: *Self, slot_index: u32, value: T) void {
            comptime const ti = @typeInfo(T);
            switch (ti) {
                .Int => {
                    self.vm.setSlotHandle(T, slot_index, self);
                    self.vm.setSlot(slot_index, value);
                },
                else => @compileError("not a valid handle type"),
            }
        }
    };
}
// const EmptyUserData = struct {};
//
// const testing = std.testing;
//
// fn print(vm: *Vm, msg: []const u8) void {
//     std.debug.print("{}", .{msg});
// }
//
// test "number handle" {
//     var config = Configuration{};
//     config.writeFn = print;
//     var vm: Vm = undefined;
//     try config.newVmInPlace(EmptyUserData, &vm, null);
//
//     try vm.interpret("test",
//         \\var a = 3
//         \\var b = 0
//         \\System.print("a = %(a), b = %(b)")
//     );
//     vm.ensureSlots(2);
//     vm.getVariable("test", "a", 0);
//     vm.getVariable("test", "b", 1);
//     var ha = vm.createHandle(i32, 0);
//     var hb = vm.createHandle(i32, 1);
//     testing.expectEqual(@as(i32, 3), ha.get(0));
//     testing.expectEqual(@as(i32, 0), hb.get(1));
//
//     hb.set(1, 5);
//     testing.expectEqual(@as(i32, 5), hb.get(1));
//     try vm.interpret("test",
//         \\System.print("a = %(a), b = %(b)")
//         \\b = 5
//         \\a = a * b
//         \\System.print("a = %(a), b = %(b)")
//     );
//     vm.ensureSlots(2);
//     testing.expectEqual(@as(i32, 15), ha.get(0));
//     testing.expectEqual(@as(i32, 5), hb.get(1));
// }
