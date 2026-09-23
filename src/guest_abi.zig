pub const ParameterType = enum(c_int) {
    int = 0,
    uint = 1,
    long = 2,
    ulong = 3,
    float = 4,
    double = 5,
    string = 6,
    bool = 7,
    bytes = 8,
    byte_chunks = 9,
};

pub const ReturnType = enum(c_int) {
    int = 0,
    uint = 1,
    long = 2,
    ulong = 3,
    float = 4,
    double = 5,
    string = 6,
    bool = 7,
    void = 8,
    bytes = 9,
    byte_chunks = 10,
};

pub const ErrorCode = enum(c_int) {
    no_error = 0,
    unsupported_parameter_type = 2,
    guest_function_name_not_provided = 3,
    guest_function_not_found = 4,
    incorrect_parameter_count = 5,
    dispatch_function_not_set = 6,
    outb_error = 7,
    unknown_error = 8,
    gs_check_failed = 10,
    too_many_guest_functions = 11,
    allocation_failure = 12,
    malloc_failed = 13,
    parameter_type_mismatch = 14,
    guest_error = 15,
    array_length_parameter_missing = 16,
    host_function_error = 17,
};

pub const Vec = extern struct {
    data: [*]u8,
    len: usize,
};

pub const ByteChunk = extern struct {
    data: [*]const u8,
    len: usize,
};

pub const ByteChunks = extern struct {
    chunks: [*]const ByteChunk,
    count: usize,
};

pub const Value = extern union {
    int: i32,
    uint: u32,
    long: i64,
    ulong: u64,
    float: f32,
    double: f64,
    bool: bool,
    string: [*:0]u8,
    bytes: Vec,
    byte_chunks: ByteChunks,
};

pub const Parameter = extern struct {
    tag: ParameterType,
    value: Value,
};

pub const ReturnValue = extern struct {
    tag: ReturnType,
    value: Value,
};

pub const FunctionCall = extern struct {
    function_name: [*:0]const u8,
    parameters: [*]const Parameter,
    parameters_len: usize,
    return_type: ReturnType,
};

pub const GuestFunction = *const fn (*const FunctionCall) callconv(.c) ?*ReturnValue;

pub extern fn hl_register_function_definition(
    function_name: [*:0]const u8,
    function: GuestFunction,
    parameter_count: usize,
    parameter_types: [*]const ParameterType,
    return_type: ReturnType,
) void;

pub extern fn hl_call_host_function_with_result(call: *const FunctionCall) ?*ReturnValue;
pub extern fn hl_free_return_value(value: ?*ReturnValue) void;

pub extern fn hl_result_from_Int(value: i32) *ReturnValue;
pub extern fn hl_result_from_UInt(value: u32) *ReturnValue;
pub extern fn hl_result_from_Long(value: i64) *ReturnValue;
pub extern fn hl_result_from_ULong(value: u64) *ReturnValue;
pub extern fn hl_result_from_Float(value: f32) *ReturnValue;
pub extern fn hl_result_from_Double(value: f64) *ReturnValue;
pub extern fn hl_result_from_Bool(value: bool) *ReturnValue;
pub extern fn hl_result_from_Void() *ReturnValue;
pub extern fn hl_result_from_StringBytes(data: [*]const u8, len: usize) ?*ReturnValue;
pub extern fn hl_result_from_Bytes(data: [*]const u8, len: usize) *ReturnValue;
pub extern fn hl_result_from_ByteChunks(value: ByteChunks) *ReturnValue;

pub extern fn hl_set_error(code: ErrorCode, message: [*:0]const u8) void;

pub extern fn malloc(size: usize) ?*anyopaque;
pub extern fn free(pointer: ?*anyopaque) void;
