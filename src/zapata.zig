pub usingnamespace @import("./zapata/allocator_wrapper.zig");
pub usingnamespace @import("./zapata/error.zig");
pub usingnamespace @import("./zapata/vm.zig");

test "zapata" {
    _ = @import("./zapata/allocator_wrapper.zig");
    _ = @import("./zapata/error.zig");
    _ = @import("./zapata/vm.zig");
    _ = @import("./zapata/wren.zig");
}