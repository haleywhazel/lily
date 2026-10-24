%%% Reflects values into Reflected trees and back. Wire names are PascalCase.
%%% Decoding uses binary_to_existing_atom so unknown names never leak atoms.

-module(lily_codec_ffi).

-export([
    construct/1,
    copy_string/1,
    int_in_range/1,
    int_to_finite_float/1,
    passthrough/1,
    reflect/1,
    refuse_float/0,
    refuse_int/1,
    refuse_string/0
]).

%% the wire range on both targets, what a JavaScript peer holds exactly
-define(MAX_WIRE_INT, 9007199254740991).

%%% ============================================================================
%%% EXPORTED FUNCTIONS
%%% ============================================================================

construct(Reflected) ->
    try
        {ok, construct_inner(Reflected)}
    catch
        _:_ -> {error, nil}
    end.

%% a sub-binary keeps the whole frame it was sliced from alive
copy_string(Binary) ->
    case binary:referenced_byte_size(Binary) > byte_size(Binary) of
        true -> binary:copy(Binary);
        false -> Binary
    end.

int_in_range(Value) ->
    Value >= -?MAX_WIRE_INT andalso Value =< ?MAX_WIRE_INT.

int_to_finite_float(Value) ->
    try
        {ok, float(Value)}
    catch
        _:_ -> {error, nil}
    end.

passthrough(Value) -> Value.

reflect(nil) ->
    reflected_nil;
reflect(Value) when is_boolean(Value) ->
    {reflected_bool, Value};
reflect(Value) when is_integer(Value) ->
    {reflected_integer, Value};
reflect(Value) when is_float(Value) ->
    {reflected_float, Value};
reflect(Value) when is_binary(Value) ->
    {reflected_string, Value};
reflect([]) ->
    {reflected_list, []};
reflect(List) when is_list(List) ->
    {reflected_list, [reflect(Item) || Item <- List]};
reflect(Value) when is_atom(Value) ->
    Name = snake_to_pascal(atom_to_binary(Value, utf8)),
    {reflected_constructor, Name, []};
reflect({set, Inner}) when is_map(Inner) ->
    %% before the tuple clause, `set` would look like a custom-type tag
    Members = [reflect(Member) || Member <- maps:keys(Inner)],
    {reflected_set, Members};
reflect(Value) when is_tuple(Value), tuple_size(Value) > 0 ->
    %% atom first element is a custom-type tag, otherwise a raw tuple
    First = element(1, Value),
    case is_atom(First) of
        true ->
            Name = snake_to_pascal(atom_to_binary(First, utf8)),
            Size = tuple_size(Value),
            Fields = collect_fields(Value, 2, Size, []),
            {reflected_constructor, Name, Fields};
        false ->
            Size = tuple_size(Value),
            Fields = collect_fields(Value, 1, Size, []),
            {reflected_tuple, Fields}
    end;
reflect(Map) when is_map(Map) ->
    Entries = [
        {reflect(Key), reflect(EntryValue)}
     || {Key, EntryValue} <- maps:to_list(Map)
    ],
    {reflected_dict, Entries};
%% a bitstring that isn't whole bytes has no wire form
reflect(Value) when is_bitstring(Value) ->
    erlang:error({lily_unencodable, bitstring});
reflect(_) ->
    reflected_nil.

refuse_float() ->
    erlang:error(lily_float_not_finite).

refuse_int(Value) ->
    erlang:error({lily_int_out_of_range, Value}).

refuse_string() ->
    erlang:error(lily_string_not_well_formed).

%%% ============================================================================
%%% PRIVATE FUNCTIONS
%%% ============================================================================

collect_fields(_Value, Index, Size, Accumulator) when Index > Size ->
    lists:reverse(Accumulator);
collect_fields(Value, Index, Size, Accumulator) ->
    Field = reflect(element(Index, Value)),
    collect_fields(Value, Index + 1, Size, [Field | Accumulator]).

construct_inner(reflected_nil) ->
    nil;
construct_inner({reflected_bool, Value}) ->
    Value;
construct_inner({reflected_integer, Value}) ->
    Value;
construct_inner({reflected_float, Value}) ->
    Value;
construct_inner({reflected_string, Value}) ->
    copy_string(Value);
construct_inner({reflected_list, Items}) ->
    [construct_inner(Item) || Item <- Items];
construct_inner({reflected_tuple, Fields}) ->
    list_to_tuple([construct_inner(Field) || Field <- Fields]);
construct_inner({reflected_dict, Entries}) ->
    maps:from_list(
        [
            {construct_inner(Key), construct_inner(EntryValue)}
         || {Key, EntryValue} <- Entries
        ]
    );
construct_inner({reflected_set, Members}) ->
    %% stdlib from_list keeps the token representation in sync
    'gleam@set':from_list([construct_inner(Member) || Member <- Members]);
construct_inner({reflected_constructor, Name, Fields}) ->
    SnakeName = pascal_to_snake(Name),
    Tag = binary_to_existing_atom(SnakeName, utf8),
    case Fields of
        [] ->
            Tag;
        _ ->
            FieldValues = [construct_inner(Field) || Field <- Fields],
            list_to_tuple([Tag | FieldValues])
    end.

pascal_to_snake(<<>>) ->
    <<>>;
pascal_to_snake(Binary) ->
    iolist_to_binary(pascal_to_snake(Binary, [])).

pascal_to_snake(<<>>, Accumulator) ->
    lists:reverse(Accumulator);
pascal_to_snake(<<Character, Rest/binary>>, Accumulator) when
    Character >= $A, Character =< $Z
->
    Lower = Character + 32,
    case Accumulator of
        [] -> pascal_to_snake(Rest, [Lower]);
        _ -> pascal_to_snake(Rest, [Lower, $_ | Accumulator])
    end;
pascal_to_snake(<<Character, Rest/binary>>, Accumulator) ->
    pascal_to_snake(Rest, [Character | Accumulator]).

snake_to_pascal(<<>>) ->
    <<>>;
snake_to_pascal(Binary) ->
    iolist_to_binary(snake_to_pascal(Binary, [], true)).

snake_to_pascal(<<>>, Accumulator, _CapitaliseNext) ->
    lists:reverse(Accumulator);
snake_to_pascal(<<$_, Rest/binary>>, Accumulator, _CapitaliseNext) ->
    snake_to_pascal(Rest, Accumulator, true);
snake_to_pascal(<<Character, Rest/binary>>, Accumulator, true) when
    Character >= $a, Character =< $z
->
    Upper = Character - 32,
    snake_to_pascal(Rest, [Upper | Accumulator], false);
snake_to_pascal(<<Character, Rest/binary>>, Accumulator, _CapitaliseNext) ->
    snake_to_pascal(Rest, [Character | Accumulator], false).
