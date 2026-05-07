//// MessagePack auto-codec bridging
//// [`Reflected`](./reflection.html#Reflected) trees to and from
//// [`message_pack`](./message_pack.html) byte streams. Composes
//// target-specific reflection with the pure-Gleam byte codec, replacing the
//// previous duplicated MessagePack code in `lily_transport_ffi.erl` and
//// `transport.ffi.mjs`.
////
//// Wire format for custom types matches the previous Erlang and JS FFI
//// implementations: a MessagePack map keyed by `"_"` (constructor name)
//// with positional field keys `"0"`, `"1"`, etc. Zero-field constructors
//// encode as `{"_": "ConstructorName"}`.

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/list
import gleam/result
import lily/internal/message_pack.{
  type Value, ValueArray, ValueBool, ValueBytes, ValueFloat, ValueInteger,
  ValueMap, ValueNil, ValueString,
}
import lily/internal/reflection.{
  type Reflected, ReflectedBool, ReflectedConstructor, ReflectedFloat,
  ReflectedInteger, ReflectedList, ReflectedNil, ReflectedString,
}

// =============================================================================
// INTERNAL FUNCTIONS
// =============================================================================

/// Encode a Gleam value to MessagePack bytes via reflection.
@internal
pub fn encode_message_pack(value: a) -> BitArray {
  reflection.reflect(value)
  |> reflected_to_message_pack
}

/// Decode MessagePack bytes to a Gleam value via reflection. The result is
/// `Dynamic` because the call site supplies the final type via the
/// `decode.Decoder` plumbing in transport.gleam.
@internal
pub fn decode_message_pack(bytes: BitArray) -> Result(Dynamic, Nil) {
  use #(message_pack_value, _) <- result.try(message_pack.decode(bytes))
  use reflected <- result.try(message_pack_value_to_reflected(
    message_pack_value,
  ))
  reflection.construct(reflected)
}

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

fn reflected_to_message_pack(reflected: Reflected) -> BitArray {
  case reflected {
    ReflectedNil -> message_pack.encode_nil()
    ReflectedBool(value) -> message_pack.encode_bool(value)
    ReflectedInteger(value) -> message_pack.encode_int(value)
    ReflectedFloat(value) -> message_pack.encode_float(value)
    ReflectedString(value) -> message_pack.encode_string(value)
    ReflectedList(items) ->
      list.map(items, reflected_to_message_pack)
      |> message_pack.encode_array
    ReflectedConstructor(name:, fields:) -> {
      // Layout matches the previous Erlang/JS FFI codecs byte-for-byte:
      // positional fields first, constructor name tag last. Zero-field
      // constructors emit just the tag.
      let tag_entry = #(
        message_pack.encode_string("_"),
        message_pack.encode_string(name),
      )
      let field_entries =
        list.index_map(fields, fn(field, index) {
          #(
            message_pack.encode_string(int.to_string(index)),
            reflected_to_message_pack(field),
          )
        })
      message_pack.encode_map(list.append(field_entries, [tag_entry]))
    }
  }
}

fn message_pack_value_to_reflected(value: Value) -> Result(Reflected, Nil) {
  case value {
    ValueNil -> Ok(ReflectedNil)
    ValueBool(b) -> Ok(ReflectedBool(b))
    ValueInteger(n) -> Ok(ReflectedInteger(n))
    ValueFloat(f) -> Ok(ReflectedFloat(f))
    ValueString(s) -> Ok(ReflectedString(s))
    // The auto-format never produces top-level bin, but the protocol
    // envelope wraps payload bytes that way; treat it as a nested decode.
    ValueBytes(bytes) ->
      case message_pack.decode(bytes) {
        Error(_) -> Error(Nil)
        Ok(#(inner, _)) -> message_pack_value_to_reflected(inner)
      }
    ValueArray(items) -> {
      use reflected_items <- result.try(list.try_map(
        items,
        message_pack_value_to_reflected,
      ))
      Ok(ReflectedList(reflected_items))
    }
    ValueMap(entries) -> map_to_reflected(entries)
  }
}

fn map_to_reflected(entries: List(#(Value, Value))) -> Result(Reflected, Nil) {
  // Constructor maps carry a "_" key with the constructor name. Anything
  // else is a decode error: the auto-format never produces plain maps.
  use name <- result.try(extract_constructor_name(entries))
  use fields <- result.try(extract_constructor_fields(entries, 0, []))
  Ok(ReflectedConstructor(name:, fields:))
}

fn extract_constructor_name(
  entries: List(#(Value, Value)),
) -> Result(String, Nil) {
  case entries {
    [] -> Error(Nil)
    [#(ValueString("_"), ValueString(name)), ..] -> Ok(name)
    [_, ..rest] -> extract_constructor_name(rest)
  }
}

fn extract_constructor_fields(
  entries: List(#(Value, Value)),
  index: Int,
  accumulator: List(Reflected),
) -> Result(List(Reflected), Nil) {
  let key = int.to_string(index)
  case lookup_string_key(entries, key) {
    Error(_) -> Ok(list.reverse(accumulator))
    Ok(value) -> {
      use reflected <- result.try(message_pack_value_to_reflected(value))
      extract_constructor_fields(entries, index + 1, [reflected, ..accumulator])
    }
  }
}

fn lookup_string_key(
  entries: List(#(Value, Value)),
  key: String,
) -> Result(Value, Nil) {
  case entries {
    [] -> Error(Nil)
    [#(ValueString(k), v), ..] if k == key -> Ok(v)
    [_, ..rest] -> lookup_string_key(rest, key)
  }
}
