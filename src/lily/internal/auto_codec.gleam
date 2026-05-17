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
  type Reflected, ReflectedBool, ReflectedConstructor, ReflectedDict,
  ReflectedFloat, ReflectedInteger, ReflectedList, ReflectedNil, ReflectedSet,
  ReflectedString, ReflectedTuple,
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
    ReflectedTuple(fields:) -> {
      // Tag-less map with positional keys. The absence of "_" is what
      // tells the decoder to rebuild a tuple rather than look the name
      // up in the constructor registry.
      let field_entries =
        list.index_map(fields, fn(field, index) {
          #(
            message_pack.encode_string(int.to_string(index)),
            reflected_to_message_pack(field),
          )
        })
      message_pack.encode_map(field_entries)
    }
    ReflectedDict(entries:) -> {
      // Encode as a tagged sentinel `{"_":"$dict","0":[[k,v],...]}`
      // matching the JSON path. Each pair becomes a 2-element array so
      // non-string keys round-trip.
      let pairs =
        list.map(entries, fn(entry) {
          let #(k, v) = entry
          message_pack.encode_array([
            reflected_to_message_pack(k),
            reflected_to_message_pack(v),
          ])
        })
      message_pack.encode_map([
        #(message_pack.encode_string("0"), message_pack.encode_array(pairs)),
        #(message_pack.encode_string("_"), message_pack.encode_string("$dict")),
      ])
    }
    ReflectedSet(members:) -> {
      let encoded_members = list.map(members, reflected_to_message_pack)
      message_pack.encode_map([
        #(
          message_pack.encode_string("0"),
          message_pack.encode_array(encoded_members),
        ),
        #(message_pack.encode_string("_"), message_pack.encode_string("$set")),
      ])
    }
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
  // Maps in the auto-format are one of:
  //   1. Custom-type maps with a `_` tag (the normal case)
  //   2. Tag-less maps with numeric keys (raw Gleam tuples)
  //   3. Special-cased `_:"$dict"` or `_:"$set"` (collection types)
  case extract_constructor_name(entries) {
    Ok("$dict") -> decode_dict(entries)
    Ok("$set") -> decode_set(entries)
    Ok(name) -> {
      use fields <- result.try(extract_constructor_fields(entries, 0, []))
      Ok(ReflectedConstructor(name:, fields:))
    }
    Error(_) -> {
      // No `_` tag, so this must be a raw tuple. Pull the positional
      // fields and reconstruct as ReflectedTuple.
      use fields <- result.try(extract_constructor_fields(entries, 0, []))
      case fields {
        [] -> Error(Nil)
        _ -> Ok(ReflectedTuple(fields:))
      }
    }
  }
}

fn decode_dict(entries: List(#(Value, Value))) -> Result(Reflected, Nil) {
  use pairs_value <- result.try(lookup_string_key(entries, "0"))
  case pairs_value {
    ValueArray(pair_values) -> {
      use pair_reflected_list <- result.try(list.try_map(
        pair_values,
        decode_dict_pair,
      ))
      Ok(ReflectedDict(entries: pair_reflected_list))
    }
    _ -> Error(Nil)
  }
}

fn decode_dict_pair(pair: Value) -> Result(#(Reflected, Reflected), Nil) {
  case pair {
    ValueArray([k_value, v_value]) -> {
      use k <- result.try(message_pack_value_to_reflected(k_value))
      use v <- result.try(message_pack_value_to_reflected(v_value))
      Ok(#(k, v))
    }
    _ -> Error(Nil)
  }
}

fn decode_set(entries: List(#(Value, Value))) -> Result(Reflected, Nil) {
  use members_value <- result.try(lookup_string_key(entries, "0"))
  case members_value {
    ValueArray(member_values) -> {
      use members <- result.try(list.try_map(
        member_values,
        message_pack_value_to_reflected,
      ))
      Ok(ReflectedSet(members:))
    }
    _ -> Error(Nil)
  }
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
