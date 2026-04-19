-module(lily_transport_ffi).

-export([
    auto_decode/1,
    auto_decode_message_pack/1,
    auto_encode/1,
    auto_encode_message_pack/1,
    decode_message_pack_protocol/2,
    encode_message_pack_protocol/2,
    register/1,
    register_model/1
]).

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

%% Automatically decode JSON to a Gleam value
%% Returns {ok, Value} as expected by new_primitive_decoder
auto_decode(Json) ->
    {ok, decode_value(Json)}.

%% Automatically decode MessagePack bytes to a Gleam value
%% Returns {ok, Value} or {error, nil}
auto_decode_message_pack(Bytes) ->
    try
        {RawValue, _Rest} = decode_message_pack(Bytes),
        {ok, decode_value(RawValue)}
    catch
        _:_ -> {error, nil}
    end.

%% Automatically encode any Gleam value to JSON
auto_encode(Value) ->
    encode_value(Value).

%% Automatically encode any Gleam value to MessagePack bytes
auto_encode_message_pack(Value) ->
    encode_message_pack(Value).

%% No-op on Erlang, as constructors are self-describing via atoms
register(_Constructors) ->
    nil.

%% No-op on Erlang, as model walk not needed
register_model(_Model) ->
    nil.

%%% ============================================================================
%%% MSGPACK PROTOCOL ENCODE
%%%
%%% Encodes a Protocol tuple to MessagePack bytes.
%%% The payload/state values are encoded via the provided codec and embedded
%%% as MessagePack bin values in the protocol envelope map.
%%% ============================================================================

encode_message_pack_protocol(Protocol, Codec) ->
    case Protocol of
        {acknowledge, Sequence} ->
            %% fixmap(2): type + sequence
            encode_message_pack_map([
                {<<"type">>, <<"acknowledge">>},
                {<<"sequence">>, Sequence}
            ]);

        {client_message, Payload} ->
            PayloadBytes = (element(2, Codec))(Payload),
            encode_message_pack_map([
                {<<"type">>, <<"client_message">>},
                {<<"payload">>, {bin, PayloadBytes}}
            ]);

        {server_message, Sequence, Payload} ->
            PayloadBytes = (element(2, Codec))(Payload),
            encode_message_pack_map([
                {<<"type">>, <<"server_message">>},
                {<<"sequence">>, Sequence},
                {<<"payload">>, {bin, PayloadBytes}}
            ]);

        {snapshot, Sequence, State} ->
            StateBytes = (element(4, Codec))(State),
            encode_message_pack_map([
                {<<"type">>, <<"snapshot">>},
                {<<"sequence">>, Sequence},
                {<<"state">>, {bin, StateBytes}}
            ]);

        {resync, AfterSequence} ->
            encode_message_pack_map([
                {<<"type">>, <<"resync">>},
                {<<"after_sequence">>, AfterSequence}
            ]);

        _ ->
            <<>>
    end.

%%% ============================================================================
%%% MSGPACK PROTOCOL DECODE
%%%
%%% Decodes MessagePack bytes to a Protocol tuple using the provided codec.
%%% Returns {ok, Protocol} or {error, nil}.
%%% ============================================================================

decode_message_pack_protocol(Bytes, Codec) ->
    try
        {Map, _Rest} = decode_message_pack(Bytes),
        case Map of
            #{<<"type">> := <<"acknowledge">>, <<"sequence">> := Sequence} ->
                {ok, {acknowledge, Sequence}};

            #{<<"type">> := <<"client_message">>, <<"payload">> := PayloadBin}
                when is_binary(PayloadBin) ->
                case (element(3, Codec))(PayloadBin) of
                    {ok, Payload} -> {ok, {client_message, Payload}};
                    _ -> {error, nil}
                end;

            #{<<"type">> := <<"server_message">>,
              <<"sequence">> := Sequence,
              <<"payload">> := PayloadBin}
                when is_binary(PayloadBin) ->
                case (element(3, Codec))(PayloadBin) of
                    {ok, Payload} -> {ok, {server_message, Sequence, Payload}};
                    _ -> {error, nil}
                end;

            #{<<"type">> := <<"snapshot">>,
              <<"sequence">> := Sequence,
              <<"state">> := StateBin}
                when is_binary(StateBin) ->
                case (element(5, Codec))(StateBin) of
                    {ok, State} -> {ok, {snapshot, Sequence, State}};
                    _ -> {error, nil}
                end;

            #{<<"type">> := <<"resync">>, <<"after_sequence">> := AfterSequence} ->
                {ok, {resync, AfterSequence}};

            _ ->
                {error, nil}
        end
    catch
        _:_ -> {error, nil}
    end.

%%% ============================================================================
%%% PRIVATE ENCODING FUNCTIONS (JSON path)
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
%%% PRIVATE DECODING FUNCTIONS (JSON path)
%%% ============================================================================

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
%%% MESSAGEPACK ENCODE (inline, no external dependencies)
%%%
%%% Encodes Gleam runtime values (atoms, tuples, binaries, lists, integers,
%%% floats, booleans) to MessagePack binary using the same positional format
%%% as the JSON auto-encoder:
%%%
%%%   custom type atom   → MessagePack map {"_": "ConstructorName"}
%%%   custom type tuple  → MessagePack map {"_": "Ctor", "0": v0, "1": v1, ...}
%%%   integer            → MessagePack int
%%%   float              → MessagePack float64
%%%   binary             → MessagePack str
%%%   boolean            → MessagePack bool
%%%   nil / undefined    → MessagePack nil
%%%   list               → MessagePack array
%%% ============================================================================

encode_message_pack(undefined) ->
    <<16#c0>>;
encode_message_pack(nil) ->
    <<16#c0>>;
encode_message_pack(true) ->
    <<16#c3>>;
encode_message_pack(false) ->
    <<16#c2>>;
encode_message_pack(Value) when is_integer(Value) ->
    encode_message_pack_int(Value);
encode_message_pack(Value) when is_float(Value) ->
    <<16#cb, Value:64/float-big>>;
encode_message_pack(Value) when is_binary(Value) ->
    encode_message_pack_str(Value);
encode_message_pack([]) ->
    <<16#90>>;  %% fixarray(0)
encode_message_pack(List) when is_list(List) ->
    Len = length(List),
    Header = encode_message_pack_array_header(Len),
    Items = [encode_message_pack(Item) || Item <- List],
    iolist_to_binary([Header | Items]);
encode_message_pack(Value) when is_atom(Value) ->
    AtomName = atom_to_binary(Value, utf8),
    PascalName = snake_to_pascal(AtomName),
    %% fixmap(1): {"_": "ConstructorName"}
    encode_message_pack_map([{<<"_">>, PascalName}]);
encode_message_pack(Value) when is_tuple(Value) ->
    Tag = element(1, Value),
    TagName = atom_to_binary(Tag, utf8),
    PascalName = snake_to_pascal(TagName),
    Size = tuple_size(Value),
    %% Build field pairs: [{"_", Name}, {"0", v0}, {"1", v1}, ...]
    %% foldl over [Size-1 .. 1] prepending each, acc starts with [{"_", Name}]
    Fields = lists:foldl(
        fun(Index, Acc) ->
            FieldValue = element(Index + 1, Value),
            FieldKey = integer_to_binary(Index - 1),
            [{FieldKey, FieldValue} | Acc]
        end,
        [{<<"_">>, PascalName}],
        lists:seq(Size - 1, 1, -1)
    ),
    Len = length(Fields),
    Header = encode_message_pack_map_header(Len),
    Pairs = [[encode_message_pack_str(K), encode_message_pack(V)] || {K, V} <- Fields],
    iolist_to_binary([Header | Pairs]);
encode_message_pack(_) ->
    <<16#c0>>.

encode_message_pack_array_header(Len) when Len =< 15 ->
    <<(16#90 bor Len)>>;
encode_message_pack_array_header(Len) when Len =< 65535 ->
    <<16#dc, Len:16/big>>;
encode_message_pack_array_header(Len) ->
    <<16#dd, Len:32/big>>.

encode_message_pack_bin(Bin) ->
    Len = byte_size(Bin),
    if
        Len =< 255 -> <<16#c4, Len, Bin/binary>>;
        Len =< 65535 -> <<16#c5, Len:16/big, Bin/binary>>;
        true -> <<16#c6, Len:32/big, Bin/binary>>
    end.

encode_message_pack_int(N) when N >= 0, N =< 16#7f ->
    <<N>>;
encode_message_pack_int(N) when N >= 0, N =< 16#ff ->
    <<16#cc, N>>;
encode_message_pack_int(N) when N >= 0, N =< 16#ffff ->
    <<16#cd, N:16/big>>;
encode_message_pack_int(N) when N >= 0, N =< 16#ffffffff ->
    <<16#ce, N:32/big>>;
encode_message_pack_int(N) when N >= 0 ->
    <<16#cf, N:64/big>>;
encode_message_pack_int(N) when N >= -32 ->
    <<N:8/signed>>;
encode_message_pack_int(N) when N >= -128 ->
    <<16#d0, N:8/signed>>;
encode_message_pack_int(N) when N >= -32768 ->
    <<16#d1, N:16/signed-big>>;
encode_message_pack_int(N) when N >= -2147483648 ->
    <<16#d2, N:32/signed-big>>;
encode_message_pack_int(N) ->
    <<16#d3, N:64/signed-big>>.

%% Encode a list of {Key, Value} pairs as a MessagePack map
%% Values can be {bin, Binary} for raw bin embedding, or any Gleam value
encode_message_pack_map(Pairs) ->
    Len = length(Pairs),
    Header = encode_message_pack_map_header(Len),
    Encoded = [begin
        K = encode_message_pack_str(K0),
        V = case V0 of
            {bin, Bin} -> encode_message_pack_bin(Bin);
            Other -> encode_message_pack(Other)
        end,
        [K, V]
    end || {K0, V0} <- Pairs],
    iolist_to_binary([Header | Encoded]).

encode_message_pack_map_header(Len) when Len =< 15 ->
    <<(16#80 bor Len)>>;
encode_message_pack_map_header(Len) when Len =< 65535 ->
    <<16#de, Len:16/big>>;
encode_message_pack_map_header(Len) ->
    <<16#df, Len:32/big>>.

encode_message_pack_str(Str) ->
    Len = byte_size(Str),
    if
        Len =< 31 -> <<(16#a0 bor Len), Str/binary>>;
        Len =< 255 -> <<16#d9, Len, Str/binary>>;
        Len =< 65535 -> <<16#da, Len:16/big, Str/binary>>;
        true -> <<16#db, Len:32/big, Str/binary>>
    end.

%%% ============================================================================
%%% MESSAGEPACK DECODE (inline, no external dependencies)
%%%
%%% Decodes MessagePack binary to Gleam runtime values:
%%%
%%%   MessagePack nil        → nil
%%%   MessagePack bool       → true | false
%%%   MessagePack int        → integer
%%%   MessagePack float64    → float
%%%   MessagePack str        → binary
%%%   MessagePack bin        → binary (raw bytes returned as Erlang binary)
%%%   MessagePack array      → list
%%%   MessagePack map with _ → Gleam custom type (atom or tuple)
%%%   MessagePack map w/o _  → Erlang map (for protocol envelope decoding)
%%% ============================================================================

decode_message_pack(<<16#c0, Rest/binary>>) ->
    {nil, Rest};
decode_message_pack(<<16#c2, Rest/binary>>) ->
    {false, Rest};
decode_message_pack(<<16#c3, Rest/binary>>) ->
    {true, Rest};

%% Positive fixint (0x00–0x7f)
decode_message_pack(<<N, Rest/binary>>) when N =< 16#7f ->
    {N, Rest};
%% Negative fixint (0xe0–0xff)
decode_message_pack(<<N, Rest/binary>>) when N >= 16#e0 ->
    {N - 256, Rest};

%% Unsigned ints
decode_message_pack(<<16#cc, N, Rest/binary>>) ->
    {N, Rest};
decode_message_pack(<<16#cd, N:16/big, Rest/binary>>) ->
    {N, Rest};
decode_message_pack(<<16#ce, N:32/big, Rest/binary>>) ->
    {N, Rest};
decode_message_pack(<<16#cf, N:64/big, Rest/binary>>) ->
    {N, Rest};

%% Signed ints
decode_message_pack(<<16#d0, N:8/signed, Rest/binary>>) ->
    {N, Rest};
decode_message_pack(<<16#d1, N:16/signed-big, Rest/binary>>) ->
    {N, Rest};
decode_message_pack(<<16#d2, N:32/signed-big, Rest/binary>>) ->
    {N, Rest};
decode_message_pack(<<16#d3, N:64/signed-big, Rest/binary>>) ->
    {N, Rest};

%% Float64
decode_message_pack(<<16#cb, F:64/float-big, Rest/binary>>) ->
    {F, Rest};
%% Float32 (less common, convert to float64)
decode_message_pack(<<16#ca, F:32/float-big, Rest/binary>>) ->
    {float(F), Rest};

%% Fixstr (0xa0–0xbf)
decode_message_pack(<<B, Rest0/binary>>) when B band 16#e0 =:= 16#a0 ->
    Len = B band 16#1f,
    <<Str:Len/binary, Rest1/binary>> = Rest0,
    {Str, Rest1};
%% str8
decode_message_pack(<<16#d9, Len, Rest0/binary>>) ->
    <<Str:Len/binary, Rest1/binary>> = Rest0,
    {Str, Rest1};
%% str16
decode_message_pack(<<16#da, Len:16/big, Rest0/binary>>) ->
    <<Str:Len/binary, Rest1/binary>> = Rest0,
    {Str, Rest1};
%% str32
decode_message_pack(<<16#db, Len:32/big, Rest0/binary>>) ->
    <<Str:Len/binary, Rest1/binary>> = Rest0,
    {Str, Rest1};

%% bin8
decode_message_pack(<<16#c4, Len, Rest0/binary>>) ->
    <<Bin:Len/binary, Rest1/binary>> = Rest0,
    {Bin, Rest1};
%% bin16
decode_message_pack(<<16#c5, Len:16/big, Rest0/binary>>) ->
    <<Bin:Len/binary, Rest1/binary>> = Rest0,
    {Bin, Rest1};
%% bin32
decode_message_pack(<<16#c6, Len:32/big, Rest0/binary>>) ->
    <<Bin:Len/binary, Rest1/binary>> = Rest0,
    {Bin, Rest1};

%% Fixarray (0x90–0x9f)
decode_message_pack(<<B, Rest0/binary>>) when B band 16#f0 =:= 16#90 ->
    Len = B band 16#0f,
    decode_message_pack_array(Rest0, Len, []);
%% array16
decode_message_pack(<<16#dc, Len:16/big, Rest0/binary>>) ->
    decode_message_pack_array(Rest0, Len, []);
%% array32
decode_message_pack(<<16#dd, Len:32/big, Rest0/binary>>) ->
    decode_message_pack_array(Rest0, Len, []);

%% Fixmap (0x80–0x8f)
decode_message_pack(<<B, Rest0/binary>>) when B band 16#f0 =:= 16#80 ->
    Len = B band 16#0f,
    decode_message_pack_map_raw(Rest0, Len, #{});
%% map16
decode_message_pack(<<16#de, Len:16/big, Rest0/binary>>) ->
    decode_message_pack_map_raw(Rest0, Len, #{});
%% map32
decode_message_pack(<<16#df, Len:32/big, Rest0/binary>>) ->
    decode_message_pack_map_raw(Rest0, Len, #{}).

decode_message_pack_array(Rest, 0, Acc) ->
    {lists:reverse(Acc), Rest};
decode_message_pack_array(Rest0, N, Acc) ->
    {Item, Rest1} = decode_message_pack(Rest0),
    decode_message_pack_array(Rest1, N - 1, [Item | Acc]).

%% Decode a MessagePack map into an Erlang map with binary keys.
%% Maps with a <<"_">> key are converted to Gleam custom types by the
%% caller (decode_message_pack_protocol and auto_decode_message_pack).
decode_message_pack_map_raw(Rest, 0, Acc) ->
    {Acc, Rest};
decode_message_pack_map_raw(Rest0, N, Acc) ->
    {Key, Rest1} = decode_message_pack(Rest0),
    {Value, Rest2} = decode_message_pack(Rest1),
    decode_message_pack_map_raw(Rest2, N - 1, Acc#{Key => Value}).

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
