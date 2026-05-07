-module(lily_logging_ffi).
-export([level_enabled/1]).

%% Returns whether a message at the given level would be emitted by the
%% currently configured logger primary level. logger:allow/2 consults the
%% same persistent_term-backed config that logger:log/2 checks, so this is
%% as cheap as the gating done inside log/2 itself.
level_enabled(Level) ->
    logger:allow(Level, ?MODULE).
