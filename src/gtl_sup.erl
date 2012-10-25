%%% vim: set ts=4 sts=4 sw=4 expandtab:
-module(gtl_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    {ok, { {one_for_one, 5, 10}, [
        {gtl_saver, {gtl_saver, start_link, []},
            permanent, 10000, worker, [gtl_saver]},
        {quota_server.gtl_memory, {quota_server, start_link, [gtl_memory]},
            permanent, 10000, worker, [quota_server]},
        {quota_server.gtl_processes, {quota_server, start_link, [gtl_processes]},
            permanent, 10000, worker, [quota_server]}
    ]}}.

