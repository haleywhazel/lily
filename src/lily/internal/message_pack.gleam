//// The byte-level half of the MessagePack wire format, encode on one side and
//// decode on the other. It only knows about primitive MessagePack types, the
//// nil byte, bools, the various int and float widths, strings, binaries,
//// arrays, and maps. Turning an actual Gleam value into those primitives is
//// [`auto_codec`](./auto_codec.html)'s job, and the runtime introspection that
//// feeds it is [`reflection`](./reflection.html)'s.
////
//// It lives here in pure Gleam so both targets share one source of truth for
//// the format, replacing the two hand-written codec FFIs that used to drift
//// apart. Decoding caps how deeply it will recurse so a hostile frame can't
//// blow the stack.

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/bit_array
import gleam/bool
import gleam/list

// =============================================================================
// INTERNAL TYPES
// =============================================================================

/// Decoded MessagePack value. The auto-decoder turns this into a Gleam value
/// via reflection.
@internal
pub type Value {
  ValueNil
  ValueBool(Bool)
  ValueInteger(Int)
  ValueFloat(Float)
  ValueString(String)
  ValueBytes(BitArray)
  ValueArray(List(Value))
  ValueMap(List(#(Value, Value)))
}

// =============================================================================
// INTERNAL FUNCTIONS
// =============================================================================

/// Decode a MessagePack value at the start of `bytes`, capping nesting at
/// [`default_max_depth`](#default_max_depth). Returns the
/// [`Value`](#Value) and the bytes after it.
@internal
pub fn decode(bytes: BitArray) -> Result(#(Value, BitArray), Nil) {
  decode_bounded(bytes, default_max_depth)
}

fn decode_at(
  bytes: BitArray,
  depth: Int,
  max_depth: Int,
) -> Result(#(Value, BitArray), Nil) {
  use <- bool.guard(when: depth > max_depth, return: Error(Nil))
  case bytes {
    <<0xc0, rest:bytes>> -> Ok(#(ValueNil, rest))
    <<0xc2, rest:bytes>> -> Ok(#(ValueBool(False), rest))
    <<0xc3, rest:bytes>> -> Ok(#(ValueBool(True), rest))

    // Positive fixint (0x00, 0x7f)
    <<n, rest:bytes>> if n <= 0x7f -> Ok(#(ValueInteger(n), rest))
    // Negative fixint (0xe0, 0xff)
    <<n, rest:bytes>> if n >= 0xe0 -> Ok(#(ValueInteger(n - 256), rest))

    // Unsigned ints
    <<0xcc, n, rest:bytes>> -> Ok(#(ValueInteger(n), rest))
    <<0xcd, n:16-big, rest:bytes>> -> Ok(#(ValueInteger(n), rest))
    <<0xce, n:32-big, rest:bytes>> -> Ok(#(ValueInteger(n), rest))
    <<0xcf, raw:bytes-size(8), rest:bytes>> ->
      Ok(#(ValueInteger(unsigned_from_bytes(raw)), rest))

    // Signed ints
    <<0xd0, n:8-signed, rest:bytes>> -> Ok(#(ValueInteger(n), rest))
    <<0xd1, n:16-signed-big, rest:bytes>> -> Ok(#(ValueInteger(n), rest))
    <<0xd2, n:32-signed-big, rest:bytes>> -> Ok(#(ValueInteger(n), rest))
    <<0xd3, raw:bytes-size(8), rest:bytes>> ->
      Ok(#(ValueInteger(signed_from_bytes(raw)), rest))

    // Floats
    <<0xcb, f:64-float-big, rest:bytes>> -> Ok(#(ValueFloat(f), rest))
    <<0xca, f:32-float-big, rest:bytes>> -> Ok(#(ValueFloat(f), rest))

    // Fixstr (0xa0, 0xbf)
    <<b, rest0:bytes>> if b >= 0xa0 && b <= 0xbf -> {
      let length = b - 0xa0
      decode_string(rest0, length)
    }
    <<0xd9, length, rest0:bytes>> -> decode_string(rest0, length)
    <<0xda, length:16-big, rest0:bytes>> -> decode_string(rest0, length)
    <<0xdb, length:32-big, rest0:bytes>> -> decode_string(rest0, length)

    // Bin
    <<0xc4, length, rest0:bytes>> -> decode_bin(rest0, length)
    <<0xc5, length:16-big, rest0:bytes>> -> decode_bin(rest0, length)
    <<0xc6, length:32-big, rest0:bytes>> -> decode_bin(rest0, length)

    // Fixarray (0x90, 0x9f)
    <<b, rest0:bytes>> if b >= 0x90 && b <= 0x9f ->
      decode_array(rest0, b - 0x90, [], depth + 1, max_depth)
    <<0xdc, length:16-big, rest0:bytes>> ->
      decode_array(rest0, length, [], depth + 1, max_depth)
    <<0xdd, length:32-big, rest0:bytes>> ->
      decode_array(rest0, length, [], depth + 1, max_depth)

    // Fixmap (0x80, 0x8f)
    <<b, rest0:bytes>> if b >= 0x80 && b <= 0x8f ->
      decode_map(rest0, b - 0x80, [], depth + 1, max_depth)
    <<0xde, length:16-big, rest0:bytes>> ->
      decode_map(rest0, length, [], depth + 1, max_depth)
    <<0xdf, length:32-big, rest0:bytes>> ->
      decode_map(rest0, length, [], depth + 1, max_depth)

    _ -> Error(Nil)
  }
}

/// Like [`decode`](#decode) but with a caller-chosen nesting cap.
@internal
pub fn decode_bounded(
  bytes: BitArray,
  max_depth: Int,
) -> Result(#(Value, BitArray), Nil) {
  decode_at(bytes, 0, max_depth)
}

/// Encode MessagePack-encoded items as a MessagePack array.
@internal
pub fn encode_array(items: List(BitArray)) -> BitArray {
  // Single concat over header and items. See `encode_map` for why folding is
  // quadratic.
  bit_array.concat([array_header(list.length(items)), ..items])
}

/// Encode raw bytes as a MessagePack bin.
@internal
pub fn encode_bin(bytes: BitArray) -> BitArray {
  let length = bit_array.byte_size(bytes)
  case length {
    n if n <= 0xff -> bit_array.concat([<<0xc4, n>>, bytes])
    n if n <= 0xffff -> bit_array.concat([<<0xc5, n:16-big>>, bytes])
    n -> bit_array.concat([<<0xc6, n:32-big>>, bytes])
  }
}

/// Encode a Bool.
@internal
pub fn encode_bool(value: Bool) -> BitArray {
  case value {
    True -> <<0xc3>>
    False -> <<0xc2>>
  }
}

/// Encode a Float as MessagePack float64.
@internal
pub fn encode_float(value: Float) -> BitArray {
  <<0xcb, value:64-float-big>>
}

/// Encode an Int as the smallest MessagePack int that fits.
@internal
pub fn encode_int(value: Int) -> BitArray {
  case value {
    n if n >= 0 && n <= 0x7f -> <<n>>
    n if n >= 0 && n <= 0xff -> <<0xcc, n>>
    n if n >= 0 && n <= 0xffff -> <<0xcd, n:16-big>>
    n if n >= 0 && n <= 0xffffffff -> <<0xce, n:32-big>>
    n if n >= 0 -> bit_array.concat([<<0xcf>>, unsigned_to_bytes(n, 8)])
    // Two's complement. The destination width truncates to the low N bits, so
    // adding 2^N before encoding gives the right bytes.
    n if n >= -32 -> <<{ 0x100 + n }:8>>
    n if n >= -128 -> <<0xd0, { 0x100 + n }:8>>
    n if n >= -32_768 -> <<0xd1, { 0x10000 + n }:16-big>>
    n if n >= -2_147_483_648 -> <<0xd2, { 0x100000000 + n }:32-big>>
    // Build the eight bytes with Int arithmetic rather than a 64-bit segment,
    // which the JS target narrows to 52 bits. On Erlang this is exact, on JS it
    // stays exact up to 2^52 and saturates beyond, which no Lily payload
    // reaches in practice.
    n -> bit_array.concat([<<0xd3>>, signed_to_bytes(n, 8)])
  }
}

/// Encode `(key, value)` entries as a MessagePack map. Keys must be pre-encoded
/// BitArrays so callers can reuse string keys without re-wrapping.
@internal
pub fn encode_map(entries: List(#(BitArray, BitArray))) -> BitArray {
  // Flatten to [key0, value0, ...] and concat once. Folding with
  // `bit_array.concat` would recopy the accumulator per entry, going quadratic.
  let body = list.flat_map(entries, fn(entry) { [entry.0, entry.1] })
  bit_array.concat([map_header(list.length(entries)), ..body])
}

/// Encode the MessagePack `nil` byte.
@internal
pub fn encode_nil() -> BitArray {
  <<0xc0>>
}

/// Default nesting cap for [`decode`](#decode). Without it a hostile frame
/// nesting arrays and maps unboundedly would exhaust the stack. Real Lily
/// models stay far below this.
@internal
pub const default_max_depth = 128

/// Encode a String as the smallest MessagePack str that fits.
@internal
pub fn encode_string(value: String) -> BitArray {
  let bytes = bit_array.from_string(value)
  let length = bit_array.byte_size(bytes)
  case length {
    n if n <= 31 -> bit_array.concat([<<{ 0xa0 + n }:8>>, bytes])
    n if n <= 0xff -> bit_array.concat([<<0xd9, n>>, bytes])
    n if n <= 0xffff -> bit_array.concat([<<0xda, n:16-big>>, bytes])
    n -> bit_array.concat([<<0xdb, n:32-big>>, bytes])
  }
}

/// Find the value for a string key in a decoded map's entries. Shared by the
/// transport envelope decoder and the auto codec, both reading string-keyed
/// MessagePack maps.
@internal
pub fn lookup_string_key(
  entries: List(#(Value, Value)),
  key: String,
) -> Result(Value, Nil) {
  case entries {
    [] -> Error(Nil)
    [#(ValueString(k), v), ..] if k == key -> Ok(v)
    [_, ..rest] -> lookup_string_key(rest, key)
  }
}

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

fn array_header(length: Int) -> BitArray {
  case length {
    n if n <= 15 -> <<{ 0x90 + n }:8>>
    n if n <= 0xffff -> <<0xdc, n:16-big>>
    n -> <<0xdd, n:32-big>>
  }
}

// Split a byte-aligned bit array into its individual bytes. Bounded to the
// eight bytes of a 64-bit int here, so plain recursion is fine.
fn byte_list(bytes: BitArray) -> List(Int) {
  case bytes {
    <<b, rest:bytes>> -> [b, ..byte_list(rest)]
    _ -> []
  }
}

fn bytes_from_byte_list(bytes: List(Int)) -> BitArray {
  list.fold(bytes, <<>>, fn(acc, b) { <<acc:bits, { b }:8>> })
}

fn decode_array(
  bytes: BitArray,
  remaining: Int,
  accumulator: List(Value),
  depth: Int,
  max_depth: Int,
) -> Result(#(Value, BitArray), Nil) {
  case remaining {
    0 -> Ok(#(ValueArray(list.reverse(accumulator)), bytes))
    n ->
      case decode_at(bytes, depth, max_depth) {
        Error(_) -> Error(Nil)
        Ok(#(item, rest)) ->
          decode_array(rest, n - 1, [item, ..accumulator], depth, max_depth)
      }
  }
}

fn decode_bin(bytes: BitArray, length: Int) -> Result(#(Value, BitArray), Nil) {
  case bytes {
    <<taken:bytes-size(length), rest:bytes>> -> Ok(#(ValueBytes(taken), rest))
    _ -> Error(Nil)
  }
}

fn decode_map(
  bytes: BitArray,
  remaining: Int,
  accumulator: List(#(Value, Value)),
  depth: Int,
  max_depth: Int,
) -> Result(#(Value, BitArray), Nil) {
  case remaining {
    0 -> Ok(#(ValueMap(list.reverse(accumulator)), bytes))
    n ->
      case decode_at(bytes, depth, max_depth) {
        Error(_) -> Error(Nil)
        Ok(#(key, after_key)) ->
          case decode_at(after_key, depth, max_depth) {
            Error(_) -> Error(Nil)
            Ok(#(value, after_value)) ->
              decode_map(
                after_value,
                n - 1,
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
) -> Result(#(Value, BitArray), Nil) {
  // Split `length` bytes off in one match. Fewer than `length` bytes fails
  // the pattern and falls through to Error, matching the old slice guard.
  case bytes {
    <<taken:bytes-size(length), rest:bytes>> ->
      case bit_array.to_string(taken) {
        Error(_) -> Error(Nil)
        Ok(text) -> Ok(#(ValueString(text), rest))
      }
    _ -> Error(Nil)
  }
}

fn map_header(length: Int) -> BitArray {
  case length {
    n if n <= 15 -> <<{ 0x80 + n }:8>>
    n if n <= 0xffff -> <<0xde, n:16-big>>
    n -> <<0xdf, n:32-big>>
  }
}

// Read a two's-complement big-endian integer. A leading byte with its top bit
// set means negative, so we take the magnitude from the complement and negate.
// This avoids ever forming 2^64, which the JS target cannot hold exactly.
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

// Two's complement of a big-endian byte string, computed byte by byte (invert
// then add one from the low end) so no intermediate exceeds a single byte.
fn twos_complement(bytes: BitArray) -> BitArray {
  let inverted_low_first =
    bytes
    |> byte_list
    |> list.reverse
    |> list.map(fn(b) { 255 - b })
  let #(_carry, low_first) =
    list.map_fold(inverted_low_first, 1, fn(carry, b) {
      let sum = b + carry
      #(sum / 256, sum % 256)
    })
  low_first |> list.reverse |> bytes_from_byte_list
}

fn unsigned_from_bytes(bytes: BitArray) -> Int {
  byte_list(bytes) |> list.fold(0, fn(acc, b) { acc * 256 + b })
}

fn unsigned_to_bytes(value: Int, count: Int) -> BitArray {
  unsigned_to_bytes_loop(value, count, <<>>)
}

fn unsigned_to_bytes_loop(
  value: Int,
  remaining: Int,
  acc: BitArray,
) -> BitArray {
  case remaining <= 0 {
    True -> acc
    False ->
      unsigned_to_bytes_loop(value / 256, remaining - 1, <<
        { value % 256 }:8,
        acc:bits,
      >>)
  }
}
