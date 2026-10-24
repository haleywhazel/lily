-module(lily_actor_ffi).
-export([
    log/2,
    log_allowance/1,
    rescue/1
]).

-define(LOG_WINDOW_MILLISECONDS, 10000).

log(Level, Message) ->
    logger:log(logger_level(Level), "~ts", [Message]),
    nil.

%% per process, keyed by the caller's label
log_allowance(Key) ->
    Now = erlang:monotonic_time(millisecond),
    Slot = {lily_log_allowance, Key},
    case erlang:get(Slot) of
        {Last, Held} when Now - Last < ?LOG_WINDOW_MILLISECONDS ->
            erlang:put(Slot, {Last, Held + 1}),
            {error, nil};
        {_, Held} ->
            erlang:put(Slot, {Now, 0}),
            {ok, Held};
        undefined ->
            erlang:put(Slot, {Now, 0}),
            {ok, 0}
    end.

%% one line, bounded, a hostile frame can make a reason huge
rescue(Operation) ->
    try {ok, Operation()}
    catch
        Class:Reason ->
            Text = io_lib:format(
                "~0p:~0p", [Class, Reason], [{chars_limit, 1000}]
            ),
            {error, unicode:characters_to_binary(Text)}
    end.

logger_level(failure) -> error;
logger_level(warning) -> warning.
