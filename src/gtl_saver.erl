%%% vim: set ts=4 sts=4 sw=4 expandtab:
-module(gtl_saver).
-behavior(gen_server).
-export([
    save/1,
    start_link/0,

    % gen server callbacks
    code_change/3,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    init/1,
    terminate/2
]).

-define(PATH,"").

start_link() ->
    %case application:get_env(gtl, gtl_node) of
    %    Node when Node /= undefined andalso Node /= node() -> nop;
    %    _ ->
    gen_server:start_link({global, ?MODULE}, ?MODULE, [] , []).

init([]) ->
    {ok, undefined}.

save(Log) -> gen_server:cast({global, ?MODULE}, {save, Log}).

handle_cast({save, {LogNames, Version, Logs}}, State) ->
    %TODO: check the message queue size and possibly skip some messages
    Header = "gtl version=" ++ Version,
    lists:map(
        fun(LogName) -> 
                log_it(?PATH ++ LogName, Header, Logs) 
        end, LogNames),
    {noreply, State}.

log_it(LogName, Header, Logs) ->
    case file:open(LogName, [append]) of
        {ok, IoDevice} ->
            error_logger:info_msg("save log to ~p dir:~p~n", [LogName, element(2,file:get_cwd())]),
            io:format(IoDevice, "[~s; ~14.3f] " ++ Header ++ "~n[~n",
                [lists:flatten(gtl_util:time_to_string(erlang:universaltime(), "GMT")), float(gtl_util:now2micro(now()) / 1000000)]),
            print_logs(IoDevice, Logs),
            io:format(IoDevice, "]~n~n", []),
            file:close(IoDevice);
        {error, Reason} ->
            error_logger:error_msg("~p: can't open ~p: ~p", [?MODULE, LogName, Reason])
    end.

print_logs(_, []) -> nop;
print_logs(IoDevice, [L | Rest]) ->
    MaybeComma = case Rest of
        [] -> "";
        _ -> ","
    end,
    io:format(IoDevice, " ~200p" ++ MaybeComma ++ "~n", [binary_to_term(L)]),
    print_logs(IoDevice, Rest).

code_change(_OldVsn, State, _Extra) -> {ok, State}.
terminate(_Reason, _State) -> ok.
handle_call(_Request, _From, State) -> {reply, ok, State}.
handle_info(_Request, State) -> {noreply, State}.
