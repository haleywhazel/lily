-module(lily_server_ffi).
-export([generate_client_id/0, rescue/1]).

generate_client_id() ->
    Bytes = crypto:strong_rand_bytes(16),
    string:lowercase(binary:encode_hex(Bytes)).

rescue(Operation) ->
    try {ok, Operation()}
    catch
        Class:Reason ->
            {error, iolist_to_binary(io_lib:format("~p:~p", [Class, Reason]))}
    end.
