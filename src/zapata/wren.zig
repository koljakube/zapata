const c = @cImport({
    @cInclude("wren.h");
});

// structs
pub const Configuration = c.WrenConfiguration;
pub const ErrorType = c.WrenErrorType;
pub const ForeignClassMethods = c.WrenForeignClassMethods;
pub const ForeignMethodFn = c.WrenForeignMethodFn;
pub const FinalizeFn = c.WrenFinalizerFn;
pub const Handle = c.WrenHandle;
pub const Vm = c.WrenVM;

// functions
pub const abortFiber = c.wrenAbortFiber;
pub const call = c.wrenCall;
pub const ensureSlots = c.wrenEnsureSlots;
pub const freeVm = c.wrenFreeVM;
pub const getSlotBool = c.wrenGetSlotBool;
pub const getSlotBytes = c.wrenGetSlotBytes;
pub const getSlotCount = c.wrenGetSlotCount;
pub const getSlotDouble = c.wrenGetSlotDouble;
pub const getSlotForeign = c.wrenGetSlotForeign;
pub const getSlotHandle = c.wrenGetSlotHandle;
pub const getSlotString = c.wrenGetSlotString;
pub const getSlotType = c.wrenGetSlotType;
pub const getUserData = c.wrenGetUserData;
pub const getVariable = c.wrenGetVariable;
pub const initConfiguration = c.wrenInitConfiguration;
pub const insertInList = c.wrenInsertInList;
pub const interpret = c.wrenInterpret;
pub const makeCallHandle = c.wrenMakeCallHandle;
pub const newVm = c.wrenNewVM;
pub const releaseHandle = c.wrenReleaseHandle;
pub const setSlotBool = c.wrenSetSlotBool;
pub const setSlotBytes = c.wrenSetSlotBytes;
pub const setSlotDouble = c.wrenSetSlotDouble;
pub const setSlotHandle = c.wrenSetSlotHandle;
pub const setSlotNewForeign = c.wrenSetSlotNewForeign;
pub const setSlotNewList = wrenSetSlotNewList;
pub const setSlotNull = c.wrenSetSlotNull;
pub const setSlotString = c.wrenSetSlotString;
pub const setUserData = c.wrenSetUserData;
