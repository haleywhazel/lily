-module(lily_server_ffi).
-export([
    gauge_add/2,
    gauge_release/1,
    gauge_set/2,
    gauge_value/1,
    message_queue_length/1,
    monotonic_milliseconds/0,
    new_gauge/0,
    random_hex/1,
    unique_integer/0
]).

gauge_add(Gauge, Delta) ->
    atomics:add_get(Gauge, 1, Delta).

%% one off unless already zero, a release can't race another below it
gauge_release(Gauge) ->
    case atomics:get(Gauge, 1) of
        Value when Value > 0 ->
            case atomics:compare_exchange(Gauge, 1, Value, Value - 1) of
                ok -> nil;
                _ -> gauge_release(Gauge)
            end;
        _ ->
            nil
    end.

gauge_set(Gauge, Value) ->
    atomics:put(Gauge, 1, Value),
    nil.

gauge_value(Gauge) ->
    atomics:get(Gauge, 1).

message_queue_length(Pid) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, Length} -> Length;
        undefined -> 0
    end.

monotonic_milliseconds() ->
    erlang:monotonic_time(millisecond).

new_gauge() ->
    atomics:new(1, [{signed, true}]).

random_hex(ByteCount) ->
    Bytes = crypto:strong_rand_bytes(ByteCount),
    string:lowercase(binary:encode_hex(Bytes)).

unique_integer() ->
    erlang:unique_integer([positive, monotonic]).
