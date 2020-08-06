const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const wren = @import("./wren.zig");
const wrappers = @import("./c_wrappers.zig");
const WrenError = @import("./error.zig").WrenError;
const allocatorWrapper = @import("./allocator_wrapper.zig").allocatorWrapper;

pub const ErrorType = enum { Compile, Runtime, StackTrace };

pub const SlotType = enum {
    Bool,
    Foreign,
    List,
    Map,
    Null,
    Number,
    String,
    Unknown,
};

pub fn AllocatedMemory(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: *Allocator,
        data: []T,

        pub fn init(allocator: *Allocator, len: usize) Self {
            // In the future, not panicking might be nice. But failing
            // allocations here put the VM in an irrecoverable state.
            const data = allocator.alloc(T, len) catch |e| std.debug.panic("could not allocate memory but really need it", .{});
            return Self{ .allocator = allocator, .data = data };
        }
    };
}

const AllocatedBytes = AllocatedMemory(u8);

pub const WriteFn = fn (*Vm, []const u8) void;
pub const ErrorFn = fn (*Vm, ErrorType, ?[]const u8, ?u32, []const u8) void;
pub const ResolveModuleFn = fn (*Vm, []const u8, []const u8) AllocatedBytes;
pub const LoadModuleFn = fn (*Vm, []const u8) AllocatedBytes;

pub const Configuration = struct {
    const Self = @This();

    allocator: ?*Allocator = null,
    resolveModuleFn: ?ResolveModuleFn = null,
    loadModuleFn: ?LoadModuleFn = null,
    writeFn: ?WriteFn = null,
    errorFn: ?ErrorFn = null,
    initialHeapSize: ?usize = null,
    minHeapSize: ?usize = null,
    heapGrowthPercent: ?u8 = null,

    // This will be much nicer when https://github.com/ziglang/zig/issues/2765 is done.
    pub fn newVmInPlace(self: Self, comptime UserData: type, result: *Vm, user_data: ?*UserData) WrenError!void {
        var cfg: wren.Configuration = undefined;
        wren.initConfiguration(&cfg);

        if (self.allocator) |a| {
            cfg.reallocateFn = allocatorWrapper;
        }

        if (self.resolveModuleFn) |f| {
            cfg.resolveModuleFn = wrappers.resolveModuleWrapper;
        }

        if (self.loadModuleFn) |f| {
            cfg.loadModuleFn = wrappers.loadModuleWrapper;
        }

        if (self.writeFn) |f| {
            cfg.writeFn = wrappers.writeWrapper;
        }

        if (self.errorFn) |f| {
            cfg.errorFn = wrappers.errorWrapper;
        }

        if (self.initialHeapSize) |i| {
            cfg.initialHeapSize = i;
        }
        if (self.minHeapSize) |i| {
            cfg.minHeapSize = i;
        }
        if (self.heapGrowthPercent) |i| {
            cfg.heapGrowthPercent = i;
        }

        // This is slightly hacky, but even the VM creation needs the
        // allocator.  Create a temporary pseudo-userdata with only the
        // allocator set, it will be replaced after being used once.
        var pseudo_vm: Vm = undefined;
        std.mem.set(u8, std.mem.asBytes(&Vm), 0);
        pseudo_vm.allocator = self.allocator;
        cfg.userData = &pseudo_vm;

        const ptr = wren.newVm(&cfg) orelse return WrenError.VmCreationFailed;
        Vm.initInPlace(UserData, result, ptr, self, user_data);
    }
};

pub const Vm = struct {
    const Self = @This();

    vm: *wren.Vm,
    allocator: ?*Allocator,
    resolveModuleFn: ?ResolveModuleFn,
    loadModuleFn: ?LoadModuleFn,
    writeFn: ?WriteFn,
    errorFn: ?ErrorFn,
    user_data_ptr: ?usize,

    // This will be much nicer when https://github.com/ziglang/zig/issues/2765 is done.
    pub fn initInPlace(comptime UserData: type, result: *Self, vm: *wren.Vm, conf: Configuration, user_data: ?*UserData) void {
        result.vm = vm;
        result.allocator = conf.allocator;
        result.resolveModuleFn = conf.resolveModuleFn;
        result.loadModuleFn = conf.loadModuleFn;
        result.writeFn = conf.writeFn;
        result.errorFn = conf.errorFn;
        result.user_data_ptr = if (@sizeOf(UserData) > 0 and user_data != null) @ptrToInt(user_data) else null;
        result.registerWithWren();
    }

    pub fn deinit(self: *Self) void {
        wren.freeVm(self.vm);
    }

    fn registerWithWren(self: *Self) void {
        wren.setUserData(self.vm, self);
    }

    pub fn getUserData(self: *Self, comptime UserData: type) *UserData {
        const udp = self.user_data_ptr orelse std.debug.panic("user data pointer is null", .{});
        return @intToPtr(*UserData, udp);
    }

    pub fn interpret(self: *Self, module: []const u8, code: []const u8) WrenError!void {
        const res = wren.interpret(self.vm, @ptrCast([*c]const u8, module), @ptrCast([*c]const u8, code));
        if (res == .WREN_RESULT_COMPILE_ERROR) {
            return WrenError.CompileError;
        }
        if (res == .WREN_RESULT_RUNTIME_ERROR) {
            return WrenError.RuntimeError;
        }
    }

    pub fn getSlotCount(self: *Self) u32 {
        const slot_count = wren.getSlotCount(self.vm);
        assert(slot_count >= 0);
        return @intCast(u32, slot_count);
    }

    pub fn ensureSlots(self: *Self, slot_count: u32) void {
        wren.ensureSlots(self.vm, @intCast(c_int, slot_count));
    }

    pub fn getSlotType(self: *Self, slot_index: u32) SlotType {
        return switch (wren.getSlotType(self.vm, @intCast(c_int, slot_index))) {
            .WREN_TYPE_BOOL => .Bool,
            .WREN_TYPE_FOREIGN => .Foreign,
            .WREN_TYPE_LIST => .Map,
            .WREN_TYPE_MAP => .Map,
            .WREN_TYPE_NULL => .Null,
            .WREN_TYPE_NUM => .Number,
            .WREN_TYPE_STRING => .String,
            .WREN_TYPE_UNKNOWN => .Unknown,
            else => std.debug.panic("invalid slot type returned: {}", .{wren.getSlotType(self.vm, @intCast(c_int, slot_index))}),
        };
    }

    pub fn setSlot(self: *Self, slot_index: u32, value: anytype) void {
        comptime const ti = @typeInfo(@TypeOf(value));
        // @compileLog("type: " ++ @typeName(@TypeOf(value)));
        switch (ti) {
            .Bool => wren.setSlotBool(self.vm, @intCast(c_int, slot_index), value),
            .Int => wren.setSlotDouble(self.vm, @intCast(c_int, slot_index), @intToFloat(f64, value)),
            .Float => wren.setSlotDouble(self.vm, @intCast(c_int, slot_index), value),
            .ComptimeInt => wren.setSlotDouble(self.vm, @intCast(c_int, slot_index), value),
            .ComptimeFloat => wren.setSlotDouble(self.vm, @intCast(c_int, slot_index), value),
            .Array => if (ti.Array.child == u8) wren.setSlotBytes(@intCast(c_int, slot_index), value.ptr, value.len) else @compileError("only u8 arrays are allowed"),
            .Pointer => {
                comptime const cti = @typeInfo(ti.Pointer.child);
                if (cti == .Array and cti.Array.child == u8) {
                    wren.setSlotBytes(self.vm, @intCast(c_int, slot_index), @ptrCast([*c]const u8, value), value.*.len);
                } else {
                    @compileError("only pointers to u8 arrays are allowed");
                }
            },
            .Null => wren.setSlotNull(self.vm, @intCast(c_int, slot_index)),
            else => @compileError("not a valid wren datatype"),
        }
    }
};

fn printError(vm: *Vm, error_type: ErrorType, module: ?[]const u8, line: ?u32, message: []const u8) void {
    std.debug.print("error_type={}, module={}, line={}, message={}\n", .{ error_type, module, line, message });
}

const testing = std.testing;

const EmptyUserData = struct {};
const TestUserData = struct {
    i: i32,
};

test "init vm" {
    var user_data = TestUserData{ .i = 23 };
    var config = Configuration{};
    var vm: Vm = undefined;
    try config.newVmInPlace(TestUserData, &vm, &user_data);
    defer vm.deinit();

    const ud = vm.getUserData(TestUserData);
    testing.expectEqual(@as(i32, 23), ud.i);
}

var testPrintSuccess = false;
fn testPrint(vm: *Vm, text: []const u8) void {
    testPrintSuccess = true;
}

test "writeFn" {
    var config = Configuration{};
    config.writeFn = testPrint;

    var vm: Vm = undefined;
    try config.newVmInPlace(EmptyUserData, &vm, null);

    testing.expect(!testPrintSuccess);
    try vm.interpret("main", "System.print(\"I am running in a VM!\")");
    testing.expect(testPrintSuccess);
}

var testResolveModuleSuccess = false;
fn testResolveModule(vm: *Vm, importer: []const u8, name: []const u8) AllocatedBytes {
    testing.expectEqualStrings("test_main", importer);
    testing.expectEqualStrings("my_module", name);
    const res = "it worked!";
    var mem = AllocatedBytes.init(std.heap.c_allocator, res.len + 1);
    std.mem.copy(u8, mem.data, res);
    mem.data[res.len] = 0;
    testResolveModuleSuccess = true;
    return mem;
}

fn testResolveLoadModule(vm: *Vm, name: []const u8) AllocatedBytes {
    testing.expectEqualStrings("it worked!", name);
    const src = "";
    var mem = AllocatedBytes.init(std.heap.c_allocator, src.len + 1);
    std.mem.copy(u8, mem.data, src);
    mem.data[src.len] = 0;
    return mem;
}

test "resolveModuleFn" {
    var config = Configuration{};
    config.resolveModuleFn = testResolveModule;
    config.loadModuleFn = testResolveLoadModule;

    var vm: Vm = undefined;
    try config.newVmInPlace(EmptyUserData, &vm, null);
    defer vm.deinit();
    try vm.interpret("test_main", "import \"my_module\"");
    testing.expect(testResolveModuleSuccess == true);
}

var testLoadModuleSuccess = false;
fn testLoadModule(vm: *Vm, name: []const u8) AllocatedBytes {
    testing.expectEqualStrings(name, "my_module");
    testLoadModuleSuccess = true;
    const source = "System.print(\"I am running in a VM!\")";
    var mem = AllocatedMemory(u8).init(std.heap.c_allocator, source.len + 1);
    std.mem.copy(u8, mem.data, source);
    mem.data[source.len] = 0;
    return mem;
}

test "loadModuleFn" {
    var config = Configuration{};
    config.loadModuleFn = testLoadModule;

    var vm: Vm = undefined;
    try config.newVmInPlace(EmptyUserData, &vm, null);
    defer vm.deinit();
    try vm.interpret("main", "import \"my_module\"");
    testing.expect(testLoadModuleSuccess == true);
}

var testCompileErrorCount: i32 = 0;
var testRuntimeErrorCount: i32 = 0;
var testStackTraceErrorCount: i32 = 0;
fn testError(vm: *Vm, error_type: ErrorType, module: ?[]const u8, line: ?u32, message: []const u8) void {
    if (error_type == .Compile) {
        testCompileErrorCount += 1;
    }
    if (error_type == .Runtime) {
        testRuntimeErrorCount += 1;
    }
    if (error_type == .StackTrace) {
        testStackTraceErrorCount += 1;
    }
}

test "errorFn" {
    var config = Configuration{};
    config.errorFn = testError;

    var vm: Vm = undefined;
    try config.newVmInPlace(EmptyUserData, &vm, null);

    vm.interpret("main", "zimport \"my_module\"") catch |e| {};
    testing.expectEqual(testCompileErrorCount, 2);

    vm.interpret("main", "import \"blob\"") catch |e| {};
    testing.expectEqual(@intCast(i32, 1), testRuntimeErrorCount);
    testing.expectEqual(@intCast(i32, 1), testStackTraceErrorCount);
}

test "allocators" {
    const alloc = std.testing.allocator;
    // const alloc = std.heap.c_allocator;
    var config = Configuration{};
    config.allocator = alloc;

    var vm: Vm = undefined;
    try config.newVmInPlace(EmptyUserData, &vm, null);
    defer vm.deinit();
    try vm.interpret("main", "System.print(\"I am running in a VM!\")");
}

test "slot count" {
    var config = Configuration{};
    var vm: Vm = undefined;
    try config.newVmInPlace(EmptyUserData, &vm, null);
    defer vm.deinit();

    vm.ensureSlots(10);
    testing.expect(vm.getSlotCount() >= 10);
}

test "slot types" {
    var config = Configuration{};
    var vm: Vm = undefined;
    try config.newVmInPlace(EmptyUserData, &vm, null);
    defer vm.deinit();

    vm.ensureSlots(100);
    var i: u32 = 0;

    vm.setSlot(i, true);
    testing.expectEqual(SlotType.Bool, vm.getSlotType(i));
    i += 1;

    var runtimeInt: i32 = 42;
    vm.setSlot(i, runtimeInt);
    testing.expectEqual(SlotType.Number, vm.getSlotType(i));
    i += 1;

    var runtimeFloat: f32 = 23.5;
    vm.setSlot(i, runtimeFloat);
    testing.expectEqual(SlotType.Number, vm.getSlotType(i));
    i += 1;

    vm.setSlot(i, 42);
    testing.expectEqual(SlotType.Number, vm.getSlotType(i));
    i += 1;

    vm.setSlot(i, 23.5);
    testing.expectEqual(SlotType.Number, vm.getSlotType(i));
    i += 1;

    vm.setSlot(i, "All your base");
    testing.expectEqual(SlotType.String, vm.getSlotType(i));
    i += 1;

    vm.setSlot(i, null);
    testing.expectEqual(SlotType.Null, vm.getSlotType(i));
    i += 1;
}
