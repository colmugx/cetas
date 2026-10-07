/// Native GPUI bridge. MoonBit only consumes C ABI.

///|
extern "C" fn native_command_len() -> UInt = "cetas_gpui_command_len"

///|
#borrow(out)
extern "C" fn native_command_copy(
  out : FixedArray[Byte],
  capacity : UInt,
) -> Int = "cetas_gpui_command_copy"

///|
#borrow(data)
extern "C" fn native_emit(
  data : Bytes,
  length : UInt,
) -> Int = "cetas_gpui_emit"

///|
fn bridge_take_command() -> String? {
  let len = native_command_len()
  if len == 0U {
    return None
  }
  let out : FixedArray[Byte] = FixedArray::make(
    len.reinterpret_as_int(),
    b'\x00',
  )
  if native_command_copy(out, len) != 0 {
    return None
  }
  let bytes = Bytes::from_array(out)
  let text = @utf8.decode(bytes) catch {
    _ => return None
  }
  Some(text)
}

///|
fn bridge_emit_text(text : String) -> Unit {
  let data = @utf8.encode(text)
  ignore(native_emit(data, data.length().reinterpret_as_uint()))
}

///|
fn bridge_emit_json(value : Json) -> Unit {
  bridge_emit_text(value.stringify())
}
