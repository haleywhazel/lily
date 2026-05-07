// Tests for the pure-Gleam MessagePack primitives in
// lily/internal/message_pack. Each test pins a specific byte sequence so
// any divergence from the MessagePack specification (or from the previous
// Erlang/JS FFI codecs) is caught immediately. Runs on both targets.

import gleam/bit_array
import gleeunit/should
import lily/internal/message_pack.{
  ValueArray, ValueBool, ValueBytes, ValueFloat, ValueInteger, ValueMap,
  ValueNil, ValueString,
}

// =============================================================================
// HELPERS
// =============================================================================

fn assert_encodes(actual: BitArray, expected_hex: String) -> Nil {
  bit_array.base16_encode(actual)
  |> should.equal(expected_hex)
}

fn assert_decodes(hex: String, expected: message_pack.Value) -> Nil {
  let assert Ok(bytes) = bit_array.base16_decode(hex)
  let assert Ok(#(value, rest)) = message_pack.decode(bytes)
  value
  |> should.equal(expected)
  bit_array.byte_size(rest)
  |> should.equal(0)
}

// =============================================================================
// ENCODE: NIL / BOOL
// =============================================================================

pub fn encode_nil_test() {
  assert_encodes(message_pack.encode_nil(), "C0")
}

pub fn encode_bool_true_test() {
  assert_encodes(message_pack.encode_bool(True), "C3")
}

pub fn encode_bool_false_test() {
  assert_encodes(message_pack.encode_bool(False), "C2")
}

// =============================================================================
// ENCODE: INTEGERS (positive)
// =============================================================================

pub fn encode_int_zero_test() {
  assert_encodes(message_pack.encode_int(0), "00")
}

pub fn encode_int_positive_fixint_max_test() {
  assert_encodes(message_pack.encode_int(127), "7F")
}

pub fn encode_int_uint8_test() {
  assert_encodes(message_pack.encode_int(128), "CC80")
  assert_encodes(message_pack.encode_int(255), "CCFF")
}

pub fn encode_int_uint16_test() {
  assert_encodes(message_pack.encode_int(256), "CD0100")
  assert_encodes(message_pack.encode_int(65_535), "CDFFFF")
}

pub fn encode_int_uint32_test() {
  assert_encodes(message_pack.encode_int(65_536), "CE00010000")
  assert_encodes(message_pack.encode_int(4_294_967_295), "CEFFFFFFFF")
}

// =============================================================================
// ENCODE: INTEGERS (negative)
// =============================================================================

pub fn encode_int_negative_fixint_test() {
  assert_encodes(message_pack.encode_int(-1), "FF")
  assert_encodes(message_pack.encode_int(-32), "E0")
}

pub fn encode_int_int8_test() {
  assert_encodes(message_pack.encode_int(-33), "D0DF")
  assert_encodes(message_pack.encode_int(-128), "D080")
}

pub fn encode_int_int16_test() {
  assert_encodes(message_pack.encode_int(-129), "D1FF7F")
  assert_encodes(message_pack.encode_int(-32_768), "D18000")
}

pub fn encode_int_int32_test() {
  assert_encodes(message_pack.encode_int(-32_769), "D2FFFF7FFF")
  assert_encodes(message_pack.encode_int(-2_147_483_648), "D280000000")
}

// =============================================================================
// ENCODE: STRINGS
// =============================================================================

pub fn encode_string_empty_test() {
  assert_encodes(message_pack.encode_string(""), "A0")
}

pub fn encode_string_short_test() {
  assert_encodes(message_pack.encode_string("hi"), "A26869")
}

pub fn encode_string_fixstr_max_test() {
  let value = "0123456789abcdef0123456789abcde"
  // 31 chars: fixstr header 0xbf + 31 bytes
  assert_encodes(
    message_pack.encode_string(value),
    "BF" <> bit_array.base16_encode(bit_array.from_string(value)),
  )
}

pub fn encode_string_str8_test() {
  let value = "0123456789abcdef0123456789abcdef"
  // 32 chars: str8 header 0xd9 + 0x20 + bytes
  assert_encodes(
    message_pack.encode_string(value),
    "D920" <> bit_array.base16_encode(bit_array.from_string(value)),
  )
}

// =============================================================================
// ENCODE: BIN
// =============================================================================

pub fn encode_bin_empty_test() {
  assert_encodes(message_pack.encode_bin(<<>>), "C400")
}

pub fn encode_bin_short_test() {
  assert_encodes(message_pack.encode_bin(<<1, 2, 3>>), "C403010203")
}

// =============================================================================
// ENCODE: ARRAY
// =============================================================================

pub fn encode_array_empty_test() {
  assert_encodes(message_pack.encode_array([]), "90")
}

pub fn encode_array_three_ints_test() {
  let items = [
    message_pack.encode_int(1),
    message_pack.encode_int(2),
    message_pack.encode_int(3),
  ]
  assert_encodes(message_pack.encode_array(items), "93010203")
}

// =============================================================================
// ENCODE: MAP
// =============================================================================

pub fn encode_map_empty_test() {
  assert_encodes(message_pack.encode_map([]), "80")
}

pub fn encode_map_one_entry_test() {
  let entries = [
    #(message_pack.encode_string("k"), message_pack.encode_int(7)),
  ]
  assert_encodes(message_pack.encode_map(entries), "81A16B07")
}

// =============================================================================
// ENCODE: FLOAT
// =============================================================================

pub fn encode_float_zero_test() {
  assert_encodes(message_pack.encode_float(0.0), "CB0000000000000000")
}

pub fn encode_float_one_test() {
  assert_encodes(message_pack.encode_float(1.0), "CB3FF0000000000000")
}

// =============================================================================
// DECODE
// =============================================================================

pub fn decode_nil_test() {
  assert_decodes("C0", ValueNil)
}

pub fn decode_bool_test() {
  assert_decodes("C3", ValueBool(True))
  assert_decodes("C2", ValueBool(False))
}

pub fn decode_positive_fixint_test() {
  assert_decodes("00", ValueInteger(0))
  assert_decodes("7F", ValueInteger(127))
}

pub fn decode_negative_fixint_test() {
  assert_decodes("FF", ValueInteger(-1))
  assert_decodes("E0", ValueInteger(-32))
}

pub fn decode_uint8_test() {
  assert_decodes("CC80", ValueInteger(128))
  assert_decodes("CCFF", ValueInteger(255))
}

pub fn decode_uint16_test() {
  assert_decodes("CD0100", ValueInteger(256))
}

pub fn decode_uint32_test() {
  assert_decodes("CE00010000", ValueInteger(65_536))
}

pub fn decode_int8_test() {
  assert_decodes("D080", ValueInteger(-128))
}

pub fn decode_int16_test() {
  assert_decodes("D18000", ValueInteger(-32_768))
}

pub fn decode_int32_test() {
  assert_decodes("D280000000", ValueInteger(-2_147_483_648))
}

pub fn decode_fixstr_test() {
  assert_decodes("A26869", ValueString("hi"))
}

pub fn decode_str8_test() {
  let value = "0123456789abcdef0123456789abcdef"
  let hex = "D920" <> bit_array.base16_encode(bit_array.from_string(value))
  assert_decodes(hex, ValueString(value))
}

pub fn decode_bin_test() {
  assert_decodes("C403010203", ValueBytes(<<1, 2, 3>>))
}

pub fn decode_fixarray_test() {
  assert_decodes(
    "93010203",
    ValueArray([ValueInteger(1), ValueInteger(2), ValueInteger(3)]),
  )
}

pub fn decode_fixmap_test() {
  assert_decodes("81A16B07", ValueMap([#(ValueString("k"), ValueInteger(7))]))
}

pub fn decode_float_test() {
  assert_decodes("CB3FF0000000000000", ValueFloat(1.0))
}

// =============================================================================
// ROUNDTRIPS
// =============================================================================

fn roundtrip_int(n: Int) -> Nil {
  let encoded = message_pack.encode_int(n)
  let assert Ok(#(decoded, _)) = message_pack.decode(encoded)
  decoded
  |> should.equal(ValueInteger(n))
}

pub fn roundtrip_int_range_test() {
  roundtrip_int(0)
  roundtrip_int(1)
  roundtrip_int(127)
  roundtrip_int(128)
  roundtrip_int(65_535)
  roundtrip_int(65_536)
  roundtrip_int(-1)
  roundtrip_int(-32)
  roundtrip_int(-33)
  roundtrip_int(-128)
  roundtrip_int(-129)
  roundtrip_int(-32_768)
  roundtrip_int(-32_769)
}

pub fn roundtrip_string_test() {
  let value = "Hello, world!"
  let encoded = message_pack.encode_string(value)
  let assert Ok(#(decoded, _)) = message_pack.decode(encoded)
  decoded
  |> should.equal(ValueString(value))
}

pub fn roundtrip_array_test() {
  let items = [
    message_pack.encode_string("a"),
    message_pack.encode_int(1),
    message_pack.encode_bool(True),
  ]
  let encoded = message_pack.encode_array(items)
  let assert Ok(#(decoded, _)) = message_pack.decode(encoded)
  decoded
  |> should.equal(
    ValueArray([ValueString("a"), ValueInteger(1), ValueBool(True)]),
  )
}

pub fn roundtrip_map_test() {
  let entries = [
    #(message_pack.encode_string("name"), message_pack.encode_string("Alice")),
    #(message_pack.encode_string("age"), message_pack.encode_int(30)),
  ]
  let encoded = message_pack.encode_map(entries)
  let assert Ok(#(decoded, _)) = message_pack.decode(encoded)
  decoded
  |> should.equal(
    ValueMap([
      #(ValueString("name"), ValueString("Alice")),
      #(ValueString("age"), ValueInteger(30)),
    ]),
  )
}
