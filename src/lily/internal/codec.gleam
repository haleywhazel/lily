//// Automatic MessagePack and JSON codec via a [`Reflected`](#Reflected) tree.
//// On JavaScript a type only decodes once its module is registered through
//// [`request_module`](#request_module). Data messages also decode any type
//// this page encoded, frames don't.

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option
import gleam/result
import gleam/string

// =============================================================================
// INTERNAL TYPES
// =============================================================================

@internal
pub type MessagePackValue {
  ValueNil
  ValueBool(Bool)
  ValueInteger(Int)
  ValueFloat(Float)
  ValueString(String)
  ValueBytes(BitArray)
  ValueArray(List(MessagePackValue))
  ValueMap(List(#(MessagePackValue, MessagePackValue)))
}

/// Dicts and sets go on the wire as reserved `$dict`/`$set` constructors.
@internal
pub type Reflected {
  ReflectedNil
  ReflectedBool(Bool)
  ReflectedInteger(Int)
  ReflectedFloat(Float)
  ReflectedString(String)
  ReflectedList(List(Reflected))
  ReflectedTuple(fields: List(Reflected))
  ReflectedDict(entries: List(#(Reflected, Reflected)))
  ReflectedSet(members: List(Reflected))
  ReflectedConstructor(name: String, fields: List(Reflected))
}

// =============================================================================
// INTERNAL FUNCTIONS
// =============================================================================

// stops hostile nesting exhausting the stack
@internal
pub const default_max_depth = 128

@internal
pub fn decode_bounded(
  bytes: BitArray,
  max_depth: Int,
) -> Result(#(MessagePackValue, BitArray), Nil) {
  decode_at(bytes, 0, max_depth)
}

@internal
pub fn decode_data_message(encoded: String) -> Result(message, Nil) {
  case string.starts_with(encoded, data_message_prefix) {
    False -> Error(Nil)
    True -> {
      let payload =
        string.drop_start(encoded, string.length(data_message_prefix))
      use bytes <- result.try(bit_array.base64_decode(payload))
      use #(value, _) <- result.try(decode_bounded(bytes, default_max_depth))
      use reflected <- result.try(message_pack_value_to_reflected(
        value,
        default_max_depth,
      ))
      use message <- result.try(construct_data_message(reflected))
      Ok(passthrough(message))
    }
  }
}

@internal
pub fn decode_json(
  value: Dynamic,
  max_depth: Int,
  conform: fn(Reflected) -> Result(Reflected, Nil),
) -> Result(Dynamic, Nil) {
  use reflected <- result.try(json_to_reflected(value, max_depth))
  use reflected <- result.try(conform(reflected))
  construct(reflected)
}

@internal
pub fn decode_message_pack(
  bytes: BitArray,
  max_depth: Int,
  conform: fn(Reflected) -> Result(Reflected, Nil),
) -> Result(Dynamic, Nil) {
  use #(message_pack_value, _) <- result.try(decode_bounded(bytes, max_depth))
  use reflected <- result.try(message_pack_value_to_reflected(
    message_pack_value,
    max_depth,
  ))
  use reflected <- result.try(conform(reflected))
  construct(reflected)
}

@internal
pub fn encode_array(items: List(BitArray)) -> BitArray {
  // single concat, folding is quadratic
  bit_array.concat([array_header(list.length(items)), ..items])
}

@internal
pub fn encode_bin(bytes: BitArray) -> BitArray {
  case bit_array.byte_size(bytes) {
    length if length <= 0xff -> bit_array.concat([<<0xc4, length>>, bytes])
    length if length <= 0xffff ->
      bit_array.concat([<<0xc5, length:16-big>>, bytes])
    length -> bit_array.concat([<<0xc6, length:32-big>>, bytes])
  }
}

@internal
pub fn encode_data_message(message: a) -> String {
  let bytes =
    reflect_data_message(message)
    |> reflected_to_message_pack
  data_message_prefix <> bit_array.base64_encode(bytes, False)
}

@internal
pub fn encode_int(value: Int) -> BitArray {
  case value {
    _ if value >= 0 && value <= 0x7f -> <<value>>
    _ if value >= 0 && value <= 0xff -> <<0xcc, value>>
    _ if value >= 0 && value <= 0xffff -> <<0xcd, value:16-big>>
    _ if value >= 0 && value <= 0xffffffff -> <<0xce, value:32-big>>
    _ if value >= 0 -> bit_array.concat([<<0xcf>>, unsigned_to_bytes(value, 8)])
    // two's complement, adding 2^N then truncating to N bits
    _ if value >= -32 -> <<{ 0x100 + value }:8>>
    _ if value >= -128 -> <<0xd0, { 0x100 + value }:8>>
    _ if value >= -32_768 -> <<0xd1, { 0x10000 + value }:16-big>>
    _ if value >= -2_147_483_648 -> <<0xd2, { 0x100000000 + value }:32-big>>
    // int arithmetic, the JS target narrows 64-bit segments to 52 bits
    _ -> bit_array.concat([<<0xd3>>, signed_to_bytes(value, 8)])
  }
}

@internal
pub fn encode_json(value: a) -> Json {
  reflect(value)
  |> reflected_to_json
}

@internal
pub fn encode_map(entries: List(#(BitArray, BitArray))) -> BitArray {
  // flatten and concat once, folding recopies per entry, going quadratic
  let body = list.flat_map(entries, fn(entry) { [entry.0, entry.1] })
  bit_array.concat([map_header(list.length(entries)), ..body])
}

@internal
pub fn encode_message_pack(value: a) -> BitArray {
  reflect(value)
  |> reflected_to_message_pack
}

@internal
pub fn encode_string(value: String) -> BitArray {
  let bytes = bit_array.from_string(value)
  case bit_array.byte_size(bytes) {
    length if length <= 31 -> bit_array.concat([<<{ 0xa0 + length }:8>>, bytes])
    length if length <= 0xff -> bit_array.concat([<<0xd9, length>>, bytes])
    length if length <= 0xffff ->
      bit_array.concat([<<0xda, length:16-big>>, bytes])
    length -> bit_array.concat([<<0xdb, length:32-big>>, bytes])
  }
}

@internal
pub fn lookup_string_key(
  entries: List(#(MessagePackValue, MessagePackValue)),
  key: String,
) -> Result(MessagePackValue, Nil) {
  case entries {
    [] -> Error(Nil)
    [#(ValueString(name), value), ..] if name == key -> Ok(value)
    [_, ..rest] -> lookup_string_key(rest, key)
  }
}

/// Unchecked cast. Only sound when the value really is a `b`.
@external(erlang, "lily_codec_ffi", "passthrough")
@external(javascript, "./codec.ffi.mjs", "passthrough")
@internal
pub fn passthrough(value: a) -> b

/// No-op on Erlang and for an already requested module.
@external(javascript, "./codec.ffi.mjs", "requestModule")
@internal
pub fn request_module(package: String, path: String) -> Nil {
  let _ = package
  let _ = path
  Nil
}

@external(javascript, "./codec.ffi.mjs", "whenRegistered")
@internal
pub fn when_registered(thunk: fn() -> Nil) -> Nil {
  thunk()
}

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

const data_message_prefix = "lily-message:"

fn array_header(length: Int) -> BitArray {
  case length {
    length if length <= 15 -> <<{ 0x90 + length }:8>>
    length if length <= 0xffff -> <<0xdc, length:16-big>>
    length -> <<0xdd, length:32-big>>
  }
}

// at most eight bytes, plain recursion is fine
fn byte_list(bytes: BitArray) -> List(Int) {
  case bytes {
    <<byte, rest:bytes>> -> [byte, ..byte_list(rest)]
    _ -> []
  }
}

fn bytes_from_byte_list(bytes: List(Int)) -> BitArray {
  list.fold(bytes, <<>>, fn(accumulator, byte) {
    <<accumulator:bits, { byte }:8>>
  })
}

fn collect_indexed(
  index: Dict(String, value),
  number: Int,
  accumulator: List(Reflected),
  convert: fn(value) -> Result(Reflected, Nil),
) -> Result(List(Reflected), Nil) {
  // stop at the first missing key so both formats agree on field count
  case dict.get(index, int.to_string(number)) {
    Error(_) -> Ok(list.reverse(accumulator))
    Ok(value) -> {
      use reflected <- result.try(convert(value))
      collect_indexed(index, number + 1, [reflected, ..accumulator], convert)
    }
  }
}

fn decode_array(
  bytes: BitArray,
  remaining: Int,
  accumulator: List(MessagePackValue),
  depth: Int,
  max_depth: Int,
) -> Result(#(MessagePackValue, BitArray), Nil) {
  case remaining {
    0 -> Ok(#(ValueArray(list.reverse(accumulator)), bytes))
    _ ->
      case decode_at(bytes, depth, max_depth) {
        Error(_) -> Error(Nil)
        Ok(#(item, rest)) ->
          decode_array(
            rest,
            remaining - 1,
            [item, ..accumulator],
            depth,
            max_depth,
          )
      }
  }
}

fn decode_at(
  bytes: BitArray,
  depth: Int,
  max_depth: Int,
) -> Result(#(MessagePackValue, BitArray), Nil) {
  use <- bool.guard(when: depth > max_depth, return: Error(Nil))
  case bytes {
    <<0xc0, rest:bytes>> -> Ok(#(ValueNil, rest))
    <<0xc2, rest:bytes>> -> Ok(#(ValueBool(False), rest))
    <<0xc3, rest:bytes>> -> Ok(#(ValueBool(True), rest))

    // positive fixint (0x00, 0x7f)
    <<value, rest:bytes>> if value <= 0x7f -> Ok(#(ValueInteger(value), rest))
    // negative fixint (0xe0, 0xff)
    <<value, rest:bytes>> if value >= 0xe0 ->
      Ok(#(ValueInteger(value - 256), rest))

    // unsigned ints
    <<0xcc, value, rest:bytes>> -> Ok(#(ValueInteger(value), rest))
    <<0xcd, value:16-big, rest:bytes>> -> Ok(#(ValueInteger(value), rest))
    <<0xce, value:32-big, rest:bytes>> -> Ok(#(ValueInteger(value), rest))
    <<0xcf, raw:bytes-size(8), rest:bytes>> ->
      Ok(#(ValueInteger(unsigned_from_bytes(raw)), rest))

    // signed ints
    <<0xd0, value:8-signed, rest:bytes>> -> Ok(#(ValueInteger(value), rest))
    <<0xd1, value:16-signed-big, rest:bytes>> ->
      Ok(#(ValueInteger(value), rest))
    <<0xd2, value:32-signed-big, rest:bytes>> ->
      Ok(#(ValueInteger(value), rest))
    <<0xd3, raw:bytes-size(8), rest:bytes>> ->
      Ok(#(ValueInteger(signed_from_bytes(raw)), rest))

    // floats
    <<0xcb, value:64-float-big, rest:bytes>> -> Ok(#(ValueFloat(value), rest))
    <<0xca, value:32-float-big, rest:bytes>> -> Ok(#(ValueFloat(value), rest))

    // fixstr (0xa0, 0xbf)
    <<byte, rest:bytes>> if byte >= 0xa0 && byte <= 0xbf -> {
      let length = byte - 0xa0
      decode_string(rest, length)
    }
    <<0xd9, length, rest:bytes>> -> decode_string(rest, length)
    <<0xda, length:16-big, rest:bytes>> -> decode_string(rest, length)
    <<0xdb, length:32-big, rest:bytes>> -> decode_string(rest, length)

    // bin
    <<0xc4, length, rest:bytes>> -> decode_bin(rest, length)
    <<0xc5, length:16-big, rest:bytes>> -> decode_bin(rest, length)
    <<0xc6, length:32-big, rest:bytes>> -> decode_bin(rest, length)

    // fixarray (0x90, 0x9f)
    <<byte, rest:bytes>> if byte >= 0x90 && byte <= 0x9f ->
      decode_array(rest, byte - 0x90, [], depth + 1, max_depth)
    <<0xdc, length:16-big, rest:bytes>> ->
      decode_array(rest, length, [], depth + 1, max_depth)
    <<0xdd, length:32-big, rest:bytes>> ->
      decode_array(rest, length, [], depth + 1, max_depth)

    // fixmap (0x80, 0x8f)
    <<byte, rest:bytes>> if byte >= 0x80 && byte <= 0x8f ->
      decode_map(rest, byte - 0x80, [], depth + 1, max_depth)
    <<0xde, length:16-big, rest:bytes>> ->
      decode_map(rest, length, [], depth + 1, max_depth)
    <<0xdf, length:32-big, rest:bytes>> ->
      decode_map(rest, length, [], depth + 1, max_depth)

    _ -> Error(Nil)
  }
}

fn decode_bin(
  bytes: BitArray,
  length: Int,
) -> Result(#(MessagePackValue, BitArray), Nil) {
  case bytes {
    <<taken:bytes-size(length), rest:bytes>> -> Ok(#(ValueBytes(taken), rest))
    _ -> Error(Nil)
  }
}

fn decode_map(
  bytes: BitArray,
  remaining: Int,
  accumulator: List(#(MessagePackValue, MessagePackValue)),
  depth: Int,
  max_depth: Int,
) -> Result(#(MessagePackValue, BitArray), Nil) {
  case remaining {
    0 -> Ok(#(ValueMap(list.reverse(accumulator)), bytes))
    _ ->
      case decode_at(bytes, depth, max_depth) {
        Error(_) -> Error(Nil)
        Ok(#(key, after_key)) ->
          case decode_at(after_key, depth, max_depth) {
            Error(_) -> Error(Nil)
            Ok(#(value, after_value)) ->
              decode_map(
                after_value,
                remaining - 1,
                [#(key, value), ..accumulator],
                depth,
                max_depth,
              )
          }
      }
  }
}

fn decode_string(
  bytes: BitArray,
  length: Int,
) -> Result(#(MessagePackValue, BitArray), Nil) {
  // too few bytes fails the pattern and falls through to Error
  case bytes {
    <<taken:bytes-size(length), rest:bytes>> ->
      case bit_array.to_string(taken) {
        Error(_) -> Error(Nil)
        Ok(text) -> Ok(#(ValueString(text), rest))
      }
    _ -> Error(Nil)
  }
}

fn dict_pair_to_reflected(
  pair: MessagePackValue,
  max_depth: Int,
) -> Result(#(Reflected, Reflected), Nil) {
  case pair {
    ValueArray([key_value, value_value]) -> {
      use key <- result.try(message_pack_value_to_reflected(
        key_value,
        max_depth,
      ))
      use value <- result.try(message_pack_value_to_reflected(
        value_value,
        max_depth,
      ))
      Ok(#(key, value))
    }
    _ -> Error(Nil)
  }
}

fn dict_to_reflected(
  entries: List(#(MessagePackValue, MessagePackValue)),
  max_depth: Int,
) -> Result(Reflected, Nil) {
  use pairs_value <- result.try(lookup_string_key(entries, "0"))
  case pairs_value {
    ValueArray(pair_values) -> {
      use pair_reflected_list <- result.try(
        list.try_map(pair_values, fn(pair) {
          dict_pair_to_reflected(pair, max_depth)
        }),
      )
      Ok(ReflectedDict(entries: pair_reflected_list))
    }
    _ -> Error(Nil)
  }
}

fn encode_bool(value: Bool) -> BitArray {
  case value {
    True -> <<0xc3>>
    False -> <<0xc2>>
  }
}

fn encode_float(value: Float) -> BitArray {
  <<0xcb, value:64-float-big>>
}

fn encode_nil() -> BitArray {
  <<0xc0>>
}

fn extract_constructor_name(
  index: Dict(String, MessagePackValue),
) -> Result(String, Nil) {
  case dict.get(index, "_") {
    Ok(ValueString(name)) -> Ok(name)
    _ -> Error(Nil)
  }
}

fn index_entries(
  entries: List(#(MessagePackValue, MessagePackValue)),
) -> Dict(String, MessagePackValue) {
  // dict once, O(1) lookups instead of rescanning per field
  list.fold(entries, dict.new(), fn(index, entry) {
    case entry {
      #(ValueString(key), value) -> dict.insert(index, key, value)
      _ -> index
    }
  })
}

fn indexed_fields_json(fields: List(Reflected)) -> List(#(String, Json)) {
  list.index_map(fields, fn(field, index) {
    #(int.to_string(index), reflected_to_json(field))
  })
}

fn indexed_fields_message_pack(
  fields: List(Reflected),
) -> List(#(BitArray, BitArray)) {
  list.index_map(fields, fn(field, index) {
    #(encode_string(int.to_string(index)), reflected_to_message_pack(field))
  })
}

fn json_dict_to_reflected(
  fields: Dict(String, Dynamic),
  remaining: Int,
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
          use key <- result.try(json_to_reflected(key_value, remaining))
          use value <- result.try(json_to_reflected(value_value, remaining))
          Ok(#(key, value))
        }
        _ -> Error(Nil)
      }
    }),
  )
  Ok(ReflectedDict(entries:))
}

fn json_object_to_reflected(
  fields: Dict(String, Dynamic),
  remaining: Int,
) -> Result(Reflected, Nil) {
  let convert = json_to_reflected(_, remaining)
  case dict.get(fields, "_") {
    Ok(tag_value) -> {
      use tag <- result.try(run_decoder(tag_value, decode.string))
      case tag {
        "$dict" -> json_dict_to_reflected(fields, remaining)
        "$set" -> json_set_to_reflected(fields, remaining)
        _ ->
          collect_indexed(fields, 0, [], convert)
          |> result.map(ReflectedConstructor(name: tag, fields: _))
      }
    }
    Error(_) ->
      case collect_indexed(fields, 0, [], convert) {
        Ok([]) | Error(_) -> Error(Nil)
        Ok(positional) -> Ok(ReflectedTuple(fields: positional))
      }
  }
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
                  // only a bare JSON null is left
                  case run_decoder(value, decode.optional(decode.bool)) {
                    Ok(option.None) -> Ok(ReflectedNil)
                    _ -> Error(Nil)
                  }
              }
          }
      }
  }
}

fn json_set_to_reflected(
  fields: Dict(String, Dynamic),
  remaining: Int,
) -> Result(Reflected, Nil) {
  use zero <- result.try(dict.get(fields, "0"))
  use members <- result.try(run_decoder(zero, decode.list(decode.dynamic)))
  use reflected <- result.try(
    list.try_map(members, json_to_reflected(_, remaining)),
  )
  Ok(ReflectedSet(members: reflected))
}

// hostile nesting would exhaust the stack
fn json_to_reflected(value: Dynamic, remaining: Int) -> Result(Reflected, Nil) {
  use <- bool.guard(when: remaining < 0, return: Error(Nil))
  case run_decoder(value, decode.dict(decode.string, decode.dynamic)) {
    Ok(fields) -> json_object_to_reflected(fields, remaining - 1)
    Error(_) ->
      case run_decoder(value, decode.list(decode.dynamic)) {
        Ok(items) -> {
          use reflected <- result.try(
            list.try_map(items, json_to_reflected(_, remaining - 1)),
          )
          Ok(ReflectedList(reflected))
        }
        Error(_) -> json_scalar_to_reflected(value)
      }
  }
}

fn map_header(length: Int) -> BitArray {
  case length {
    length if length <= 15 -> <<{ 0x80 + length }:8>>
    length if length <= 0xffff -> <<0xde, length:16-big>>
    length -> <<0xdf, length:32-big>>
  }
}

fn map_to_reflected(
  entries: List(#(MessagePackValue, MessagePackValue)),
  max_depth: Int,
) -> Result(Reflected, Nil) {
  // `_`-tagged custom type, tag-less tuple, or `$dict`/`$set` sentinel
  let index = index_entries(entries)
  let fields = fn() {
    collect_indexed(index, 0, [], fn(value) {
      message_pack_value_to_reflected(value, max_depth)
    })
  }
  case extract_constructor_name(index) {
    Ok("$dict") -> dict_to_reflected(entries, max_depth)
    Ok("$set") -> set_to_reflected(entries, max_depth)
    Ok(name) -> result.map(fields(), ReflectedConstructor(name:, fields: _))
    // no `_` tag, a raw tuple
    Error(_) ->
      case fields() {
        Ok([]) | Error(_) -> Error(Nil)
        Ok(fields) -> Ok(ReflectedTuple(fields:))
      }
  }
}

fn message_pack_value_to_reflected(
  value: MessagePackValue,
  max_depth: Int,
) -> Result(Reflected, Nil) {
  case value {
    ValueNil -> Ok(ReflectedNil)
    ValueBool(value) -> Ok(ReflectedBool(value))
    ValueInteger(value) -> Ok(ReflectedInteger(value))
    ValueFloat(value) -> Ok(ReflectedFloat(value))
    ValueString(value) -> Ok(ReflectedString(value))
    // never emitted, and a nested bin would reset the depth budget
    ValueBytes(_) -> Error(Nil)
    ValueArray(items) -> {
      use reflected_items <- result.try(
        list.try_map(items, fn(item) {
          message_pack_value_to_reflected(item, max_depth)
        }),
      )
      Ok(ReflectedList(reflected_items))
    }
    ValueMap(entries) -> map_to_reflected(entries, max_depth)
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
              let #(key, value) = entry
              json.preprocessed_array([
                reflected_to_json(key),
                reflected_to_json(value),
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

fn reflected_to_message_pack(reflected: Reflected) -> BitArray {
  case reflected {
    ReflectedNil -> encode_nil()
    ReflectedBool(value) -> encode_bool(value)
    ReflectedInteger(value) -> encode_int(value)
    ReflectedFloat(value) -> encode_float(value)
    ReflectedString(value) -> encode_string(value)
    ReflectedList(items) ->
      list.map(items, reflected_to_message_pack)
      |> encode_array
    // tag-less positional map, no `_` marks a tuple
    ReflectedTuple(fields:) -> encode_map(indexed_fields_message_pack(fields))
    ReflectedDict(entries:) -> {
      // `{"_":"$dict","0":[[k,v],...]}`, pairs so non-string keys round-trip
      let pairs =
        list.map(entries, fn(entry) {
          let #(key, value) = entry
          encode_array([
            reflected_to_message_pack(key),
            reflected_to_message_pack(value),
          ])
        })
      encode_map([
        #(encode_string("0"), encode_array(pairs)),
        #(encode_string("_"), encode_string("$dict")),
      ])
    }
    ReflectedSet(members:) -> {
      let encoded_members = list.map(members, reflected_to_message_pack)
      encode_map([
        #(encode_string("0"), encode_array(encoded_members)),
        #(encode_string("_"), encode_string("$set")),
      ])
    }
    // positional fields first, name tag last
    ReflectedConstructor(name:, fields:) -> {
      let tag_entry = #(encode_string("_"), encode_string(name))
      encode_map(list.append(indexed_fields_message_pack(fields), [tag_entry]))
    }
  }
}

fn run_decoder(value: Dynamic, decoder: decode.Decoder(a)) -> Result(a, Nil) {
  decode.run(value, decoder)
  |> result.replace_error(Nil)
}

fn set_to_reflected(
  entries: List(#(MessagePackValue, MessagePackValue)),
  max_depth: Int,
) -> Result(Reflected, Nil) {
  use members_value <- result.try(lookup_string_key(entries, "0"))
  case members_value {
    ValueArray(member_values) -> {
      use members <- result.try(
        list.try_map(member_values, fn(member) {
          message_pack_value_to_reflected(member, max_depth)
        }),
      )
      Ok(ReflectedSet(members:))
    }
    _ -> Error(Nil)
  }
}

// magnitude via complement, never forms 2^64 which JS can't hold exactly
fn signed_from_bytes(bytes: BitArray) -> Int {
  case byte_list(bytes) {
    [first, ..] if first >= 0x80 ->
      0 - unsigned_from_bytes(twos_complement(bytes))
    _ -> unsigned_from_bytes(bytes)
  }
}

fn signed_to_bytes(value: Int, count: Int) -> BitArray {
  case value >= 0 {
    True -> unsigned_to_bytes(value, count)
    False -> twos_complement(unsigned_to_bytes(0 - value, count))
  }
}

// byte by byte so no intermediate exceeds a byte
fn twos_complement(bytes: BitArray) -> BitArray {
  let inverted_low_first =
    bytes
    |> byte_list
    |> list.reverse
    |> list.map(fn(byte) { 255 - byte })
  let #(_carry, low_first) =
    list.map_fold(inverted_low_first, 1, fn(carry, byte) {
      let sum = byte + carry
      #(sum / 256, sum % 256)
    })
  low_first |> list.reverse |> bytes_from_byte_list
}

fn unsigned_from_bytes(bytes: BitArray) -> Int {
  byte_list(bytes)
  |> list.fold(0, fn(accumulator, byte) { accumulator * 256 + byte })
}

fn unsigned_to_bytes(value: Int, count: Int) -> BitArray {
  unsigned_to_bytes_loop(value, count, <<>>)
}

fn unsigned_to_bytes_loop(
  value: Int,
  remaining: Int,
  accumulator: BitArray,
) -> BitArray {
  case remaining <= 0 {
    True -> accumulator
    False ->
      unsigned_to_bytes_loop(value / 256, remaining - 1, <<
        { value % 256 }:8,
        accumulator:bits,
      >>)
  }
}

// =============================================================================
// PRIVATE FFI
// =============================================================================

// `Error(Nil)` on JS for an unregistered constructor
@external(erlang, "lily_codec_ffi", "construct")
@external(javascript, "./codec.ffi.mjs", "construct")
fn construct(reflected: Reflected) -> Result(Dynamic, Nil)

// falls back to classes this page encoded, never use it for frames
@external(erlang, "lily_codec_ffi", "construct")
@external(javascript, "./codec.ffi.mjs", "constructDataMessage")
fn construct_data_message(reflected: Reflected) -> Result(Dynamic, Nil)

@external(erlang, "lily_codec_ffi", "reflect")
@external(javascript, "./codec.ffi.mjs", "reflect")
fn reflect(value: a) -> Reflected

// also records the classes for construct_data_message on JS
@external(erlang, "lily_codec_ffi", "reflect")
@external(javascript, "./codec.ffi.mjs", "reflectDataMessage")
fn reflect_data_message(value: a) -> Reflected
