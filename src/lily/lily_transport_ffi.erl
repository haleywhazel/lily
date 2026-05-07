%%% Transport auto-serialiser FFI for Erlang. Provides JSON serialisation for
%%% Gleam custom types using a positional encoding scheme. On Erlang, custom
%%% types are represented as tagged tuples and atoms are self-describing, so
%%% no constructor registry is needed for decoding.
%%%
%%% Wire format: {"_":"ConstructorName","0":field0,"1":field1,...}
%%% Zero-field constructors (atoms) encode as {"_":"ConstructorName"}.
%%% Tuples with fields encode with positional keys "0", "1", etc.
%%%
%%% MessagePack auto-serialisation lives in pure Gleam at
%%% lily/internal/auto_codec, composed with reflection (which uses
%%% lily_reflection_ffi for value introspection on Erlang). Only the JSON
%%% path remains here, since gleam_json has its own pre-existing FFI plumbing
%%% that the Gleam side is built on.

-module(lily_transport_ffi).

-export([
    auto_decode/1,
    auto_encode/1
]).

%%% ============================================================================
%%% EXPORTED FUNCTIONS
%%% ============================================================================

%% Automatically decode JSON to a Gleam value. Returns {ok, Value}; the
%% decode_value clause uses binary_to_existing_atom so unknown constructor
%% names from a stale schema raise badarg rather than leaking fresh atoms.
auto_decode(Json) ->
    try
        {ok, decode_value(Json)}
    catch
        _:_ -> {error, undefined}
    end.

%% Automatically encode any Gleam value to a Json type (using gleam_json).
auto_encode(Value) ->
    encode_value(Value).

%%% ============================================================================
%%% PRIVATE ENCODING FUNCTIONS
%%% ============================================================================

encode_value(undefined) ->
    'gleam@json':null();
encode_value(nil) ->
    'gleam@json':null();
encode_value(Value) when is_boolean(Value) ->
    'gleam@json':bool(Value);
encode_value(Value) when is_binary(Value) ->
    'gleam@json':string(Value);
encode_value(Value) when is_integer(Value) ->
    'gleam@json':int(Value);
encode_value(Value) when is_float(Value) ->
    'gleam@json':float(Value);
encode_value([]) ->
    'gleam@json':array([], fun(X) -> X end);
encode_value(List) when is_list(List) ->
    'gleam@json':array(List, fun encode_value/1);
encode_value(Value) when is_atom(Value) ->
    %% Zero-field constructor (atom).
    AtomName = atom_to_binary(Value, utf8),
    PascalName = snake_to_pascal(AtomName),
    'gleam@json':object([{<<"_">>, 'gleam@json':string(PascalName)}]);
encode_value(Value) when is_tuple(Value) ->
    %% Tagged tuple (custom type with fields).
    Tag = element(1, Value),
    TagName = atom_to_binary(Tag, utf8),
    PascalName = snake_to_pascal(TagName),
    Size = tuple_size(Value),
    %% Build [{Key, JsonValue}] in forward order by folding high-to-low index,
    %% prepending each field. Avoids the reverse/1 pass at the end.
    Fields =
        lists:foldl(fun(Index, Acc) ->
                       FieldValue = element(Index + 1, Value),
                       EncodedValue = encode_value(FieldValue),
                       FieldKey = integer_to_binary(Index - 1),
                       [{FieldKey, EncodedValue} | Acc]
                    end,
                    [{<<"_">>, 'gleam@json':string(PascalName)}],
                    lists:seq(Size - 1, 1, -1)),
    'gleam@json':object(Fields);
encode_value(_Value) ->
    %% Fallback for unknown types. Pass through as null.
    'gleam@json':null().

%%% ============================================================================
%%% PRIVATE DECODING FUNCTIONS
%%% ============================================================================

%% Decode a custom type from a map with "_" tag.
decode_custom_type(TagBinary, Map) ->
    SnakeName = pascal_to_snake(TagBinary),
    Tag = binary_to_existing_atom(SnakeName, utf8),
    Fields = extract_fields(Map, 0, []),
    case Fields of
        [] -> Tag;
        _ -> list_to_tuple([Tag | Fields])
    end.

decode_value(null) ->
    nil;
decode_value(Value) when is_boolean(Value) ->
    Value;
decode_value(Value) when is_binary(Value) ->
    Value;
decode_value(Value) when is_integer(Value) ->
    Value;
decode_value(Value) when is_float(Value) ->
    Value;
decode_value([]) ->
    [];
decode_value(List) when is_list(List) ->
    [decode_value(Item) || Item <- List];
decode_value(Map) when is_map(Map) ->
    case maps:get(<<"_">>, Map, undefined) of
        undefined -> Map;
        TagBinary -> decode_custom_type(TagBinary, Map)
    end;
decode_value(Value) ->
    Value.

extract_fields(Map, Index, Acc) ->
    FieldKey = integer_to_binary(Index),
    case maps:get(FieldKey, Map, undefined) of
        undefined -> lists:reverse(Acc);
        Value ->
            DecodedValue = decode_value(Value),
            extract_fields(Map, Index + 1, [DecodedValue | Acc])
    end.

%%% ============================================================================
%%% NAME CONVERSION HELPERS
%%% ============================================================================
%%
%% Gleam constructors use PascalCase in source (e.g. RefreshStats) but compile
%% to snake_case atoms on Erlang (e.g. refresh_stats). The wire format uses
%% PascalCase to match the JavaScript representation. These helpers convert
%% between the two conventions.

%% Convert PascalCase binary to snake_case binary.
pascal_to_snake(<<>>) ->
    <<>>;
pascal_to_snake(Bin) ->
    iolist_to_binary(pascal_to_snake(Bin, [])).

pascal_to_snake(<<>>, Acc) ->
    lists:reverse(Acc);
pascal_to_snake(<<C, Rest/binary>>, Acc) when C >= $A, C =< $Z ->
    Lower = C + 32,
    case Acc of
        [] -> pascal_to_snake(Rest, [Lower]);
        _ -> pascal_to_snake(Rest, [Lower, $_ | Acc])
    end;
pascal_to_snake(<<C, Rest/binary>>, Acc) ->
    pascal_to_snake(Rest, [C | Acc]).

%% Convert snake_case binary to PascalCase binary.
snake_to_pascal(<<>>) ->
    <<>>;
snake_to_pascal(Bin) ->
    iolist_to_binary(snake_to_pascal(Bin, [], true)).

snake_to_pascal(<<>>, Acc, _CapNext) ->
    lists:reverse(Acc);
snake_to_pascal(<<$_, Rest/binary>>, Acc, _CapNext) ->
    snake_to_pascal(Rest, Acc, true);
snake_to_pascal(<<C, Rest/binary>>, Acc, true) when C >= $a, C =< $z ->
    Upper = C - 32,
    snake_to_pascal(Rest, [Upper | Acc], false);
snake_to_pascal(<<C, Rest/binary>>, Acc, _CapNext) ->
    snake_to_pascal(Rest, [C | Acc], false).
