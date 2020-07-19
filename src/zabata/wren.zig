const c = @cImport({
    @cInclude("wren.h");
});

// structs
pub const Configuration = c.WrenConfiguration;
pub const Vm = c.WrenVM;

// functions
pub const freeVm = c.wrenFreeVM;
pub const getUserData = c.wrenGetUserData;
pub const initConfiguration = c.wrenInitConfiguration;
pub const interpret = c.wrenInterpret;
pub const newVm = c.wrenNewVM;
pub const setUserData = c.wrenSetUserData;
