-module(lily_actor_ffi).
-export([log/2, rescue/1]).

log(Level, Message) ->
    logger:log(logger_level(Level), "~ts", [Message]),
    nil.

rescue(Operation) ->
    try {ok, Operation()}
    catch
        Class:Reason ->
            {error, iolist_to_binary(io_lib:format("~p:~p", [Class, Reason]))}
    end.

logger_level(failure) -> error;
logger_level(warning) -> warning.
