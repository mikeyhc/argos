%%%-------------------------------------------------------------------
%% @doc argos timed callbacks
%% This module accepts callbacks and checks approx every minute to see
%% if the callback should be run
%% @author mikeyhc <mikeyhc@atmosia.net>
%% @since 0.1.0
%% @version 0.1.0
%% @private
%% @end
%%%-------------------------------------------------------------------
-module(timed).

-behaviour(gen_server).

%% Public API
-export([start_link/0, add_callback/3, add_callback/4]).

%% gen_server callbacks
-export([init/1, terminate/2, code_change/3]).
-export([handle_call/3, handle_cast/2, handle_info/2]).

%%====================================================================
%% Types and Records
%%====================================================================

%% records and types
-type callback_fn() :: fun(() -> any).

-record(callback, {timeout   :: pos_integer(),
                   current   :: pos_integer(),
                   exclusion :: {{pos_integer(), pos_integer()},
                                 {pos_integer(), pos_integer()}
                                } | none,
                   function  :: callback_fn()
                  }).
-type callback() :: #callback{}.

-type exclusion() :: {{pos_integer(), pos_integer()},
                      {pos_integer(), pos_integer()}}.

-record(state, {callbacks :: [callback()]}).

%%====================================================================
%% API
%%====================================================================

%% @doc Creates a <code>timed</code> as part of a supervision tree.
%% This function is to be called, directly or indirectly, by the
%% supervisor as it ensures that the <code>timed</code> is linked
%% to the calling process.
%% @since 0.1.0
%% @end
-spec start_link() -> {ok, pid()} | ignore
                      | {error, {already_started, pid()} | term()}.
start_link() -> gen_server:start_link(?MODULE, [], []).

%% @doc Adds a callback function which runs every <b>Timeout</b>
%% with optional exclusion period <b>Exclusion</b> to process
%% <b>Pid</b>.
%% @since 0.1.0
%% @end
-spec add_callback(pid(), pos_integer(), callback_fn()) -> ok.
add_callback(Pid, Timeout, Fn) -> add_callback(Pid, Timeout, Fn, none).

-spec add_callback(pid(), pos_integer(), callback_fn(), exclusion()) -> ok.
add_callback(Pid, Timeout, Callback, Exclusion) ->
    CB = #callback{timeout=Timeout, current=Timeout,
                   exclusion=Exclusion, function=Callback},
    gen_server:call(Pid, {add, CB}).

%%====================================================================
%% gen_server Callbacks
%%====================================================================

%% @hidden
init([]) ->
    {ok, #state{callbacks=[]}, calculate_timeout()}.

%% @hidden
terminate(_Reason, _State) -> ok.

%% @hidden
code_change(_OldVsn, State, _Extras) -> {ok, State}.

%% @hidden
handle_call({add, CB}, _From, State) ->
    NewState = State#state{callbacks=[CB|State#state.callbacks]},
    {noreply, NewState, calculate_timeout()}.

%% @hidden
handle_cast(_Message, State) ->
    {noreply, State, calculate_timeout()}.

%% @hidden
handle_info(timeout, State) ->
    lager:info("ticking callbacks"),
    NewState = update_and_run(State),
    lager:info("callback run complete"),
    {noreply, NewState, calculate_timeout()}.


%%====================================================================
%% Internal Functions
%%====================================================================

%% @doc updates the given state object by running each of the callback
%% objects (provide they have reached their timeout and are not in an
%% exclusionary period)
%% @private
%% @end
update_and_run(S=#state{callbacks=Callbacks}) ->
    Updated = lists:map(fun process_callback/1, Callbacks),
    S#state{callbacks=Updated}.

%% @doc If we are not in an exclusion period then run the given
%% function <b>Fn</b> with argument <b>C</b>.
%% @private
%% @end
within_exclusion(none,                 Fn, C) -> Fn(C);
within_exclusion({{SH, SM}, {EH, EM}}, Fn, C) ->
    {_Date, {H, M, _S}} = erlang:localtime(),
    case within_hours(SH, SM, EH, EM, H, M) of
        true  -> Fn(C);
        false -> C
    end.

%% @doc Decreases the callback by a minute, if it hits 0 then
%% it runs the callback function
%% @TODO run the callback async and kill it if it runs longer
%% than a minute
%% @private
%% @end
callback_tick(C=#callback{timeout=TO, current=C, function=Fn}) ->
    case C- 1 of
        0  ->
            Fn(),
            C#callback{current=TO};
        CT -> C#callback{current=CT}
    end.

%%====================================================================
%% Helper Functions
%%====================================================================

%% @hidden
process_callback(C=#callback{exclusion=E}) ->
    within_exclusion(E, fun callback_tick/1, C).

%% Checks if the time falls outside start and end hours
%% @hidden
within_hours(SH, SM, EH, EM, H, M) ->
    if H =:= SH              -> M < SM;
       H =:= EH              -> M > EM;
       H > SH andalso H < EH -> false;
       true                  -> true
    end.

%% Returns the amount of seconds to the next minute
%% @hidden
calculate_timeout() ->
    {_Date, {_Hour, _Min, Sec}} = erlang:localtime(),
    Sec * 1000.
