-module(lily_server_ffi).
-export([generate_client_id/0]).

generate_client_id() ->
    Bytes = crypto:strong_rand_bytes(16),
    string:lowercase(binary:encode_hex(Bytes)).
