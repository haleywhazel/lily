-module(lily_test_ref_ffi).

-export([new_ref/1, get_ref/1, set_ref/2]).

%% Create a new mutable reference using a unique Erlang ref as the process
%% dictionary key. Each call produces a distinct, non-colliding key.
new_ref(Initial) ->
    Key = make_ref(),
    erlang:put(Key, Initial),
    Key.

%% Read the current value from the reference.
get_ref(Key) ->
    erlang:get(Key).

%% Write a new value to the reference. Returns nil (Gleam's unit).
set_ref(Key, Value) ->
    erlang:put(Key, Value),
    nil.
