-module(lily_transport_ffi).

-export([auto_encode/1, auto_decode/1, register/1, register_model/1]).

%%% ============================================================================
%%% TRANSPORT AUTO-SERIALISER
%%%
%%% Provides automatic JSON serialisation for Gleam custom types using a
%%% positional encoding scheme. On Erlang, custom types are represented as
%%% tagged tuples, and atoms are self-describing, so no constructor registry
%%% is needed for decoding.
%%%
%%% This has to be an FFI module as the encoder needs to inspect the runtime
%%% representation of an arbitrary Gleam value.
%%%
%%% Wire format:
%%%   {"_":"ConstructorName","0":field0,"1":field1,...}
%%%
%%% Zero-field constructors (atoms) encode as {"_":"ConstructorName"}.
%%% Tuples with fields encode with positional keys "0", "1", etc.
%%%
%%% This uses gleam_json functions to build proper Json types.
%%% ============================================================================

%%% ============================================================================
%%% EXPORTED FUNCTIONS
%%% ============================================================================

%% Automatically encode any Gleam value to JSON
auto_encode(Value) ->
    encode_value(Value).

%% Automatically decode JSON to a Gleam value
%% Returns {ok, Value} as expected by new_primitive_decoder
auto_decode(Json) ->
    {ok, decode_value(Json)}.

%% No-op on Erlang, as constructors are self-describing via atoms
register(_Constructors) ->
    nil.

%% No-op on Erlang, as model walk not needed
register_model(_Model) ->
    nil.

%%% ============================================================================
%%% PRIVATE ENCODING FUNCTIONS
%%% ============================================================================

%% Encode a Gleam value to a JSON type (using gleam_json)
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
    %% Zero-field constructor (atom)
    AtomName = atom_to_binary(Value, utf8),
    PascalName = snake_to_pascal(AtomName),
    'gleam@json':object([{<<"_">>, 'gleam@json':string(PascalName)}]);
encode_value(Value) when is_tuple(Value) ->
    %% Tagged tuple (custom type with fields)
    Tag = element(1, Value),
    TagName = atom_to_binary(Tag, utf8),
    PascalName = snake_to_pascal(TagName),
    Size = tuple_size(Value),

    %% Build [{Key, JsonValue}] in forward order by folding high-to-low index,
    %% prepending each field — avoids the reverse/1 pass at the end
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
    %% Fallback for unknown types – just pass through as null
    'gleam@json':null().

%%% ============================================================================
%%% PRIVATE DECODING FUNCTIONS
%%% ============================================================================

%% Decode a JSON-compatible Erlang term to a Gleam value
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
        undefined ->
            %% Not a custom type, return as-is
            Map;
        TagBinary ->
            %% Custom type - decode by tag
            decode_custom_type(TagBinary, Map)
    end;
decode_value(Value) ->
    %% Fallback
    Value.

%% Decode a custom type from a map with "_" tag
decode_custom_type(TagBinary, Map) ->
    %% Wire format uses PascalCase (e.g., "RefreshStats"),
    %% but Gleam compiles constructors to snake_case atoms on Erlang
    %% (e.g., refresh_stats). Convert before creating the atom.
    SnakeName = pascal_to_snake(TagBinary),
    Tag = binary_to_atom(SnakeName, utf8),

    %% Extract positional fields
    Fields = extract_fields(Map, 0, []),

    case Fields of
        [] ->
            %% Zero-field constructor (just the atom)
            Tag;
        _ ->
            %% Multi-field constructor (tagged tuple)
            list_to_tuple([Tag | Fields])
    end.

%% Extract numbered fields from a map recursively
extract_fields(Map, Index, Acc) ->
    FieldKey = integer_to_binary(Index),
    case maps:get(FieldKey, Map, undefined) of
        undefined ->
            %% No more fields
            lists:reverse(Acc);
        Value ->
            %% Decode field and continue
            DecodedValue = decode_value(Value),
            extract_fields(Map, Index + 1, [DecodedValue | Acc])
    end.

%%% ============================================================================
%%% NAME CONVERSION HELPERS
%%%
%%% Gleam constructors use PascalCase in source (e.g., RefreshStats) but compile
%%% to snake_case atoms on Erlang (e.g., refresh_stats). The wire format uses
%%% PascalCase to match the JavaScript representation. These helpers convert
%%% between the two conventions.
%%% ============================================================================

%% Convert PascalCase binary to snake_case binary
%% e.g., <<"RefreshStats">> -> <<"refresh_stats">>
%%
%% Accumulates into an iolist and converts once at the end.
%% Binary-append per character is O(n²); iolist prepend + reverse is O(n).
pascal_to_snake(<<>>) ->
    <<>>;
pascal_to_snake(Bin) ->
    iolist_to_binary(pascal_to_snake(Bin, [])).

pascal_to_snake(<<>>, Acc) ->
    lists:reverse(Acc);
pascal_to_snake(<<C, Rest/binary>>, Acc) when C >= $A, C =< $Z ->
    Lower = C + 32,
    case Acc of
        [] ->
            %% First character — no underscore prefix
            pascal_to_snake(Rest, [Lower]);
        _ ->
            pascal_to_snake(Rest, [Lower, $_ | Acc])
    end;
pascal_to_snake(<<C, Rest/binary>>, Acc) ->
    pascal_to_snake(Rest, [C | Acc]).

%% Convert snake_case binary to PascalCase binary
%% e.g., <<"refresh_stats">> -> <<"RefreshStats">>
snake_to_pascal(<<>>) ->
    <<>>;
snake_to_pascal(Bin) ->
    iolist_to_binary(snake_to_pascal(Bin, [], true)).

snake_to_pascal(<<>>, Acc, _CapNext) ->
    lists:reverse(Acc);
snake_to_pascal(<<$_, Rest/binary>>, Acc, _CapNext) ->
    %% Underscore: skip it, capitalise the next character
    snake_to_pascal(Rest, Acc, true);
snake_to_pascal(<<C, Rest/binary>>, Acc, true) when C >= $a, C =< $z ->
    Upper = C - 32,
    snake_to_pascal(Rest, [Upper | Acc], false);
snake_to_pascal(<<C, Rest/binary>>, Acc, _CapNext) ->
    snake_to_pascal(Rest, [C | Acc], false).
