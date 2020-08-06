const c = @cImport({
    @cInclude("wren.h");
});

// structs
pub const Configuration = c.WrenConfiguration;
pub const Vm = c.WrenVM;
pub const ErrorType = c.WrenErrorType;

// functions
pub const ensureSlots = c.wrenEnsureSlots;
pub const freeVm = c.wrenFreeVM;
pub const getSlotBool = c.wrenGetSlotBool;
pub const getSlotBytes = c.wrenGetSlotBytes;
pub const getSlotCount = c.wrenGetSlotCount;
pub const getSlotDouble = c.wrenGetSlotDouble;
pub const getSlotString = c.wrenGetSlotString;
pub const getSlotType = c.wrenGetSlotType;
pub const getUserData = c.wrenGetUserData;
pub const getVariable = wrenGetVariable;
pub const initConfiguration = c.wrenInitConfiguration;
pub const insertInList = wrenInsertInList;
pub const interpret = c.wrenInterpret;
pub const newVm = c.wrenNewVM;
pub const setSlotBool = c.wrenSetSlotBool;
pub const setSlotBytes = c.wrenSetSlotBytes;
pub const setSlotDouble = c.wrenSetSlotDouble;
pub const setSlotNewList = wrenSetSlotNewList;
pub const setSlotNull = c.wrenSetSlotNull;
pub const setSlotString = c.wrenSetSlotString;
pub const setUserData = c.wrenSetUserData;
