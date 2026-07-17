//// The codec of the auto-serialiser that turns any Gleam value into wire
//// bytes and back without needing a codec, by walking the target-neutral
//// [`Reflected`](./reflection.html) tree that reflection hands it. Both wire
//// formats ride the same walk, MessagePack on one side and JSON on the other,
//// so they can't drift into disagreeing about how a value is shaped.
////
//// The shape is simple. A custom type is a map tagged by its constructor name
//// under `"_"`, with positional fields under `"0"`, `"1"`, and so on. A tuple
//// is the same map without the tag. Dicts and sets get the reserved tags
//// `"$dict"` and `"$set"`. This is what the old Erlang and JS FFI codecs
//// emitted too, so nothing on the wire changed when the codec moved into
//// Gleam.

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option
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

/// Decode a JSON `Dynamic` (from `json.parse`) back to a Gleam value. Comes out
/// as `Dynamic` because the call site in transport.gleam pins the concrete type.
@internal
pub fn decode_json(value: Dynamic) -> Result(Dynamic, Nil) {
  use reflected <- result.try(json_to_reflected(value))
  reflection.construct(reflected)
}

/// Encode a Gleam value to a JSON value via reflection.
@internal
pub fn encode_json(value: a) -> Json {
  reflection.reflect(value)
  |> reflected_to_json
}

/// Encode a Gleam value to MessagePack bytes via reflection.
@internal
pub fn encode_message_pack(value: a) -> BitArray {
  reflection.reflect(value)
  |> reflected_to_message_pack
}

/// Decode MessagePack bytes back to a Gleam value, capping nesting at
/// [`message_pack.default_max_depth`](./message_pack.html#default_max_depth).
@internal
pub fn decode_message_pack(bytes: BitArray) -> Result(Dynamic, Nil) {
  decode_message_pack_bounded(bytes, message_pack.default_max_depth)
}

/// Like [`decode_message_pack`](#decode_message_pack) but with a caller-chosen
/// nesting cap, used by the server to bound decoding of untrusted frames.
@internal
pub fn decode_message_pack_bounded(
  bytes: BitArray,
  max_depth: Int,
) -> Result(Dynamic, Nil) {
  use #(message_pack_value, _) <- result.try(message_pack.decode_bounded(
    bytes,
    max_depth,
  ))
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
      // Tag-less map with positional keys. No `_` tells the decoder this is a
      // tuple, not a named constructor.
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
      // Tagged sentinel `{"_":"$dict","0":[[k,v],...]}`. Each pair is a
      // 2-element array so non-string keys round-trip.
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
      // Positional fields first, name tag last, byte-for-byte what the old FFI
      // codecs emitted. Zero-field constructors are just the tag.
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
    // envelope wraps payload bytes that way, treat it as a nested decode.
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
  // Three shapes reach here. A `_`-tagged custom type (the normal case), a
  // tag-less map with numeric keys (a raw tuple), or the `$dict`/`$set`
  // sentinels for collections.
  case extract_constructor_name(entries) {
    Ok("$dict") -> decode_dict(entries)
    Ok("$set") -> decode_set(entries)
    Ok(name) -> {
      use fields <- result.try(extract_constructor_fields(entries, 0, []))
      Ok(ReflectedConstructor(name:, fields:))
    }
    Error(_) -> {
      // No `_` tag, so it's a raw tuple.
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

fn reflected_to_json(reflected: Reflected) -> Json {
  case reflected {
    ReflectedNil -> json.null()
    ReflectedBool(value) -> json.bool(value)
    ReflectedInteger(value) -> json.int(value)
    ReflectedFloat(value) -> json.float(value)
    ReflectedString(value) -> json.string(value)
    ReflectedList(items) ->
      json.preprocessed_array(list.map(items, reflected_to_json))
    ReflectedTuple(fields:) -> json.object(indexed_fields_json(fields))
    ReflectedDict(entries:) ->
      json.object([
        #("_", json.string("$dict")),
        #(
          "0",
          json.preprocessed_array(
            list.map(entries, fn(entry) {
              let #(k, v) = entry
              json.preprocessed_array([
                reflected_to_json(k),
                reflected_to_json(v),
              ])
            }),
          ),
        ),
      ])
    ReflectedSet(members:) ->
      json.object([
        #("_", json.string("$set")),
        #("0", json.preprocessed_array(list.map(members, reflected_to_json))),
      ])
    ReflectedConstructor(name:, fields:) ->
      json.object([#("_", json.string(name)), ..indexed_fields_json(fields)])
  }
}

fn indexed_fields_json(fields: List(Reflected)) -> List(#(String, Json)) {
  list.index_map(fields, fn(field, index) {
    #(int.to_string(index), reflected_to_json(field))
  })
}

// The mirror of reflected_to_json. Classifies a parsed JSON `Dynamic` into a
// Reflected node so reflection.construct can rebuild the value, the same way
// message_pack_value_to_reflected feeds the MessagePack path. Objects are
// tried before lists before scalars, and a bare null lands last as Nil.
fn json_to_reflected(value: Dynamic) -> Result(Reflected, Nil) {
  case run_decoder(value, decode.dict(decode.string, decode.dynamic)) {
    Ok(fields) -> json_object_to_reflected(fields)
    Error(_) ->
      case run_decoder(value, decode.list(decode.dynamic)) {
        Ok(items) -> {
          use reflected <- result.try(list.try_map(items, json_to_reflected))
          Ok(ReflectedList(reflected))
        }
        Error(_) -> json_scalar_to_reflected(value)
      }
  }
}

fn json_object_to_reflected(
  fields: Dict(String, Dynamic),
) -> Result(Reflected, Nil) {
  case dict.get(fields, "_") {
    Ok(tag_value) -> {
      use tag <- result.try(run_decoder(tag_value, decode.string))
      case tag {
        "$dict" -> json_dict_to_reflected(fields)
        "$set" -> json_set_to_reflected(fields)
        _ -> {
          use positional <- result.try(json_indexed_fields(fields))
          Ok(ReflectedConstructor(name: tag, fields: positional))
        }
      }
    }
    Error(_) -> {
      use positional <- result.try(json_indexed_fields(fields))
      case positional {
        [] -> Error(Nil)
        _ -> Ok(ReflectedTuple(fields: positional))
      }
    }
  }
}

fn json_indexed_fields(
  fields: Dict(String, Dynamic),
) -> Result(List(Reflected), Nil) {
  json_indexed_loop(fields, 0, [])
}

fn json_indexed_loop(
  fields: Dict(String, Dynamic),
  index: Int,
  accumulator: List(Reflected),
) -> Result(List(Reflected), Nil) {
  case dict.get(fields, int.to_string(index)) {
    Error(_) -> Ok(list.reverse(accumulator))
    Ok(value) -> {
      use reflected <- result.try(json_to_reflected(value))
      json_indexed_loop(fields, index + 1, [reflected, ..accumulator])
    }
  }
}

fn json_dict_to_reflected(
  fields: Dict(String, Dynamic),
) -> Result(Reflected, Nil) {
  use zero <- result.try(dict.get(fields, "0"))
  use pairs <- result.try(run_decoder(zero, decode.list(decode.dynamic)))
  use entries <- result.try(
    list.try_map(pairs, fn(pair_value) {
      use pair <- result.try(run_decoder(
        pair_value,
        decode.list(decode.dynamic),
      ))
      case pair {
        [key_value, value_value] -> {
          use key <- result.try(json_to_reflected(key_value))
          use value <- result.try(json_to_reflected(value_value))
          Ok(#(key, value))
        }
        _ -> Error(Nil)
      }
    }),
  )
  Ok(ReflectedDict(entries:))
}

fn json_set_to_reflected(
  fields: Dict(String, Dynamic),
) -> Result(Reflected, Nil) {
  use zero <- result.try(dict.get(fields, "0"))
  use members <- result.try(run_decoder(zero, decode.list(decode.dynamic)))
  use reflected <- result.try(list.try_map(members, json_to_reflected))
  Ok(ReflectedSet(members: reflected))
}

fn json_scalar_to_reflected(value: Dynamic) -> Result(Reflected, Nil) {
  case run_decoder(value, decode.bool) {
    Ok(bool_value) -> Ok(ReflectedBool(bool_value))
    Error(_) ->
      case run_decoder(value, decode.string) {
        Ok(string_value) -> Ok(ReflectedString(string_value))
        Error(_) ->
          case run_decoder(value, decode.int) {
            Ok(int_value) -> Ok(ReflectedInteger(int_value))
            Error(_) ->
              case run_decoder(value, decode.float) {
                Ok(float_value) -> Ok(ReflectedFloat(float_value))
                Error(_) ->
                  // Everything concrete failed, so a bare JSON null is all
                  // that is left. Anything else is genuinely undecodable.
                  case run_decoder(value, decode.optional(decode.bool)) {
                    Ok(option.None) -> Ok(ReflectedNil)
                    _ -> Error(Nil)
                  }
              }
          }
      }
  }
}

fn run_decoder(value: Dynamic, decoder: decode.Decoder(a)) -> Result(a, Nil) {
  decode.run(value, decoder)
  |> result.replace_error(Nil)
}
