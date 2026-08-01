-module(lily_logging_ffi).
-export([level_enabled/1]).

%% Whether a message at the given level would be emitted at the configured
%% logger level. logger:allow/2 reads the same persistent_term config as
%% logger:log/2, so this is as cheap as log/2's own gating.
level_enabled(Level) ->
    logger:allow(Level, ?MODULE).
