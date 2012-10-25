%%% vim: set ts=4 sts=4 sw=4 expandtab:
-module(gtl_app).

-behaviour(application).

%% Application callbacks
-export([start/0, start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

%TODO: create proper entry point
start() ->
    application:start(gtl).


start(_StartType, _StartArgs) ->
    gtl_sup:start_link().

stop(_State) ->
    ok.
