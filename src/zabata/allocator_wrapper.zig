const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const wren = @import("./zabata/wren.zig");

const Vm = @import("./vm.zig").Vm;

// Zig's allocators operate on slices, the wrapped C library just passes a
// length-less pointer into memory. The code in this file prepends a small
// metadata block before each allocated chunk of memory to store information
// for zig.

const MemoryMetadata = struct {
    slice: []u8,
};

// Don't fuss with alignment on this.
const MemoryMetadataPtr = *align(1) MemoryMetadata;

fn calcAllocSize(requested: usize) usize {
    return requested + @sizeOf(MemoryMetadata);
}

fn metadataFromPtr(memory: ?*c_void) MemoryMetadataPtr {
    return @intToPtr(MemoryMetadataPtr, @ptrToInt(memory) - @sizeOf(MemoryMetadata));
}

fn ptrFromMetadataPtr(metadata: MemoryMetadataPtr) [*]u8 {
    return @intToPtr([*]u8, @ptrToInt(metadata) + @sizeOf(MemoryMetadata));
}

/// There are a few possible combinations of parameters.
/// • memory = null -> allocation
/// • new_size = 0 -> deallocation
/// • both != null/0 -> reallocation
/// • both = null/0 -> no-op
fn wrenReallocate(allocator: *Allocator, memory: ?*c_void, new_size: usize) ?*c_void {
    // This is apparently valid and described in more detail here:
    // https://github.com/wren-lang/wren/pull/279
    if (memory == null and new_size == 0) {
        return null;
    }
    if (memory == null) {
        assert(new_size != 0);
        const begin = allocator.alloc(u8, calcAllocSize(new_size)) catch |e| {
            return null;
        };
        var meta: MemoryMetadataPtr = @ptrCast(MemoryMetadataPtr, begin);
        var ptr = ptrFromMetadataPtr(meta);
        meta.slice.ptr = ptr;
        meta.slice.len = new_size;
        return ptr;
    }

    var old_meta = metadataFromPtr(memory);
    var slice: []u8 = undefined;
    slice.len = calcAllocSize(old_meta.slice.len);
    slice.ptr = @ptrCast([*]u8, old_meta);

    const allocSize = if (new_size == 0) 0 else calcAllocSize(new_size);
    const begin = allocator.realloc(slice, allocSize) catch |e| {
        return null;
    };

    if (new_size != 0) {
        var new_meta = @ptrCast(MemoryMetadataPtr, begin);
        var ptr = ptrFromMetadataPtr(new_meta);
        new_meta.slice.ptr = ptr;
        new_meta.slice.len = new_size;
        return ptr;
    }

    return null;
}

pub fn allocatorWrapper(memory: ?*c_void, new_size: usize, user_data: ?*c_void) callconv(.C) ?*c_void {
    assert(user_data != null);
    const zvm = @ptrCast(*Vm, @alignCast(@alignOf(*Vm), user_data));
    var allocator = zvm.allocator orelse std.debug.panic("allocatorWrapper must only be installed when an allocator is set", .{});

    return wrenReallocate(allocator, memory, new_size);
}

const test_allocator = std.testing.allocator;

test "allocating metadata" {
    const ptr = wrenReallocate(test_allocator, null, 32);
    const meta = metadataFromPtr(ptr);
    std.testing.expect(@ptrToInt(meta.slice.ptr) == @ptrToInt(ptr));
    std.testing.expect(meta.slice.len == 32);
    _ = wrenReallocate(test_allocator, ptr, 0);
}

test "reallocating with metadata" {
    const ptr1 = wrenReallocate(test_allocator, null, 32);
    const ptr2 = wrenReallocate(test_allocator, ptr1, 128);
    const meta = metadataFromPtr(ptr2);
    std.testing.expect(@ptrToInt(meta.slice.ptr) == @ptrToInt(ptr2));
    std.testing.expect(meta.slice.len == 128);
    _ = wrenReallocate(test_allocator, ptr2, 0);
}
