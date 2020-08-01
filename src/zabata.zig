pub usingnamespace @import("./zabata/allocator_wrapper.zig");
pub usingnamespace @import("./zabata/error.zig");
pub usingnamespace @import("./zabata/vm.zig");

test "zabata" {
    _ = @import("./zabata/allocator_wrapper.zig");
    _ = @import("./zabata/error.zig");
    _ = @import("./zabata/vm.zig");
    _ = @import("./zabata/wren.zig");
}
