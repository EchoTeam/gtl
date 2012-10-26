%%% vim: set ts=4 sts=4 sw=4 expandtab:
-module(gtl_quotas).
-behavior(gen_server).
-export([
    alloc/2,        % alloc next chunk of quota
    free/2,         % free the quota used
    set_limit/2,    % set new quota limit

    name/1,
    start_link/1,
    stop/1,
    resume/1,
    status/1,
    quota_left/1,


    % gen server callbacks
    code_change/3,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    init/1,
    terminate/2
]).

-record(state, {
    limit = [],
    used = [],
    suspended = false
}).

-define(TIMEOUT, 100). % in ms

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%   Public API
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

name(Name) when is_atom(Name) ->
    list_to_atom(atom_to_list(?MODULE) ++ "." ++ atom_to_list(Name)).

start_link(Name) when is_atom(Name) ->
    Key = list_to_atom("quota_" ++ atom_to_list(Name)),
    Limit = case application:get_env(gtl, Key) of
        {ok, L} -> L;
        _ ->
            error_logger:warning_msg("env key ~p is not set. Use 0", [Key]),
            0
    end,
    start_link(Name, Limit).

start_link(Name, Limit) ->
    gen_server:start_link({local, name(Name)}, ?MODULE, Limit, []).

stop(Name) ->
    gen_server:call(name(Name), stop).

resume(Name) ->
    gen_server:call(name(Name), resume).

status(Name) ->
    gen_server:call(name(Name), status).

quota_left(Name) ->
    {ok, Res} = status(Name),
    {ok, proplists:get_value(free, Res, [])}.

-spec alloc(atom(), integer()) -> {ok, integer()} | {error, any()}.
alloc(Name, V) when is_atom(Name) andalso is_number(V) ->
    call_safely(name(Name), {alloc, V}).

-spec free(atom(), integer()) -> {ok, integer()} | {error, any()}.
free(Name, V) when is_atom(Name) andalso is_number(V) ->
    call_safely(name(Name), {free, V}).

-spec set_limit(atom(), integer()) -> {ok, integer()} | {error, any()}.
set_limit(Name, V) when is_atom(Name) andalso is_number(V) ->
    call_safely(name(Name), {set_limit, V}).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%   Internal functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

call_safely(Ref, Msg) ->
    try gen_server:call(Ref, Msg, ?TIMEOUT)
    catch C:R -> {error, {C,R}}
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%   Gen server callbacks
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init(Limit) ->
    {ok, #state{limit = Limit, used = 0}}.

handle_call(status, _From, State) ->
    L = State#state.limit,
    U = State#state.used,
    F = L - U,
    Output = [
        {limit, L},
        {used, U},
        {free, F},
        {suspended, State#state.suspended}
    ],
    {reply, {ok, Output}, State};

handle_call(stop, _From, #state{suspended = true} = State) ->
    {reply, already_stopped, State};
handle_call(stop, _From, State) ->
    {reply, ok, State#state{suspended = true}};
handle_call(resume, _From, #state{suspended = false} = State) ->
    {reply, already_worked, State};
handle_call(resume, _From, #state{suspended = true} = State) ->
    {reply, ok, State#state{suspended = false}};

handle_call({alloc, _}, _From, #state{suspended = true} = State) ->
    {reply, {error, suspended}, State};
handle_call({alloc, V}, _From, #state{limit=L, used=U} = State) ->
    NewU = U + V,
    case NewU > L of
        true -> {reply, {error, quota_exceeded}, State};
        false -> {reply, {ok, V}, State#state{used = NewU}}
    end;

handle_call({free, V}, _From, #state{limit=_L, used=U} = State) ->
    NewU = case U - V < 0 of
        true -> 0;
        _ -> U - V
    end,
    {reply, ok, State#state{used = NewU}};

handle_call({set_limit, V}, _From, State) ->
    {reply, ok, State#state{limit = V}}.

code_change(_OldVsn, State, _Extra) -> {ok, State}.
terminate(_Reason, _State) -> ok.
handle_cast(_Request, State) -> {noreply, State}.
handle_info(_Request, State) -> {noreply, State}.
