-module(lily_id_ffi).
-export([random_hex/1]).

random_hex(ByteCount) ->
    Bytes = crypto:strong_rand_bytes(ByteCount),
    string:lowercase(binary:encode_hex(Bytes)).
