const std = @import("std");
const assert = std.debug.assert;

const wren = @import("./wren.zig");
const Vm = @import("./vm.zig").Vm;
const ErrorType = @import("./vm.zig").ErrorType;

fn zigVmFromCVm(vm: ?*wren.Vm) *Vm {
    const udptr = wren.getUserData(vm);
    assert(udptr != null);
    return @ptrCast(*Vm, @alignCast(@alignOf(*Vm), udptr));
}

fn cStrToSlice(str: [*c]const u8) []const u8 {
    return str[0..std.mem.lenZ(str)];
}

pub fn writeWrapper(cvm: ?*wren.Vm, ctext: [*c]const u8) callconv(.C) void {
    const vm = zigVmFromCVm(cvm);
    const writeFn = vm.writeFn orelse std.debug.panic("writeWrapper must only be installed when writeFn is set", .{});
    writeFn(vm, cStrToSlice(ctext));
}

pub fn errorWrapper(cvm: ?*wren.Vm, cerr_type: wren.ErrorType, cmodule: [*c]const u8, cline: c_int, cmessage: [*c]const u8) callconv(.C) void {
    const vm = zigVmFromCVm(cvm);
    const errorFn = vm.errorFn orelse std.debug.panic("errorWrapper must only be installed when errorFn is set", .{});
    const err_type: ErrorType = switch (cerr_type) {
        .WREN_ERROR_COMPILE => .Compile,
        .WREN_ERROR_RUNTIME => .Runtime,
        .WREN_ERROR_STACK_TRACE => .StackTrace,
        else => std.debug.panic("unknown error type: {}", .{cerr_type}),
    };
    errorFn(vm, err_type, if (cmodule != null) cStrToSlice(cmodule) else null, if (cline >= 0) @intCast(u32, cline) else null, cStrToSlice(cmessage));
}

pub fn resolveModuleWrapper(cvm: ?*wren.Vm, cimporter: [*c]const u8, cname: [*c]const u8) callconv(.C) [*c]u8 {
    const vm = zigVmFromCVm(cvm);
    const resolveModuleFn = vm.resolveModuleFn orelse std.debug.panic("resolveModuleWrapper must only be installed when resolveModuleFn is set", .{});
    const mem = resolveModuleFn(vm, cStrToSlice(cimporter), cStrToSlice(cname));
    assert(mem.allocator == if (vm.allocator == null) std.heap.c_allocator else vm.allocator);
    return mem.data.ptr;
}

pub fn loadModuleWrapper(cvm: ?*wren.Vm, cname: [*c]const u8) callconv(.C) [*c]u8 {
    const vm = zigVmFromCVm(cvm);
    const loadModuleFn = vm.loadModuleFn orelse std.debug.panic("loadModuleWrapper must only be installed when loadModuleFn is set", .{});
    const mem = loadModuleFn(vm, cStrToSlice(cname));
    assert(mem.allocator == if (vm.allocator == null) std.heap.c_allocator else vm.allocator);
    return mem.data.ptr;
}
