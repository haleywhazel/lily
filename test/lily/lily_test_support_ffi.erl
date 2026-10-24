-module(lily_test_support_ffi).

-export([new_ref/1, get_ref/1, set_ref/2, new_shared/1, get_shared/1,
         set_shared/2, register_fixtures/0,
         mark_stopped/1, is_stopped/1, capture_log_levels/1, log/2]).

%% no constructor registry on Erlang
register_fixtures() ->
    nil.

%% mutable ref, a fresh make_ref() as the process dictionary key
new_ref(Initial) ->
    Key = make_ref(),
    erlang:put(Key, Initial),
    Key.

get_ref(Key) ->
    erlang:get(Key).

set_ref(Key, Value) ->
    erlang:put(Key, Value),
    nil.

%% readable from any process, for state a server or topic reads
new_shared(Initial) ->
    Key = {lily_test_shared, make_ref()},
    persistent_term:put(Key, Initial),
    Key.

get_shared(Key) ->
    persistent_term:get(Key).

set_shared(Key, Value) ->
    persistent_term:put(Key, Value),
    nil.

%% settling a stopped server skips the call that would log a crash
mark_stopped(Server) ->
    erlang:put({lily_test_stopped, Server}, true),
    nil.

is_stopped(Server) ->
    erlang:get({lily_test_stopped, Server}) =:= true.

%% {Level, Message} pairs logged by the thunk, level as a binary
%% primary level lowered to debug meanwhile so nothing is filtered
capture_log_levels(Thunk) ->
    Id = lily_test_support_capture,
    Previous = maps:get(level, logger:get_primary_config()),
    ok = logger:set_primary_config(level, debug),
    ok = logger:add_handler(Id, ?MODULE, #{config => #{pid => self()}}),
    try
        Thunk(),
        collect([])
    after
        logger:remove_handler(Id),
        logger:set_primary_config(level, Previous)
    end.

collect(Seen) ->
    receive
        {lily_test_support_captured, Level, Message} ->
            collect([{atom_to_binary(Level), Message} | Seen])
    after 0 ->
        lists:reverse(Seen)
    end.

%% logger handler callback
log(#{level := Level, msg := {string, Chardata}}, #{config := #{pid := Pid}}) ->
    Pid ! {lily_test_support_captured, Level, unicode:characters_to_binary(Chardata)},
    ok;
log(#{level := Level, msg := {report, Report}}, #{config := #{pid := Pid}}) ->
    Text = unicode:characters_to_binary(io_lib:format("~p", [Report])),
    Pid ! {lily_test_support_captured, Level, Text},
    ok;
log(#{level := Level, msg := {Format, Arguments}}, #{config := #{pid := Pid}}) ->
    Text = unicode:characters_to_binary(io_lib:format(Format, Arguments)),
    Pid ! {lily_test_support_captured, Level, Text},
    ok;
log(_Event, _Config) ->
    ok.
