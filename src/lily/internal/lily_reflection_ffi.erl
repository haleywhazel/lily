%%% Reflection FFI for Erlang. Inspects Gleam runtime values (atoms and
%%% tagged tuples are how Gleam custom types compile on Erlang) and produces
%%% target-neutral Reflected trees that the pure-Gleam codec can walk.
%%%
%%% Constructor names: Gleam compiles PascalCase variants to snake_case
%%% atoms on Erlang. The wire format uses PascalCase to match the JavaScript
%%% representation, so we convert in both directions here.
%%%
%%% Decoding uses binary_to_existing_atom so unknown constructor names
%%% (e.g. from a stale client speaking a different schema) raise badarg
%%% rather than leaking a fresh atom into the table. The construct/1 wrapper
%%% catches that and surfaces it as {error, nil}.

-module(lily_reflection_ffi).

-export([
    reflect/1,
    construct/1,
    passthrough/1
]).

%% Identity passthrough used to reinterpret Dynamic as a concrete type after
%% reflection has reconstructed the value. Erlang values do not carry static
%% types at runtime, so the cast is sound.
passthrough(Value) -> Value.

%%% ============================================================================
%%% EXPORTED FUNCTIONS
%%% ============================================================================

reflect(undefined) ->
    {reflected_nil};
reflect(nil) ->
    {reflected_nil};
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
reflect(Value) when is_tuple(Value) ->
    Tag = element(1, Value),
    Name = snake_to_pascal(atom_to_binary(Tag, utf8)),
    Size = tuple_size(Value),
    Fields = collect_fields(Value, 2, Size, []),
    {reflected_constructor, Name, Fields};
reflect(_) ->
    {reflected_nil}.

construct(Reflected) ->
    try
        {ok, construct_inner(Reflected)}
    catch
        _:_ -> {error, nil}
    end.

%%% ============================================================================
%%% PRIVATE FUNCTIONS
%%% ============================================================================

construct_inner({reflected_nil}) ->
    nil;
construct_inner({reflected_bool, Value}) ->
    Value;
construct_inner({reflected_integer, Value}) ->
    Value;
construct_inner({reflected_float, Value}) ->
    Value;
construct_inner({reflected_string, Value}) ->
    Value;
construct_inner({reflected_list, Items}) ->
    [construct_inner(Item) || Item <- Items];
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

collect_fields(_Value, Index, Size, Accumulator) when Index > Size ->
    lists:reverse(Accumulator);
collect_fields(Value, Index, Size, Accumulator) ->
    Field = reflect(element(Index, Value)),
    collect_fields(Value, Index + 1, Size, [Field | Accumulator]).

%%% Convert PascalCase binary to snake_case binary.
%%% e.g. <<"RefreshStats">> becomes <<"refresh_stats">>.
pascal_to_snake(<<>>) ->
    <<>>;
pascal_to_snake(Bin) ->
    iolist_to_binary(pascal_to_snake(Bin, [])).

pascal_to_snake(<<>>, Accumulator) ->
    lists:reverse(Accumulator);
pascal_to_snake(<<C, Rest/binary>>, Accumulator) when C >= $A, C =< $Z ->
    Lower = C + 32,
    case Accumulator of
        [] -> pascal_to_snake(Rest, [Lower]);
        _ -> pascal_to_snake(Rest, [Lower, $_ | Accumulator])
    end;
pascal_to_snake(<<C, Rest/binary>>, Accumulator) ->
    pascal_to_snake(Rest, [C | Accumulator]).

%%% Convert snake_case binary to PascalCase binary.
%%% e.g. <<"refresh_stats">> becomes <<"RefreshStats">>.
snake_to_pascal(<<>>) ->
    <<>>;
snake_to_pascal(Bin) ->
    iolist_to_binary(snake_to_pascal(Bin, [], true)).

snake_to_pascal(<<>>, Accumulator, _CapitaliseNext) ->
    lists:reverse(Accumulator);
snake_to_pascal(<<$_, Rest/binary>>, Accumulator, _CapitaliseNext) ->
    snake_to_pascal(Rest, Accumulator, true);
snake_to_pascal(<<C, Rest/binary>>, Accumulator, true) when C >= $a, C =< $z ->
    Upper = C - 32,
    snake_to_pascal(Rest, [Upper | Accumulator], false);
snake_to_pascal(<<C, Rest/binary>>, Accumulator, _CapitaliseNext) ->
    snake_to_pascal(Rest, [C | Accumulator], false).
