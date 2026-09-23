use std::ffi::c_void;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::PathBuf;
use std::ptr::{self, NonNull};
use std::slice;
use std::str;
use std::sync::Arc;

use hyperlight_host::func::{Bytes, ParameterType, ParameterValue, ReturnType, ReturnValue};
use hyperlight_host::sandbox::snapshot::Snapshot;
use hyperlight_host::{HyperlightError, MultiUseSandbox, SandboxBuilder};

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HlzType {
    Void = 0,
    Int = 1,
    UInt = 2,
    Long = 3,
    ULong = 4,
    Float = 5,
    Double = 6,
    Bool = 7,
    String = 8,
    VecBytes = 9,
    ByteChunks = 10,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct HlzBytes {
    pub data: *const u8,
    pub len: usize,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct HlzByteChunks {
    pub chunks: *const HlzBytes,
    pub len: usize,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub union HlzValueData {
    pub int_value: i32,
    pub uint_value: u32,
    pub long_value: i64,
    pub ulong_value: u64,
    pub float_value: f32,
    pub double_value: f64,
    pub bool_value: bool,
    pub bytes_value: HlzBytes,
    pub chunks_value: HlzByteChunks,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct HlzValue {
    pub tag: HlzType,
    pub value: HlzValueData,
}

impl HlzValue {
    fn void() -> Self {
        Self {
            tag: HlzType::Void,
            value: HlzValueData { ulong_value: 0 },
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HlzStatus {
    Ok = 0,
    InvalidArgument = 1,
    HyperlightError = 2,
    CallbackError = 3,
    Panic = 4,
}

#[repr(C)]
pub struct HlzError {
    pub data: *mut u8,
    pub len: usize,
}

impl HlzError {
    fn empty() -> Self {
        Self {
            data: ptr::null_mut(),
            len: 0,
        }
    }
}

pub struct HlzBuilder {
    inner: Option<SandboxBuilder>,
}

pub struct HlzSandbox {
    inner: MultiUseSandbox,
}

pub struct HlzSnapshot {
    inner: Arc<Snapshot>,
}

pub type HlzHostCallback = unsafe extern "C" fn(
    context: *mut c_void,
    args: *const HlzValue,
    args_len: usize,
    result: *mut HlzValue,
    error: *mut HlzBytes,
) -> HlzStatus;

#[derive(Clone, Copy)]
struct SendContext(*mut c_void);

// SAFETY: the binding requires callback context to remain valid for the
// sandbox lifetime. Hyperlight serializes mutable callback access.
unsafe impl Send for SendContext {}

impl SendContext {
    fn get(self) -> *mut c_void {
        self.0
    }
}

fn borrowed_bytes(value: HlzBytes) -> Result<&'static [u8], String> {
    if value.len == 0 {
        return Ok(&[]);
    }
    let data = NonNull::new(value.data.cast_mut())
        .ok_or_else(|| "non-empty byte value has a null pointer".to_string())?;
    // SAFETY: the FFI caller guarantees the pointer covers `len` readable bytes
    // for the duration of the call.
    Ok(unsafe { slice::from_raw_parts(data.as_ptr(), value.len) })
}

fn borrowed_values(values: *const HlzValue, len: usize) -> Result<&'static [HlzValue], String> {
    if len == 0 {
        return Ok(&[]);
    }
    let values = NonNull::new(values.cast_mut())
        .ok_or_else(|| "non-empty value list has a null pointer".to_string())?;
    // SAFETY: the FFI caller guarantees the pointer covers `len` values for
    // the duration of the call.
    Ok(unsafe { slice::from_raw_parts(values.as_ptr(), len) })
}

fn borrowed_types(values: *const HlzType, len: usize) -> Result<&'static [HlzType], String> {
    if len == 0 {
        return Ok(&[]);
    }
    let values = NonNull::new(values.cast_mut())
        .ok_or_else(|| "non-empty type list has a null pointer".to_string())?;
    // SAFETY: the FFI caller guarantees the pointer covers `len` values for
    // the duration of the call.
    Ok(unsafe { slice::from_raw_parts(values.as_ptr(), len) })
}

fn name_from_bytes(value: HlzBytes, what: &str) -> Result<String, String> {
    let bytes = borrowed_bytes(value)?;
    str::from_utf8(bytes)
        .map(str::to_owned)
        .map_err(|_| format!("{what} is not valid UTF-8"))
}

fn to_parameter(value: &HlzValue) -> Result<ParameterValue, String> {
    // SAFETY: the active union field is selected by `tag`.
    unsafe {
        match value.tag {
            HlzType::Int => Ok(ParameterValue::Int(value.value.int_value)),
            HlzType::UInt => Ok(ParameterValue::UInt(value.value.uint_value)),
            HlzType::Long => Ok(ParameterValue::Long(value.value.long_value)),
            HlzType::ULong => Ok(ParameterValue::ULong(value.value.ulong_value)),
            HlzType::Float => Ok(ParameterValue::Float(value.value.float_value)),
            HlzType::Double => Ok(ParameterValue::Double(value.value.double_value)),
            HlzType::Bool => Ok(ParameterValue::Bool(value.value.bool_value)),
            HlzType::String => {
                let value = borrowed_bytes(value.value.bytes_value)?;
                let value = str::from_utf8(value)
                    .map_err(|_| "string parameter is not valid UTF-8".to_string())?;
                Ok(ParameterValue::String(value.to_owned()))
            }
            HlzType::VecBytes => Ok(ParameterValue::VecBytes(
                borrowed_bytes(value.value.bytes_value)?.to_vec(),
            )),
            HlzType::ByteChunks => {
                let chunks = value.value.chunks_value;
                if chunks.len == 0 {
                    return Ok(ParameterValue::ByteChunks(Vec::new()));
                }
                let chunks_ptr = NonNull::new(chunks.chunks.cast_mut())
                    .ok_or_else(|| "non-empty chunk list has a null pointer".to_string())?;
                let chunks = slice::from_raw_parts(chunks_ptr.as_ptr(), chunks.len);
                let chunks = chunks
                    .iter()
                    .map(|chunk| borrowed_bytes(*chunk).map(Bytes::copy_from_slice))
                    .collect::<Result<Vec<_>, _>>()?;
                Ok(ParameterValue::ByteChunks(chunks))
            }
            HlzType::Void => Err("void is not a valid parameter type".to_string()),
        }
    }
}

fn to_return(value: &HlzValue) -> Result<ReturnValue, String> {
    if value.tag == HlzType::Void {
        return Ok(ReturnValue::Void(()));
    }
    Ok(match to_parameter(value)? {
        ParameterValue::Int(value) => ReturnValue::Int(value),
        ParameterValue::UInt(value) => ReturnValue::UInt(value),
        ParameterValue::Long(value) => ReturnValue::Long(value),
        ParameterValue::ULong(value) => ReturnValue::ULong(value),
        ParameterValue::Float(value) => ReturnValue::Float(value),
        ParameterValue::Double(value) => ReturnValue::Double(value),
        ParameterValue::Bool(value) => ReturnValue::Bool(value),
        ParameterValue::String(value) => ReturnValue::String(value),
        ParameterValue::VecBytes(value) => ReturnValue::VecBytes(value),
        ParameterValue::ByteChunks(value) => ReturnValue::ByteChunks(value),
    })
}

fn to_parameter_type(value: HlzType) -> Result<ParameterType, String> {
    match value {
        HlzType::Int => Ok(ParameterType::Int),
        HlzType::UInt => Ok(ParameterType::UInt),
        HlzType::Long => Ok(ParameterType::Long),
        HlzType::ULong => Ok(ParameterType::ULong),
        HlzType::Float => Ok(ParameterType::Float),
        HlzType::Double => Ok(ParameterType::Double),
        HlzType::Bool => Ok(ParameterType::Bool),
        HlzType::String => Ok(ParameterType::String),
        HlzType::VecBytes => Ok(ParameterType::VecBytes),
        HlzType::ByteChunks => Ok(ParameterType::ByteChunks),
        HlzType::Void => Err("void is not a valid parameter type".to_string()),
    }
}

fn to_return_type(value: HlzType) -> ReturnType {
    match value {
        HlzType::Void => ReturnType::Void,
        HlzType::Int => ReturnType::Int,
        HlzType::UInt => ReturnType::UInt,
        HlzType::Long => ReturnType::Long,
        HlzType::ULong => ReturnType::ULong,
        HlzType::Float => ReturnType::Float,
        HlzType::Double => ReturnType::Double,
        HlzType::Bool => ReturnType::Bool,
        HlzType::String => ReturnType::String,
        HlzType::VecBytes => ReturnType::VecBytes,
        HlzType::ByteChunks => ReturnType::ByteChunks,
    }
}

fn leak_bytes(value: Vec<u8>) -> HlzBytes {
    if value.is_empty() {
        return HlzBytes {
            data: ptr::null(),
            len: 0,
        };
    }
    let value = value.into_boxed_slice();
    let len = value.len();
    let data = Box::into_raw(value).cast::<u8>();
    HlzBytes { data, len }
}

fn from_return(value: ReturnValue) -> HlzValue {
    match value {
        ReturnValue::Void(()) => HlzValue::void(),
        ReturnValue::Int(value) => HlzValue {
            tag: HlzType::Int,
            value: HlzValueData { int_value: value },
        },
        ReturnValue::UInt(value) => HlzValue {
            tag: HlzType::UInt,
            value: HlzValueData { uint_value: value },
        },
        ReturnValue::Long(value) => HlzValue {
            tag: HlzType::Long,
            value: HlzValueData { long_value: value },
        },
        ReturnValue::ULong(value) => HlzValue {
            tag: HlzType::ULong,
            value: HlzValueData { ulong_value: value },
        },
        ReturnValue::Float(value) => HlzValue {
            tag: HlzType::Float,
            value: HlzValueData { float_value: value },
        },
        ReturnValue::Double(value) => HlzValue {
            tag: HlzType::Double,
            value: HlzValueData {
                double_value: value,
            },
        },
        ReturnValue::Bool(value) => HlzValue {
            tag: HlzType::Bool,
            value: HlzValueData { bool_value: value },
        },
        ReturnValue::String(value) => HlzValue {
            tag: HlzType::String,
            value: HlzValueData {
                bytes_value: leak_bytes(value.into_bytes()),
            },
        },
        ReturnValue::VecBytes(value) => HlzValue {
            tag: HlzType::VecBytes,
            value: HlzValueData {
                bytes_value: leak_bytes(value),
            },
        },
        ReturnValue::ByteChunks(value) => {
            let chunks = value
                .into_iter()
                .map(|chunk| leak_bytes(chunk.to_vec()))
                .collect::<Vec<_>>()
                .into_boxed_slice();
            let len = chunks.len();
            let chunks = if len == 0 {
                ptr::null()
            } else {
                Box::into_raw(chunks).cast::<HlzBytes>()
            };
            HlzValue {
                tag: HlzType::ByteChunks,
                value: HlzValueData {
                    chunks_value: HlzByteChunks { chunks, len },
                },
            }
        }
    }
}

fn borrowed_value(value: &ParameterValue, chunks: Option<&[HlzBytes]>) -> HlzValue {
    match value {
        ParameterValue::Int(value) => HlzValue {
            tag: HlzType::Int,
            value: HlzValueData { int_value: *value },
        },
        ParameterValue::UInt(value) => HlzValue {
            tag: HlzType::UInt,
            value: HlzValueData { uint_value: *value },
        },
        ParameterValue::Long(value) => HlzValue {
            tag: HlzType::Long,
            value: HlzValueData { long_value: *value },
        },
        ParameterValue::ULong(value) => HlzValue {
            tag: HlzType::ULong,
            value: HlzValueData {
                ulong_value: *value,
            },
        },
        ParameterValue::Float(value) => HlzValue {
            tag: HlzType::Float,
            value: HlzValueData {
                float_value: *value,
            },
        },
        ParameterValue::Double(value) => HlzValue {
            tag: HlzType::Double,
            value: HlzValueData {
                double_value: *value,
            },
        },
        ParameterValue::Bool(value) => HlzValue {
            tag: HlzType::Bool,
            value: HlzValueData { bool_value: *value },
        },
        ParameterValue::String(value) => HlzValue {
            tag: HlzType::String,
            value: HlzValueData {
                bytes_value: HlzBytes {
                    data: value.as_ptr(),
                    len: value.len(),
                },
            },
        },
        ParameterValue::VecBytes(value) => HlzValue {
            tag: HlzType::VecBytes,
            value: HlzValueData {
                bytes_value: HlzBytes {
                    data: value.as_ptr(),
                    len: value.len(),
                },
            },
        },
        ParameterValue::ByteChunks(_) => {
            let chunks = chunks.unwrap_or_default();
            HlzValue {
                tag: HlzType::ByteChunks,
                value: HlzValueData {
                    chunks_value: HlzByteChunks {
                        chunks: chunks.as_ptr(),
                        len: chunks.len(),
                    },
                },
            }
        }
    }
}

fn callback_arguments(args: &[ParameterValue]) -> (Vec<Vec<HlzBytes>>, Vec<HlzValue>) {
    let chunk_storage = args
        .iter()
        .map(|arg| match arg {
            ParameterValue::ByteChunks(chunks) => chunks
                .iter()
                .map(|chunk| HlzBytes {
                    data: chunk.as_ptr(),
                    len: chunk.len(),
                })
                .collect(),
            _ => Vec::new(),
        })
        .collect::<Vec<_>>();
    let values = args
        .iter()
        .enumerate()
        .map(|(index, arg)| borrowed_value(arg, Some(&chunk_storage[index])))
        .collect();
    (chunk_storage, values)
}

fn error_message(value: HlzBytes) -> String {
    borrowed_bytes(value)
        .ok()
        .and_then(|bytes| str::from_utf8(bytes).ok())
        .unwrap_or("host callback failed")
        .to_owned()
}

fn set_error(error: *mut HlzError, message: impl Into<String>) {
    if error.is_null() {
        return;
    }
    let bytes = message.into().into_bytes();
    let value = leak_bytes(bytes);
    // SAFETY: the pointer was checked above and is supplied by the FFI caller.
    unsafe {
        *error = HlzError {
            data: value.data.cast_mut(),
            len: value.len,
        };
    }
}

fn run_ffi(error: *mut HlzError, f: impl FnOnce() -> Result<(), (HlzStatus, String)>) -> HlzStatus {
    if !error.is_null() {
        // SAFETY: non-null output pointer is writable by the FFI contract.
        unsafe { *error = HlzError::empty() };
    }
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(())) => HlzStatus::Ok,
        Ok(Err((status, message))) => {
            set_error(error, message);
            status
        }
        Err(_) => {
            set_error(error, "panic in hyperlightz bridge");
            HlzStatus::Panic
        }
    }
}

fn invalid(message: impl Into<String>) -> (HlzStatus, String) {
    (HlzStatus::InvalidArgument, message.into())
}

fn hyperlight(error: HyperlightError) -> (HlzStatus, String) {
    (HlzStatus::HyperlightError, error.to_string())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn hlz_builder_from_file(
    path: HlzBytes,
    builder_out: *mut *mut HlzBuilder,
    error: *mut HlzError,
) -> HlzStatus {
    run_ffi(error, || {
        if builder_out.is_null() {
            return Err(invalid("builder output pointer is null"));
        }
        let path = name_from_bytes(path, "guest path").map_err(invalid)?;
        let builder = Box::new(HlzBuilder {
            inner: Some(SandboxBuilder::from_file(PathBuf::from(path))),
        });
        // SAFETY: checked above.
        unsafe { *builder_out = Box::into_raw(builder) };
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn hlz_builder_host_function(
    builder: *mut HlzBuilder,
    name: HlzBytes,
    parameter_types: *const HlzType,
    parameter_count: usize,
    return_type: HlzType,
    callback: Option<HlzHostCallback>,
    context: *mut c_void,
    error: *mut HlzError,
) -> HlzStatus {
    run_ffi(error, || {
        let builder = unsafe { builder.as_mut() }.ok_or_else(|| invalid("builder is null"))?;
        let name = name_from_bytes(name, "host function name").map_err(invalid)?;
        let parameter_types = borrowed_types(parameter_types, parameter_count)
            .map_err(invalid)?
            .iter()
            .copied()
            .map(to_parameter_type)
            .collect::<Result<Vec<_>, _>>()
            .map_err(invalid)?;
        let callback = callback.ok_or_else(|| invalid("host callback is null"))?;
        let expected_return = return_type;
        let context = SendContext(context);
        let current = builder
            .inner
            .take()
            .ok_or_else(|| invalid("builder has already been consumed"))?;
        builder.inner = Some(current.host_function_dynamic(
            name,
            parameter_types,
            to_return_type(return_type),
            move |args| {
                let (_chunk_storage, args) = callback_arguments(&args);
                let mut result = HlzValue::void();
                let mut callback_error = HlzBytes {
                    data: ptr::null(),
                    len: 0,
                };
                // SAFETY: the callback and context originate from the FFI
                // caller, and all argument views remain alive for this call.
                let status = unsafe {
                    callback(
                        context.get(),
                        args.as_ptr(),
                        args.len(),
                        &mut result,
                        &mut callback_error,
                    )
                };
                if status != HlzStatus::Ok {
                    return Err(HyperlightError::Error(error_message(callback_error)));
                }
                if result.tag != expected_return {
                    return Err(HyperlightError::Error(format!(
                        "host callback returned {:?}, expected {:?}",
                        result.tag, expected_return
                    )));
                }
                to_return(&result).map_err(HyperlightError::Error)
            },
        ));
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn hlz_builder_build(
    builder: *mut HlzBuilder,
    sandbox_out: *mut *mut HlzSandbox,
    error: *mut HlzError,
) -> HlzStatus {
    run_ffi(error, || {
        let builder = unsafe { builder.as_mut() }.ok_or_else(|| invalid("builder is null"))?;
        if sandbox_out.is_null() {
            return Err(invalid("sandbox output pointer is null"));
        }
        let builder = builder
            .inner
            .take()
            .ok_or_else(|| invalid("builder has already been consumed"))?;
        let sandbox = builder.build().map_err(hyperlight)?;
        // SAFETY: checked above.
        unsafe {
            *sandbox_out = Box::into_raw(Box::new(HlzSandbox { inner: sandbox }));
        }
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn hlz_sandbox_call(
    sandbox: *mut HlzSandbox,
    function_name: HlzBytes,
    return_type: HlzType,
    args: *const HlzValue,
    args_len: usize,
    result_out: *mut HlzValue,
    error: *mut HlzError,
) -> HlzStatus {
    run_ffi(error, || {
        let sandbox = unsafe { sandbox.as_mut() }.ok_or_else(|| invalid("sandbox is null"))?;
        if result_out.is_null() {
            return Err(invalid("result output pointer is null"));
        }
        let function_name =
            name_from_bytes(function_name, "guest function name").map_err(invalid)?;
        let args = borrowed_values(args, args_len)
            .map_err(invalid)?
            .iter()
            .map(to_parameter)
            .collect::<Result<Vec<_>, _>>()
            .map_err(invalid)?;
        let result = sandbox
            .inner
            .call_dynamic(&function_name, to_return_type(return_type), args)
            .map_err(hyperlight)?;
        // SAFETY: checked above.
        unsafe { *result_out = from_return(result) };
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn hlz_sandbox_snapshot(
    sandbox: *mut HlzSandbox,
    snapshot_out: *mut *mut HlzSnapshot,
    error: *mut HlzError,
) -> HlzStatus {
    run_ffi(error, || {
        let sandbox = unsafe { sandbox.as_mut() }.ok_or_else(|| invalid("sandbox is null"))?;
        if snapshot_out.is_null() {
            return Err(invalid("snapshot output pointer is null"));
        }
        let snapshot = sandbox.inner.snapshot().map_err(hyperlight)?;
        // SAFETY: checked above.
        unsafe {
            *snapshot_out = Box::into_raw(Box::new(HlzSnapshot { inner: snapshot }));
        }
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn hlz_sandbox_restore(
    sandbox: *mut HlzSandbox,
    snapshot: *const HlzSnapshot,
    error: *mut HlzError,
) -> HlzStatus {
    run_ffi(error, || {
        let sandbox = unsafe { sandbox.as_mut() }.ok_or_else(|| invalid("sandbox is null"))?;
        let snapshot = unsafe { snapshot.as_ref() }.ok_or_else(|| invalid("snapshot is null"))?;
        sandbox
            .inner
            .restore(snapshot.inner.clone())
            .map_err(hyperlight)?;
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn hlz_error_deinit(error: *mut HlzError) {
    let Some(error) = (unsafe { error.as_mut() }) else {
        return;
    };
    if error.len != 0 && !error.data.is_null() {
        let data = ptr::slice_from_raw_parts_mut(error.data, error.len);
        // SAFETY: bridge errors are allocated by `leak_bytes`.
        drop(unsafe { Box::from_raw(data) });
    }
    *error = HlzError::empty();
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn hlz_value_deinit(value: *mut HlzValue) {
    let Some(value) = (unsafe { value.as_mut() }) else {
        return;
    };
    // SAFETY: the active union field is selected by `tag`, and only values
    // returned by this bridge are passed to this function.
    unsafe {
        match value.tag {
            HlzType::String | HlzType::VecBytes => {
                let bytes = value.value.bytes_value;
                if bytes.len != 0 && !bytes.data.is_null() {
                    let data = ptr::slice_from_raw_parts_mut(bytes.data.cast_mut(), bytes.len);
                    drop(Box::from_raw(data));
                }
            }
            HlzType::ByteChunks => {
                let chunks = value.value.chunks_value;
                if chunks.len != 0 && !chunks.chunks.is_null() {
                    let descriptors =
                        ptr::slice_from_raw_parts_mut(chunks.chunks.cast_mut(), chunks.len);
                    let descriptors = Box::from_raw(descriptors);
                    for bytes in &descriptors {
                        if bytes.len != 0 && !bytes.data.is_null() {
                            let data =
                                ptr::slice_from_raw_parts_mut(bytes.data.cast_mut(), bytes.len);
                            drop(Box::from_raw(data));
                        }
                    }
                    drop(descriptors);
                }
            }
            _ => {}
        }
    }
    *value = HlzValue::void();
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn hlz_builder_deinit(builder: *mut HlzBuilder) {
    if !builder.is_null() {
        // SAFETY: the pointer was returned by `hlz_builder_from_file`.
        drop(unsafe { Box::from_raw(builder) });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn hlz_sandbox_deinit(sandbox: *mut HlzSandbox) {
    if !sandbox.is_null() {
        // SAFETY: the pointer was returned by `hlz_builder_build`.
        drop(unsafe { Box::from_raw(sandbox) });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn hlz_snapshot_deinit(snapshot: *mut HlzSnapshot) {
    if !snapshot.is_null() {
        // SAFETY: the pointer was returned by `hlz_sandbox_snapshot`.
        drop(unsafe { Box::from_raw(snapshot) });
    }
}

#[cfg(test)]
mod tests {
    use std::mem::{align_of, offset_of, size_of};

    use super::*;

    #[test]
    fn c_abi_layout_is_stable() {
        assert_eq!(HlzType::Void as i32, 0);
        assert_eq!(HlzType::ByteChunks as i32, 10);
        assert_eq!(HlzStatus::Ok as i32, 0);
        assert_eq!(HlzStatus::Panic as i32, 4);
        assert_eq!(size_of::<HlzType>(), size_of::<i32>());
        assert_eq!(size_of::<HlzStatus>(), size_of::<i32>());
        assert_eq!(size_of::<HlzBytes>(), 2 * size_of::<usize>());
        assert_eq!(size_of::<HlzByteChunks>(), size_of::<HlzBytes>());
        assert_eq!(offset_of!(HlzValue, value) % align_of::<HlzValueData>(), 0);
    }

    #[test]
    fn values_round_trip() {
        let values = [
            ReturnValue::Int(-1),
            ReturnValue::UInt(2),
            ReturnValue::Long(-3),
            ReturnValue::ULong(4),
            ReturnValue::Float(5.0),
            ReturnValue::Double(6.0),
            ReturnValue::Bool(true),
            ReturnValue::String("hello".to_string()),
            ReturnValue::VecBytes(vec![1, 2, 3]),
            ReturnValue::ByteChunks(vec![
                Bytes::copy_from_slice(b"hello"),
                Bytes::copy_from_slice(b"world"),
            ]),
        ];

        for expected in values {
            let mut ffi = from_return(expected.clone());
            let actual = to_return(&ffi).unwrap();
            assert_eq!(actual, expected);
            // SAFETY: `ffi` is owned by the bridge.
            unsafe { hlz_value_deinit(&mut ffi) };
        }
    }

    #[test]
    fn rejects_invalid_utf8_strings() {
        let bytes = [0xff];
        let value = HlzValue {
            tag: HlzType::String,
            value: HlzValueData {
                bytes_value: HlzBytes {
                    data: bytes.as_ptr(),
                    len: bytes.len(),
                },
            },
        };
        assert!(to_parameter(&value).is_err());
    }
}
