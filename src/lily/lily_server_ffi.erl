-module(lily_server_ffi).
-export([rescue/1]).

rescue(Operation) ->
    try {ok, Operation()}
    catch
        Class:Reason ->
            {error, iolist_to_binary(io_lib:format("~p:~p", [Class, Reason]))}
    end.
