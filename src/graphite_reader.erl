%%%-------------------------------------------------------------------
%% @doc argos graphite reader
%% This module is used to access the graphite-web API to collect
%% information and return it in and erlang friendly format.
%% @author mikeyhc <mikeyhc@atmosia.net>
%% @since 0.1.0
%% @version 0.1.0
%% @private
%% @end
%%%-------------------------------------------------------------------
-module(graphite_reader).

-behaviour(gen_server).

%% Public API
-export([start_link/1, request/2, request/3]).

%% gen_server callbacks
-export([init/1, terminate/2, code_change/3]).
-export([handle_call/3, handle_cast/2, handle_info/2]).

%% types
-export_type([request_option/0, request_options/0, reply/0, request_id/0]).

%%====================================================================
%% Types and Records
%%====================================================================

%% records and types
-record(state, {hostname    :: string(),
                pending=[]  :: [pending_request()]
               }).

-type pending_request() :: {pid(), uid(), httpc:request_id()}.
-type uid() :: [hex()].
-type request_option() :: {from, string()}
                        | {until, string()}
                        | {reply_to, pid()}.
-type request_options() :: [request_option()].
-type reply() :: ok.
-type request_id() :: string().

-type hex() :: 48..57 | 97..102.

-type httpc_body() :: string() | binary().
-type httpc_response() :: {httpc:status_line(), httpc:headers(), httpc_body()}
                        | {httpc:status_code(), httpc:body()}.

%%====================================================================
%% API
%%====================================================================

%% @doc Creates a <code>graphite_reader</code> as part of a supervision
%% tree. This function is to be called, directly or indirectly, by the
%% supervisor as it ensures that the <code>graphite_reader</code>
%% is linked to the calling process.
%% @since 0.1.0
%% @end
-spec start_link(string()) -> {ok, pid()} | ignore
                              | {error, {already_started, pid()} | term()}.
start_link(Hostname) -> gen_server:start_link(?MODULE, [Hostname], []).


%% @doc Launch a request with the <code>graphite_reader</code> specified
%% by the given <b>Pid</b>. Will attempt to fetch information about the
%% given <b>Target</b> filtering by <b>Options</b>.
%% @throws {no_such_process, pid()}
%% @since 0.1.0
%% @end
-spec request(pid(), string()) -> uid().
request(Pid, Target) -> request(Pid, Target, []).

-spec request(pid(), string(), request_options()) -> uid().
request(Pid, Target, Options) ->
    Reply = case proplists:lookup(reply_to, Options) of
                {reply_to, P} -> P;
                none          -> self()
            end,
    Filter = fun({reply_to, _}) -> false;
                (_)             -> true
             end,
    case process_info(Pid) of
        undefined -> throw({no_such_process, Pid});
        _         ->
            Uid = uid(),
            gen_server:cast(Pid, {request, Reply, Uid, Target,
                                  lists:filter(Filter, Options)}),
            Uid
    end.

%%====================================================================
%% gen_server Callbacks
%%====================================================================

%% @hidden
init([Hostname]) -> {ok, #state{hostname=Hostname}}.

%% @hidden
terminate(_Reason, #state{pending=Pending}) ->
    F = fun({Pid, _Rid, Uid}) -> send_error(Pid, Uid, listener_terminate) end,
    lists:foreach(F, Pending).

%% @hidden
code_change(_OldVsn, State, _Extras) -> {ok, State}.

%% @hidden
handle_call(_Message, _From, State) -> {noreply, State}.

%% @hidden
handle_cast({request, Callee, Uid, Target, Options}, S) ->
    URL = build_url(S#state.hostname, Target, Options),
    P = [create_request(Callee, Uid, URL)|S#state.pending],
    {noreply, S#state{pending=P}}.


%% @hidden
handle_info({http, {ID, Reply}}, State) ->
    NS = case find_pending(ID, State#state.pending) of
             not_found ->
                 lager:warning("httpc reply ~p had no caller", [ID]),
                 State;
             {Found, Rest} ->
                 handle_response(Found, Reply),
                 State#state{pending=Rest}
         end,
    {noreply, NS}.

%%====================================================================
%% Internal Functions
%%====================================================================

%% @doc check a response is valid, parse it and send it back to the
%% requesting process
%% @todo handle the status code prior to the content type
%% @private
%% @end
-spec handle_response(pending_request(), httpc_response()) -> any().
handle_response({Pid, Uid, _}, {Status, Body}) ->
    process_response(Pid, Uid, Status, Body);
handle_response({Pid, Uid, _}, {{_Version, Code, _Reason}, Headers, Body}) ->
    Process = fun() -> process_response(Pid, Uid, Code, Body) end,
    case proplists:get_value(Headers, "content-type") of
        undefined   -> Process();
        ContentType ->
            if ContentType =:= "application/json" -> Process();
               true                               ->
                   send_error(Pid, Uid, invalid_content_type)
            end
    end.

%% @doc find a pending request by ID in a list of pending requests
%% @private
%% @end
-spec find_pending(httpc:request_id(), [pending_request()]) ->
    {pending_request(), [pending_request()]} | not_found.
find_pending(ID, Pending) -> find_pending(ID, Pending, []).

%% @hidden
-spec find_pending(httpc:request_id(), [pending_request()],
                   [pending_request()]) ->
    {pending_request(), [pending_request()]} | not_found.
find_pending(_Id, [], _Acc) -> not_found;
find_pending(ID, [R = {_, _, ID}|Rest], Acc) -> {R, drain(Acc, Rest)};
find_pending(ID, [H|T], Acc) -> find_pending(ID, T, [H|Acc]).

%% @doc creates a hash used to identify a request
%% @private
%% @end
-spec uid() -> uid().
uid() ->
    to_hex(crypto:hash(sha256, io_lib:format("~p", [os:timestamp()]))).

%% @doc convert a binary to a hex string
%% @private
%% @end
-spec to_hex(binary()) -> [hex()].
to_hex(Bin) -> to_hex(Bin, []).

%% @doc collect the host, target and parameters into a single string
%% @private
%% @end
-spec build_url(string(), string(), request_options()) -> string().
build_url(Host, Target, Options) ->
    Head = io_lib:format("~s/render?format=json&target=~s", [Host, Target]),
    lists:flatten(Head ++ lists:map(fun build_qs/1, Options)).

%% @doc starts a request with the <b>graphite_reader</b> registered host
%% and returns a pending request, which can later be matched to an
%% http message and then forwarded to the requesting pid
%% @private
%% @end
-spec create_request(pid(), uid(), string()) -> pending_request().
create_request(Callee, Uid, URL) ->
    Opts = [{sync, false}],
    {ok, RequestID} = httpc:request(get, {URL, []}, [], Opts),
    {Callee, Uid, RequestID}.

%%====================================================================
%% Helper Functions
%%====================================================================

%% flatten the default jiffy form for graphite replies
%% @hidden
-spec flatten({[any()]}) -> [any()].
flatten({L}) -> L.

%% @hidden
-spec process_response(pid(), uid(), integer(), httpc_body()) -> any().
process_response(Pid, Uid, Code, Body) when Code < 200 orelse Code > 299 ->
    lager:warning("graphite-web error<~w>: ~s", [Code, Body]),
    send_error(Pid, Uid, server_error);
process_response(Pid, Uid, _Code, Body) ->
    try
        send_success(Pid, Uid, lists:map(fun flatten/1, jiffy:decode(Body)))
    catch
        {error, {_, invalid_json}} -> send_error(Pid, Uid, invalid_json)
    end.

%% @hidden
-spec send_error(pid(), uid(), any()) -> any().
send_error(Pid, Uid, Error) -> Pid ! {graphite, {error, Uid, Error}}.

%% @hidden
-spec send_success(pid(), uid(), any()) -> any().
send_success(Pid, Uid, Msg) -> Pid ! {graphite, {ok, Uid, Msg}}.

%% @hidden
-spec to_hex(binary(), string()) -> string().
to_hex(<<>>, Acc) -> lists:reverse(Acc);
to_hex(<<A:4, B:4, C/binary>>, Acc) ->
    to_hex(C, [hex_char(B), hex_char(A)|Acc]).

%% @hidden
-spec hex_char(0..15) -> hex().
hex_char(C) when C < 10 -> C + $0;
hex_char(C) -> C - 10 + $a.

%% @hidden
-spec build_qs(request_option()) -> iolist().
build_qs({from, Time})-> io_lib:format("&from=~s", [Time]);
build_qs({until, Time}) -> io_lib:format("&target=~s", [Time]).

%% @doc prepends the first list to <b>Target</b> without preserving order
%% @private
%% @end
-spec drain(list(), list()) -> list().
drain([], Target) -> Target;
drain([H|T], Target) -> drain(T, [H|Target]).
