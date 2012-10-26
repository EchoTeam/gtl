%%% vim: set ts=4 sts=4 sw=4 expandtab:
%% @doc
%% The main module that contains all the API to the GTL
%% @end
%%
%% binary bloated Global Transactional Logger.
%%
%% o Marks related log entries using a single transaction identifier.
%% o Records time of the entries.
%% o When the time exceeds certain predefined amount, the transaction is marked
%%   as "slow".
%% o After transaction finishes explicitly or implicitly (by link failure),
%%   the slow transactions are logged and fast transactions are ignored.
%% o Logger dumps all the binary data associated with a transaction.
%%
%% EXAMPLE:
%%
%%
%% 69> gtl:log(start_logging).
%% ok
%% 70> gtl:spawn_opt(fun() -> gtl:log("some subsystem's log") end, []).
%% <0.40.0>
%% 71> gtl:log(stop_logging).
%% ok.
%% 72> gtl:get_log().
%% [{"0.2",<0.48.0>,nonode@nohost,{1341,673500,869669},"2012/07/07 19:05:00",start_logging},
%%  {"0.2",<0.48.0>,nonode@nohost,{1341,673519,607523},"2012/07/07 19:05:19",{gtl,register_child,<0.52.0>}},
%%  {"0.2",<0.52.0>,nonode@nohost,{1341,673519,606950},"2012/07/07 19:05:19","some subsystem's log"},
%%  {"0.2",<0.52.0>,nonode@nohost,{1341,673519,607932},"2012/07/07 19:05:19",{gtl,handle_down_client,<0.51.0>}},
%%  {"0.2",<0.52.0>,nonode@nohost,{1341,673520,608662},"2012/07/07 19:05:20",{gtl,handle_stop_clerk,<0.52.0>}},
%%  {"0.2",<0.48.0>,nonode@nohost,{1341,673520,609024},"2012/07/07 19:05:20",{gtl,handle_down_child,<0.52.0>}},
%%  {"0.2",<0.48.0>,nonode@nohost,{1341,673527,85996},"2012/07/07 19:05:27",stop_logging}]



-module(gtl).
-behavior(gen_server).
-export([

    % External functions
    log/1,          % Remember a particular term
    mark/0,         % Mark a transaction as interesting (loggable). (=mark('_'))
    mark/1,         % Mark and specify a filename where it should be saved to

    maybe_mark/0,   % Mark if current process has already been logged,
    maybe_mark/1,   %      do nothing otherwise
    maybe_log/1,    % The same for "log"

    mark_if_slow/2, % Mark a transaction if it went slow.
    mark_if_slow/3,
    spawn/1,
    spawn_opt/2,    % Transaction tree preserving spawn_opt wrapper.

    % debug functions
    status/0,       % get status of current log clerk (if any). for debug mainly
    get_log/0,      % get the log (debug also)

    % external functions for work with clerk info
    get_clerk_info/0,
    erase_clerk_info/0,
    set_clerk_info/1,
    set_parent_clerk_info/1,

    % if the client process lives too long
    % we should stop follow it and disconnect gtl process
    deregister_client/0,

    % info about quota for a gtl on each node
    quota_status/0,

    % handle process_ttl of gtl processes
    set_ttl/1,  % in msec
    bump_ttl/0,  % when publishing in amqs (see comment below)

    is_process_alive/1
]).

% gen_server functions
-export([
    code_change/3,
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-define(VERSION,"0.1").
-define(MSG(Clerk, Time, Msg), term_to_binary({?VERSION, Clerk, node(), Time, gtl_util:now2string(Time), Msg})).

% gtl process lives while its client is alive. After that he lives
%     ?PROCESS_TTL milliseconds more and dies
% NB: jamq_publisher bumps this ttl to 10 seconds
% NB: in any case, a gtl process is closed forcedly after
%     ?FORCED_TIMEOUT milliseconds
-define(PROCESS_TTL, 1 * 1000).   % 1 sec
-define(AMQ_TIMEOUT, 10 * 1000).   % 10 sec
-define(FORCED_TIMEOUT, 15 * 60 * 1000).   % 15 min
-define(DEFAULT_MARK, "_").
-define(MEMORY_CHUNK, 1000). % in bytes


% @doc Get the current status of quota server
quota_status() ->
    [ {K, Status} ||
        K <- [ memory, processes ],
        {ok, Status} <- [gtl_quotas:status(K)]
    ].

% @private 
% @doc create logger and call gen_server:cast
cast(Msg) ->
    case get_or_create_clerk_pid() of
        undefined -> undefined;
        Pid -> gen_server:cast(Pid, Msg)
    end.

% @private 
% @doc cast only if clerk or parent_clerk exists (see cast/1)
maybe_cast(Msg) ->
    Pid = case {get_clerk_pid(), get_parent_clerk_pid()} of
        {undefined, undefined} -> undefined;
        {undefined, _} -> get_or_create_clerk_pid();
        {P, _} -> P
    end,
    case Pid of
        undefined -> nop;
        Pid -> gen_server:cast(Pid, Msg)
    end.

%% @doc Remember a particular term.
log(Term) ->
    %error_logger:info_msg("~p log:~p~n", [self(), Term]),
    cast({record, now(), Term}).

% @doc same as 'log', but executed only if a logger has already been started
maybe_log(Term) ->
    %error_logger:info_msg("~p maybe_log:~p~n", [self(), Term]),
    maybe_cast({record, now(), Term}).

% @doc
% By default, no transaction logs are ever recorded (logged).
% The mark() function allows to mark a transaction as "interesting enough"
% to be recorded when it finishes.
mark() -> mark(?DEFAULT_MARK).
mark(Mark) when is_list(Mark) -> % string for marks. used for naming files
    %error_logger:info_msg("~p mark as '~p'~nClerkInfo:~p~n", [self(), Mark, get_clerk_info()]),
    gtl:log({gtl, marked, Mark}),
    cast({marks, [Mark]}).

% @doc same as 'mark', but executed only if a logger has already been started
maybe_mark() -> maybe_mark(?DEFAULT_MARK).
maybe_mark(Mark) when is_list(Mark) ->
    %error_logger:info_msg("~p maybe_mark as '~p'~nClerkInfo:~p~n", [self(), Mark, get_clerk_info()]),
    gtl:maybe_log({gtl, marked, Mark}),
    maybe_cast({marks, [Mark]}).

% @doc mark transaction if a the call to function F takes too much time
mark_if_slow(Timeout, F) -> mark_if_slow(Timeout, F, ?DEFAULT_MARK).
mark_if_slow(Timeout, F, Mark) ->
    Start = now(),
    gtl:log({started, mark_if_slow, F, Start}),
    Result = try F()
        catch C:R ->
            gtl:log({excepted, mark_if_slow, F, now(), {C,R}}),
            erlang:raise(C, R, erlang:get_stacktrace())
    end,
    Stop = now(),
    Elapsed = timer:now_diff(Stop, Start) div 1000,
    {Fin, Mark1} = case Elapsed > Timeout of
        true -> gtl:mark(Mark), {finished_slow, Mark};
        false -> {finished_fast, ?DEFAULT_MARK}
    end,
    gtl:log({Fin, mark_if_slow, F,
            Start, '->', Stop, '=', Elapsed, Mark1}),
    Result.

% @doc erlang:spawn replacer with GTL support
spawn(Fun) -> ?MODULE:spawn_opt(Fun, []).

% @doc erlang:spawn_opt replacer with GTL support
spawn_opt(Fun, Options) ->
    case get_clerk_pid() of
        undefined -> erlang:spawn_opt(Fun, Options);
        _ ->
            %error_logger:info_msg("~p call spawn_opt~n", [self()]),
            ClerkInfo = get_clerk_info(),
            erlang:spawn_opt(
                fun() ->
                        %error_logger:info_msg("~p inside spawn_opt~n", [self()]),
                        gtl:set_parent_clerk_info(ClerkInfo),
                        Fun()
                end,
                Options)
    end.

% @doc remove from worker any info about GTL.
% this is useful for gen_servers and other long-live processes
deregister_client() ->
    cast({deregister_client, self()}).

% @doc status about current logger (if any)
status() ->
    case get_clerk_pid() of
        undefined -> undefined;
        Pid -> gen_server:call(Pid, status)
    end.
% @doc get log from current logger (if any)
get_log() ->
    case get_clerk_pid() of
        undefined -> undefined;
        Pid -> gen_server:call(Pid, get_log)
    end.

clerk_keys() -> [ '$gtl_clerk',  '$gtl_parent_clerk'].

% @doc get info from about current logger
get_clerk_info() ->
    [ {K, get(K)} || K <- clerk_keys() ].

% @doc erase info from worker about current logger
erase_clerk_info() ->
    [ {K, erase(K)} || K <- clerk_keys() ].

% @doc save info into the worker about logger
set_clerk_info(Info) ->
    [ put(K,V) || {K, V} <- Info ],
    ok.

set_parent_clerk_info(ClerkInfo) ->
    cling_to([ proplists:get_value(K, ClerkInfo) || K <- clerk_keys() ]).

cling_to([]) -> failed;
cling_to([undefined | Rest]) -> cling_to(Rest);
cling_to([Pid | Rest]) ->
    case ?MODULE:is_process_alive(Pid) of
        false -> cling_to(Rest);
        _ ->
            %error_logger:info_msg("~p clung to pid:~p~n", [self(), Pid]),
            put('$gtl_parent_clerk', Pid),
            ok
    end.

% @doc
% When a process publishes an amq-message, it might immediately die
%  (before an amq-subscriber handle the message). Clerk for such a
%  process should wait until gtl clerk for the subscriber appears.
% For the performance reason this delay for the local has been decreased
%  as we don't have large amount of data in our tests
bump_ttl() ->
    TTL = ?AMQ_TIMEOUT,
    set_ttl(TTL).


% @doc
% ask a gtl process to stay alive for a longer (shorter) period of time
set_ttl(T) when is_integer(T) andalso T < 0 -> ok;
set_ttl(T) when is_integer(T) -> maybe_cast({ttl, T}).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% INTERNAL FUNCTIONS
%%%%%%%%%%%%%%%%%%%%%%%%%%%%

get_proplist_values(Keys, PL, Default) ->
    [proplists:get_value(K, PL, Default) || K <- Keys].

replace_proplist_values(Values, PL) ->
    lists:foldl(
        fun ({K,V}, Acc) -> lists:keystore(K, 1, Acc, {K,V});
            (_, Acc) -> Acc
        end, PL, Values).

is_process_alive(Pid) ->
    is_pid(Pid) andalso
        ((try erlang:is_process_alive(Pid) catch _:_ -> false end)
            orelse
         (rpc:call(node(Pid), erlang, is_process_alive, [Pid]) == true)).

%% Obtain (or create) pid() of a clerk process which records messages.
-spec get_or_create_clerk_pid() -> undefined | pid().
get_or_create_clerk_pid() ->
    case get_clerk_pid() of
        undefined -> start_new_clerk(alloc_proc());
        ClerkPid -> ClerkPid
    end.

%% Obtain pid() of a clerk process which records messages.
-spec get_clerk_pid() -> undefined | pid().
get_clerk_pid() -> get('$gtl_clerk').
get_parent_clerk_pid() -> get('$gtl_parent_clerk').

start_new_clerk({ok, _V}) ->
    Args = {get_parent_clerk_pid(), self()},
    case gen_server:start(?MODULE, Args, [{timeout, 1000}]) of
        {ok, ClerkPid} ->
            %error_logger:info_msg("get_clerk_info:~p~nstart_new_clerk ~p for client ~p~n", [get_clerk_info(), ClerkPid, self()]),
            put('$gtl_clerk', ClerkPid),
            ClerkPid;
        _E ->
            error_logger:warning_msg("can't start new clerk: gen_server:start() returned ~p~n", [_E]),
            undefined
    end;
start_new_clerk(Error) ->
    error_logger:warning_msg("can't start new clerk: alloc_proc() returned ~p~n", [Error]),
    case get_parent_clerk_pid() of
        Pid when is_pid(Pid) -> gen_server:cast(Pid, {record, ?MSG(undefined, now(), {gtl, alloc_proc, faled})});
        _ -> nop
    end,
    undefined.

% clerk state
new_clerk_state(Values) ->
    Default = [
        {ttl, ?PROCESS_TTL},
        {timer, undefined},
        {start_time, now()},
        {gtl_clerk, self()},  %NB! we use it in jamq_publisher
        {gtl_parent_clerk, undefined}, % parent clerk for current clerk
        {client_mref, undefined},   % the real process that logs some info
        {client_pid, undefined}, % XXX: is it needed really?
        {marked, false},
        {marks, sets:new()}, % "_" as default
        {log, []},
        {log_length, 0},
        {memory_free, 0},
        {proc_free, 0},
        {memory_used, 0},
        {proc_used, 0},
        {childs, []}   % child clerks for which current clerk is parent
    ],
    repl_keys(Values, Default).
% just aliases
repl_keys(V,PL) -> replace_proplist_values(V,PL).
get_value(K,PL) -> proplists:get_value(K,PL).
get_values(Ks,PL) -> get_proplist_values(Ks,PL,undefined).

init({ParentPid, ClientPid}) ->
    {ok, Tref} = timer:send_after(?FORCED_TIMEOUT, forced_timeout),
    State = new_clerk_state([
        {timer, Tref},
        {gtl_parent_clerk, ParentPid},
        {proc_used, 1},
        {client_mref, erlang:monitor(process, ClientPid)},
        {client_pid, ClientPid}]),
    gen_server:cast(ParentPid, {register_child, self()}),
    % make all possibly long initialization steps asynchronously
    timer:send_after(0, async_init),
    {ok, State, get_value(ttl,State)}.

alloc_memory(Size) ->
    Chunk = case Size > ?MEMORY_CHUNK of
        true -> Size;
        _ -> ?MEMORY_CHUNK
    end,
    %error_logger:info_msg("~p alloc_memory(~p)~n", [self(), Chunk]),
    gtl_quotas:alloc(memory, Chunk).

alloc_proc() ->
    %error_logger:info_msg("~p alloc_proc(~p)~n", [self(), 1]),
    gtl_quotas:alloc(processes, 1).

free_memory(0) -> ok;
free_memory(Size) ->
    %error_logger:info_msg("~p free_memory(~p)~n", [self(), Size]),
    gtl_quotas:free(memory, Size).

free_proc(0) -> ok;
free_proc(Size) ->
    %error_logger:info_msg("~p free_proc(~p)~n", [self(), Size]),
    gtl_quotas:free(processes, Size).

handle_record({record, R}, Size, MFree, S) when MFree < Size ->
    case alloc_memory(Size) of
        {ok, V} ->
            MFreeN = MFree + V,
            NS = repl_keys([ {memory_free, MFreeN} ], S),
            handle_record({record, R}, Size, MFreeN, NS);
        _Err ->
            {noreply, S, get_value(ttl,S)}
    end;
handle_record({record, R}, Size, MFree, S) ->
    NS = repl_keys([
            {log, [R | get_value(log, S)]},
            {memory_free, MFree - Size},
            {memory_used, get_value(memory_used,S) + Size}
        ], S),
    {noreply, NS, get_value(ttl,NS)}.


handle_cast({record, Time, Msg}, State) ->
    Clerk = get_value(gtl_clerk, State),
    handle_cast({record, ?MSG(Clerk, Time, Msg)}, State);
% XXX: Backward compatibility block begins
handle_cast({record, R}, State) when not is_binary(R) ->
    handle_cast({record, term_to_binary(R)}, State);
% XXX: Backward compatibility block ends
handle_cast({record, R}, State) ->
    Size = byte_size(R),
    MemoryFree = get_value(memory_free, State),
    handle_record({record, R}, Size, MemoryFree, State);

handle_cast({records, Msgs}, State) ->
    Proc = fun (E, S) ->
            {noreply, NS, _} = handle_cast({record, E}, S),
            NS
    end,
    NS = lists:foldr(Proc, State, Msgs),
    {noreply, NS, get_value(ttl,NS)};

handle_cast({marks, []}, State) ->
    {noreply, State, get_value(ttl,State)};
handle_cast({marks, Marks}, State) ->
    %error_logger:info_msg("handle_cast marks ~p~n", [Marks]),

    % hack. mark parent clerk instantly.
    % correct behavior: we should pass marks from child to parent
    % only when child dies
    % but as for now we can't pass clerk_pid through as_pipeline correctly
    % see comment in as_pipeline
    case get_value(gtl_parent_clerk, State) of
        undefined ->
            ok;
        Parent ->
            case ?MODULE:is_process_alive(Parent) of
                true ->
                    gen_server:cast(Parent, {marks, Marks});
                _ -> ok
            end
    end,

    Ts = sets:from_list(Marks),
    Marks_new = sets:union(get_value(marks, State), Ts),
    NS = repl_keys([{marked, true}, {marks,Marks_new}], State),
    {noreply, NS, get_value(ttl,NS)};

handle_cast({register_child, Pid}, S) ->
    %error_logger:info_msg("~p register_child ~p~n", [self(), Pid]),
    Childs = get_value(childs, S),
    [Log, Clerk] = get_values([log, gtl_clerk], S),
    LastMsg = ?MSG(Clerk, now(), {gtl, register_child, Pid}),
    LogN = [LastMsg | Log],
    ChildRef = erlang:monitor(process, Pid),
    ChildsN = [ChildRef | Childs],
    NS = repl_keys([
            {log, LogN},
            {childs, ChildsN}
        ], S),
    {noreply, NS, get_value(ttl,NS)};

handle_cast({ttl, T}, S) ->
    %error_logger:info_msg("~p updated ttl to ~p~n", [self(), T]),
    NS = repl_keys([{ttl, T}], S),
    {noreply, NS, get_value(ttl,NS)};

handle_cast({deregister_client, Pid}, S) ->
    %error_logger:info_msg("~p deregister_client ~p~n", [self(), Pid]),
    NS = handle_down_client(Pid, S),
    {noreply, NS, get_value(ttl,NS)};

handle_cast(_, S) -> {noreply, S, get_value(ttl,S)}.

handle_call(status,_, S) ->
    Pid = get_value(gtl_clerk, S),
    Ret = repl_keys([
            {log, "skip it as it might be long"},
            {marks, sets:to_list(get_value(marks, S))},
            {log_length, length(get_value(log, S))}
        ], S),
    {reply, {Pid, Ret}, S, get_value(ttl,S)};
handle_call(get_log,_, S) ->
    Log = [ binary_to_term(L) || L <- lists:reverse(get_value(log, S)) ],
    {reply, Log, S, get_value(ttl,S)};
handle_call(get_marks,_, S) ->
    {reply, sets:to_list(get_value(marks, S)), S, get_value(ttl,S)};
handle_call(_,_, S) -> {noreply, S, get_value(ttl,S)}.

% postponed init is used to handle possibly long init procedure
handle_info(async_init, S) ->
    NS = case get_value(gtl_parent_clerk, S) of
        undefined -> S;
        Parent ->
            case (catch gen_server:call(Parent, get_marks)) of
                [] -> S;
                Marks when is_list(Marks) ->

                    %error_logger:info_msg("~p: async_init set marks to ~p~n", [self(), Marks]),
                    Ts = sets:from_list(Marks),
                    Marks_new = sets:union(get_value(marks, S), Ts),
                    %error_logger:info_msg("handle_info async init marks:~p~n" ,[ Marks_new]),
                    repl_keys([{marked, true}, {marks,Marks_new}], S);
                V ->
                    error_logger:warning_msg("Can't get parent marks:~p~n", [V]),
                    S
            end
    end,
    {noreply, NS, get_value(ttl,NS)};

% after each ?PROCESS_TTL milliseconds check if we should stop clerk
handle_info(timeout, S) ->
    case get_values([client_mref, childs], S) of
        [undefined, []] -> % clerk doesn't have childs, and client is dead
            handle_stop_clerk(S);
        _ -> % some childs are still alive, wait for them
            {noreply, S, get_value(ttl,S)}
    end;

% if ?FORCED_TIMEOUT is over, close everything
handle_info(forced_timeout, S) ->
    handle_stop_clerk(S);

% we monitor client and child clerks, one of them is died
handle_info({'DOWN', MRef, process, Pid, _Info} = _Msg, S) ->
    %error_logger:info_msg("~p: Info 'DOWN' received:~p~n", [self(), _Msg]),
    Client_mref = get_value(client_mref, S),
    NS = case MRef == Client_mref of
        true -> handle_down_client(Pid, S);
        _ -> handle_down_child(MRef, Pid, S)
    end,
    {noreply, NS, get_value(ttl,NS)};

handle_info(Info,S) ->
    error_logger:warning_msg("~p: Info received:~p~n", [self(), Info]),
    {noreply, S, get_value(ttl,S)}.

handle_down_child(MRef, Pid, S) ->
    % at this point we've already received all info from child clerk
    % so we should either die (if no childs left) or wait for other childs
    %error_logger:info_msg("~p: child is down~n", [self()]),
    Childs = get_value(childs, S),
    [Log, Clerk] = get_values([log, gtl_clerk], S),
    LastMsg = ?MSG(Clerk, now(), {gtl, handle_down_child, Pid}),
    ChildsN = lists:delete(MRef, Childs),
    NS = repl_keys([
            {log, [LastMsg | Log]},
            {childs, ChildsN}
        ], S),
    NS.

handle_down_client(Pid, S) ->
    %error_logger:info_msg("~p: client is down~n", [self()]),
    [Log, Clerk] = get_values([log, gtl_clerk], S),
    LastMsg = ?MSG(Clerk, now(), {gtl, handle_down_client, Pid}),
    NS = repl_keys([
            {log, [LastMsg | Log]},
            {client_mref, undefined}
        ], S),
    NS.

handle_stop_clerk(S) ->
    %error_logger:info_msg("stopping clerk ~p~n", [self()]),
    [Parent, Log, Marks_raw, Timer] = get_values(
        [gtl_parent_clerk, log, marks, timer],
        S),
    timer:cancel(Timer),
    [Clerk, ProcU, ProcF, MemU, MemF] = get_values(
        [gtl_clerk, proc_used, proc_free, memory_used, memory_free], S),
    ProcTotal = ProcU + ProcF,
    MemoryTotal = MemU + MemF,
    _FM = free_memory(MemoryTotal),
    _FP = free_proc(ProcTotal),
    LastMsg = ?MSG(Clerk, now(), {gtl, handle_stop_clerk, Clerk}),
    NewLog = [ LastMsg | Log],

    case ?MODULE:is_process_alive(Parent) of
        true ->
            %error_logger:info_msg("~p: sending clerk's log to parent ~p~n", [self(), Parent]),
            gen_server:cast(Parent, {records, NewLog}),
            Marks = sets:to_list(Marks_raw),
            %error_logger:info_msg("~p: sending clerk's marks to parent ~p~n", [self(), Parent]),
            gen_server:cast(Parent, {marks, Marks});
        _ ->
            % Parent is dead or undefined
            case Parent of
                undefined -> nop;
                _ -> error_logger:warning_msg("~p: can't send marks and logs to parent (~p) as it's dead~n", [self(), Parent])
            end,
            flush_log(get_value(marked, S), repl_keys([{log, NewLog}], S))
    end,
    NS = repl_keys([
            {memory_free,0},
            {memory_used,0},
            {proc_free,0},
            {proc_used,0}
        ], S),
    {stop, normal, NS}.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

terminate(_Reason, S) ->
    [ProcU, ProcF, MemU, MemF] = get_values(
        [proc_used, proc_free, memory_used, memory_free], S),
    ProcTotal = ProcU + ProcF,
    MemoryTotal = MemU + MemF,
    free_proc(ProcTotal),
    free_memory(MemoryTotal),
    ok.

form_logname(Mark) when is_list(Mark) ->
    M1 = case lists:suffix(".log", Mark) of
        true -> Mark;
        false -> Mark ++ ".log"
    end,
    case M1 of
        "gtl." ++ _ -> M1;
        _ -> "gtl." ++ M1
    end.

flush_log(false, _S) -> ok;      % Do not flush
flush_log(true, S) ->
    [_ST, Log, _Clerk, Marks_raw] = get_values(
        [start_time, log, gtl_clerk, marks],
        S),
    Marks = sets:to_list(Marks_raw),

    LogNames = lists:map(fun form_logname/1, Marks),
    %error_logger:info_msg("flush_log: ~p~n", [LogNames]),
    gtl_saver:save(LogNames, ?VERSION, lists:reverse(Log)).
