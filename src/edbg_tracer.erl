-module(edbg_tracer).

-export([file/0
         , file/1
         , tlist_to_file/2
         , fstart/0
         , fstart/1
         , fstart/2
         , fstop/0
         , lts/0
         , send/2
         , start_my_tracer/0
         , tlist/0
         , tmax/1
         , tquit/0
         , traw/1
         , tstart/0
         , tstart/1
         , tstart/2
         , tstart/3
         , tstop/0
        ]).

-import(edbg_file_tracer,
        [add_mf_f/1
         , dump_output_eager_f/0
         , dump_output_lazy_f/0
         , fname/2
         , get_config/0
         , log_file_f/1
         , max_msgs_f/1
         , memory_f/0
         , mname/2
         , monotonic_ts_f/0
         , new_mf/0
         , send_receive_f/0
         , set_config/2
         , start_trace/0
         , stop_trace/0
         , trace_spec_f/1
         , trace_time_f/1
        ]).

%% Internal export
-export([tloop/3,
         ploop/1,
         rloop/2
        ]).


-ifdef(USE_COLORS).
-define(info_msg(Fmt,Args), edbg_color_srv:info_msg(Fmt,Args)).
-define(info_msg(IoDevice, Fmt,Args), io:format(IoDevice, Fmt,Args)).
-define(att_msg(Fmt,Args), edbg_color_srv:att_msg(Fmt,Args)).
-define(warn_msg(Fmt,Args), edbg_color_srv:warn_msg(Fmt,Args)).
-define(err_msg(Fmt,Args), edbg_color_srv:err_msg(Fmt,Args)).
-define(cur_line_msg(Fmt,Args), edbg_color_srv:cur_line_msg(Fmt,Args)).
-define(c_hi(Str), edbg_color_srv:c_hi(Str)).
-define(c_warn(Str), edbg_color_srv:c_warn(Str)).
-define(c_err(Str), edbg_color_srv:c_err(Str)).
-define(help_hi(Str), edbg_color_srv:help_hi(Str)).
-define(edbg_color_srv_init(), edbg_color_srv:init()).
-else.
-define(info_msg(Fmt,Args), io:format(Fmt,Args)).
-define(info_msg(IoDevice, Fmt,Args), io:format(IoDevice, Fmt,Args)).
-define(att_msg(Fmt,Args), io:format(Fmt,Args)).
-define(warn_msg(Fmt,Args), io:format(Fmt,Args)).
-define(err_msg(Fmt,Args), io:format(Fmt,Args)).
-define(cur_line_msg(Fmt,Args), io:format(Fmt,Args)).
-define(c_hi(Str), Str).
-define(c_warn(Str), Str).
-define(c_err(Str), Str).
-define(help_hi(Str), Str).
-define(edbg_color_srv_init(), ok).
-endif.


-define(mytracer, mytracer).

-define(inside(At,Cur,Page), ((Cur >=At) andalso (Cur =< (At+Page)))).

-record(tlist, {
          level = maps:new(),  % Key=<pid> , Val=<level>
          at = 1,
          current = 1,
          page = 100000,
          send_receive = true, % do (not) show send/receive msgs
          memory = true        % do (not) show memory info
         }).


-record(t, {
          trace_max = 10000,
          tracer
         }).

start_my_tracer() ->
    case whereis(?mytracer) of
        Pid when is_pid(Pid) ->
            Pid;
        _ ->
            Pid = spawn(fun() -> tinit(#t{}) end),
            register(?mytracer, Pid),
            Pid
    end.

%% dbg:tracer(process,{fun(Trace,N) ->
%%                        io:format("TRACE (#~p): ~p~n",[N,Trace]),
%%                        N+1
%%                       end, 0}).
%%dbg:p(all,clear).
%%dbg:p(all,[c]).

%% @doc Enter trace list mode based on given trace file.
file() ->
    file("./edbg.trace_result").

file(Fname) ->
    catch stop_trace(),
    catch edbg_file_tracer:stop(),
    try file:read_file(Fname) of
        {ok, Tdata} ->
            %% We expect Tdata to be a list of trace tuples as
            %% a binary in the external term form.
            call(start_my_tracer(), {load_trace_data,
                                     binary_to_term(Tdata)}),
            tlist();
        Error ->
            Error
    catch
        _:Err ->
            {error, Err}
    end.

tlist_to_file(Fname, Out) ->
    catch stop_trace(),
    catch edbg_file_tracer:stop(),
    try file:read_file(Fname) of
        {ok, Tdata} ->
            %% We expect Tdata to be a list of trace tuples as
            %% a binary in the external term form.
            call(start_my_tracer(), {load_trace_data,
                                     binary_to_term(Tdata)}),
            tlist_to_file(Out);
        Error ->
            Error
    catch
        _:Err ->
            {error, Err}
    end.

%% @doc Start tracing to file.
fstart() ->
    edbg_file_tracer:start(),
    edbg_file_tracer:load_config(),
    start_trace().

fstart(ModFunList) ->
    fstart(ModFunList, []).

fstart(ModFunList, Options)
  when is_list(ModFunList) andalso
       is_list(Options) ->
    edbg_file_tracer:start(),
    MF  = new_mf(),
    MFs = lists:foldr(fun({Mname,Fname}, Acc) ->
                              [add_mf_f(fname(mname(MF, Mname), Fname))|Acc];
                         (Mname, Acc) when is_atom(Mname) ->
                              [add_mf_f(mname(MF, Mname))|Acc];
                         (X, Acc) ->
                              io:format("Ignoring ModFun: ~p~n",[X]),
                              Acc
                      end, [], ModFunList),

    Opts = lists:foldr(fun({log_file, Lname}, Acc) ->
                               [log_file_f(Lname)|Acc];
                          ({max_msgs, Max}, Acc) ->
                               [max_msgs_f(Max)|Acc];
                          ({trace_time, Time}, Acc) ->
                               [trace_time_f(Time)|Acc];
                          ({trace_spec, Spec}, Acc) ->
                               [trace_spec_f(Spec)|Acc];
                          (dump_output_lazy, Acc) ->
                               [dump_output_lazy_f()|Acc];
                          (dump_output_eager, Acc) ->
                               [dump_output_eager_f()|Acc];
                          (monotonic_ts, Acc) ->
                               [monotonic_ts_f()|Acc];
                          (send_receive, Acc) ->
                               [send_receive_f()|Acc];
                          (memory, Acc) ->
                               [memory_f()|Acc];
                          (X, Acc) ->
                               io:format("Ignoring Option: ~p~n",[X]),
                               Acc
                       end, [], Options),

    set_config(MFs++Opts, get_config()),
    start_trace().

fstop() ->
    edbg_file_tracer:stop_trace(),
    edbg_file_tracer:stop().


tstart() ->
    start_my_tracer().

tstart(Mod) when is_atom(Mod) ->
    tstart(Mod, []).

tstart(Mod, Mods) when is_atom(Mod) andalso is_list(Mods)  ->
    tstart(Mod, Mods, []).

tstart(Mod, Mods, Opts) when is_atom(Mod) andalso is_list(Mods)  ->
    trace_start({Mod, Mods, Opts}, Opts).

trace_start(FilterInput, Opts) ->
    call(start_my_tracer(), {start, FilterInput, Opts}).

call(MyTracer, Msg) ->
    MyTracer ! {self(), Msg},
    receive
        {MyTracer, Result} ->
            Result
    end.

lts() ->
    {ok,[X]} = file:consult("trace.edbg"),
    call(start_my_tracer(), X).


tlist() ->
    Self = self(),
    Prompt = spawn_link(fun() -> prompt(Self) end),
    print_help(),
    ?mytracer ! at,
    ploop(Prompt).

tlist_to_file(Out) ->
    %% Self = self(),
    %% Prompt = spawn_link(fun() -> prompt(Self) end),
    %% print_help(),
    ?mytracer ! {tlist_to_file, Out}.
    %% ploop(Prompt).

ploop(Prompt) ->
    receive
        {'EXIT', Prompt, _} ->
            true;

        quit ->
            true;

        _ ->
            ?MODULE:ploop(Prompt)
    end.


prompt(Pid) when is_pid(Pid) ->
    Prompt = "tlist> ",
    rloop(Pid, Prompt).

rloop(Pid, Prompt) ->
    case string:tokens(io:get_line(Prompt), "\n") of
        ["d"++_] -> ?mytracer ! down;
        ["u"++_] -> ?mytracer ! up;
        ["t"++_] -> ?mytracer ! top;
        ["b"++_] -> ?mytracer ! bottom;
        ["a"++X] -> at(?mytracer, X);
        ["f"++X] -> find(?mytracer, X);
        ["s"++X] -> show(?mytracer, X);
        ["r"++X] -> show_return(?mytracer, X);
        ["w"++X] -> show_raw(?mytracer, X);
        ["pr"++X]-> show_record(?mytracer, X);
        ["p"++X] -> set_page(?mytracer, X);
        ["h"++_] -> print_help();
        ["on"++X]-> on(?mytracer, X);
        ["off"++X]-> off(?mytracer, X);
        ["q"++_] -> Pid ! quit, exit(normal);

        _X ->
            ?info_msg("prompt got: ~p~n",[_X])
    end,
    ?MODULE:rloop(Pid, Prompt).

find(Pid, X) ->
    try
        Xstr = string:strip(X),
        case string:tokens(Xstr, ":") of
            [M,F] ->
                case string:tokens(F, " ") of
                    [F1] ->
                        Pid ! {find, {M,F1}};
                    [F1,An,Av] ->
                        Pid ! {find, {M,F1},{list_to_integer(An),Av}}
                end;
            [M|_] ->
                case string:chr(Xstr, $:) of
                    I when I > 0 ->
                        Pid ! {find, {M,""}};
                    _ ->
                        Pid ! {find_str, Xstr}
                end
        end
    catch
        _:_ -> false
    end.

on(Pid, X) ->
    case string:strip(X) of
        "send_receive" ->
            Pid ! {on, send_receive};
        "memory" ->
            Pid ! {on, memory};
        _ ->
            false
    end.

off(Pid, X) ->
    case string:strip(X) of
        "send_receive" ->
            Pid ! {off, send_receive};
        "memory" ->
            Pid ! {off, memory};
        _ ->
            false
    end.

show(Pid, X) ->
    parse_integers(Pid, X, show).

show_record(Pid, X) ->
    parse_integers(Pid, X, show_record).

set_page(Pid, X) ->
    parse_integers(Pid, X, set_page).

at(Pid, X) ->
    parse_integers(Pid, X, at).

show_return(Pid, X) ->
    parse_integers(Pid, X, show_return).

show_raw(Pid, X) ->
    parse_integers(Pid, X, show_raw).

parse_integers(Pid, X, Msg) ->
    try
        case string:tokens(string:strip(X), " ") of
            [] ->
                Pid ! Msg;
            [A] ->
                Pid ! {Msg, list_to_integer(A)};
            [A,B] ->
                Pid ! {Msg, list_to_integer(A), list_to_integer(B)}
        end
    catch
        _:_ -> false
    end.


print_help() ->
    S1 = " (h)elp (a)t [<N>] (d)own (u)p (t)op (b)ottom",
    S2 = " (s)how <N> [<ArgN>] (r)etval <N> ra(w) <N>",
    S3 = " (pr)etty print record <N> <ArgN>",
    S4 = " (f)ind <M>:<Fx> [<ArgN> <ArgVal>] | <RetVal>",
    S5 = " (on)/(off) send_receive | memory",
    S6 = " (p)agesize <N> (q)uit",
    S = io_lib:format("~n~s~n~s~n~s~n~s~n~s~n~s~n",[S1,S2,S3,S4,S5,S6]),
    ?info_msg(?help_hi(S), []).


tstop() -> ?mytracer ! stop.
traw(N) when is_integer(N)  -> ?mytracer ! {raw,N}.
tquit() -> ?mytracer ! quit.
tmax(N) when is_integer(N) -> ?mytracer ! {max,N}.

tinit(X) ->
    process_flag(trap_exit, true),
    ?MODULE:tloop(X, #tlist{}, []).


tloop(#t{trace_max = MaxTrace} = X, Tlist, Buf) ->
    receive

        %% FROM THE TRACE FILTER

        %% Trace everything until Max is reached.
        {trace, From, {N,_Trace} = Msg} when N =< MaxTrace ->
            reply(From, ok),
            ?MODULE:tloop(X, Tlist ,[Msg|Buf]);

        %% Max is reached; stop tracing!
        {trace, From , {N,_Trace} = _Msg} when N > MaxTrace ->
            reply(From, stop),
            dbg:stop_clear(),
            ?MODULE:tloop(X#t{tracer = undefined}, Tlist ,Buf);


        %% FROM EDBG

        {max, N} ->
            ?MODULE:tloop(X#t{trace_max = N}, Tlist ,Buf);

        {set_page, Page} ->
            ?MODULE:tloop(X, Tlist#tlist{page = Page} ,Buf);

        {show_raw, N} ->
            dbg:stop_clear(),
            case lists:keyfind(N, 1, Buf) of
                {_, Msg} ->
                    ?info_msg("~n~p~n", [Msg]);
                _ ->
                    ?err_msg("not found~n",[])
            end,
            ?MODULE:tloop(X, Tlist ,Buf);

        {show_return, N} ->
            dbg:stop_clear(),
            case get_return_value(N, lists:reverse(Buf)) of
                {ok, {M,F,Alen}, RetVal} ->
                    Sep = pad(35, $-),
                    ?info_msg("~nCall: ~p:~p/~p , return value:~n~s~n~p~n",
                             [M,F,Alen,Sep,RetVal]);
                not_found ->
                    ?info_msg("~nNo return value found!~n",[])
            end,
            ?MODULE:tloop(X, Tlist ,Buf);

        {show, N} ->
            dbg:stop_clear(),
            mlist(N, Buf),
            ?MODULE:tloop(X, Tlist ,Buf);

        {show, N, ArgN} ->
            dbg:stop_clear(),
            try
                case lists:keyfind(N, 1, Buf) of
                    {_,{trace, _Pid, call, MFA, _As}} ->
                        show_arg(ArgN, MFA);

                    {_,{trace_ts, _Pid, call, MFA, _TS, _As}} ->
                        show_arg(ArgN, MFA);

                    _ ->
                        ?err_msg("not found~n",[])
                end
            catch
                _:_ ->  ?err_msg("not found~n",[])
            end,
            ?MODULE:tloop(X, Tlist ,Buf);

        {show_record, N, ArgN} ->
            dbg:stop_clear(),
            try
                case lists:keyfind(N, 1, Buf) of
                    {_,{trace, _Pid, call, MFA, _As}} ->
                        show_rec(ArgN, MFA);

                    {_,{trace_ts, _Pid, call, MFA, _TS, _As}} ->
                        show_rec(ArgN, MFA);

                    _ ->
                        ?err_msg("not found~n",[])
                end
            catch
                _:_ ->
                    ?err_msg("not found~n",[])
            end,
            ?MODULE:tloop(X, Tlist ,Buf);

        %% Find a matching function call
        {find, {Mstr,Fstr}} ->
            NewTlist = case find_mf(Tlist#tlist.at, Buf, Mstr, Fstr) of
                           not_found ->
                               ?info_msg("not found~n",[]),
                               Tlist;
                           NewAt ->
                               list_trace(Tlist#tlist{at = NewAt}, Buf)
                       end,
            ?MODULE:tloop(X, NewTlist ,Buf);

        %% Find a matching function call where ArgN contains Value
        {find, {Mstr,Fstr},{An,Av}} ->
            NewTlist = case find_mf_av(Tlist#tlist.at,Buf,Mstr,Fstr,An,Av) of
                           not_found ->
                               ?info_msg("not found~n",[]),
                               Tlist;
                           NewAt ->
                               list_trace(Tlist#tlist{at = NewAt}, Buf)
                       end,
            ?MODULE:tloop(X, NewTlist ,Buf);

        %% Find a match among the return values
        {find_str, Str} ->
            NewTlist = case find_retval(Tlist#tlist.at, Buf, Str) of
                           not_found ->
                               ?info_msg("not found~n",[]),
                               Tlist;
                           NewAt ->
                               list_trace(Tlist#tlist{at = NewAt}, Buf)
                       end,
            ?MODULE:tloop(X, NewTlist ,Buf);

        top ->
            NewTlist = list_trace(Tlist#tlist{at = 1}, Buf),
            ?MODULE:tloop(X, NewTlist, Buf);

        bottom ->
            {N,_} = hd(Buf),
            NewTlist = list_trace(Tlist#tlist{at = N}, Buf),
            ?MODULE:tloop(X, NewTlist, Buf);

        {on, send_receive} ->
            ?info_msg("turning on display of send/receive messages~n",[]),
            ?MODULE:tloop(X, Tlist#tlist{send_receive = true}, Buf);

        {on, memory} ->
            ?info_msg("turning on display of memory usage~n",[]),
            ?MODULE:tloop(X, Tlist#tlist{memory = true}, Buf);

        {off, send_receive} ->
            ?info_msg("turning off display of send/receive messages~n",[]),
            ?MODULE:tloop(X, Tlist#tlist{send_receive = false}, Buf);

        {off, memory} ->
            ?info_msg("turning off display of memory usage~n",[]),
            ?MODULE:tloop(X, Tlist#tlist{memory = false}, Buf);

        at ->
            NewAt = erlang:max(0, Tlist#tlist.at - Tlist#tlist.page - 1),
            NewTlist = list_trace(Tlist#tlist{at = NewAt}, Buf),
            ?MODULE:tloop(X, NewTlist, Buf);
        {tlist_to_file, Out} ->
            {ok, IoDevice} = file:open(Out, [write]),
            NewTlist = list_trace(IoDevice, Tlist#tlist{at = 1}, Buf),
            ok = file:close(IoDevice),
            ?MODULE:tloop(X, NewTlist, Buf);
        {at, At} ->
            NewTlist = list_trace(Tlist#tlist{at = At}, Buf),
            ?MODULE:tloop(X, NewTlist, Buf);

        up ->
            NewAt = erlang:max(0, Tlist#tlist.at - (2*Tlist#tlist.page)),
            NewTlist = list_trace(Tlist#tlist{at = NewAt}, Buf),
            ?MODULE:tloop(X, NewTlist, Buf);

        down ->
            dbg:stop_clear(),
            NewTlist = list_trace(Tlist, Buf),
            ?MODULE:tloop(X, NewTlist, Buf);

        {raw, N} ->
            case lists:keyfind(N, 1, Buf) of
                {_,V} -> ?info_msg("~p~n",[V]);
                _     -> ?info_msg("nothing found!~n",[])
            end,
            ?MODULE:tloop(X, Tlist ,Buf);

        stop ->
            dbg:stop_clear(),
            ?MODULE:tloop(X#t{tracer = undefined}, Tlist ,Buf);

        quit ->
            dbg:stop_clear(),
            exit(quit);

        {From, {load_trace_data, TraceData}} ->
            From ! {self(), ok},
            ?MODULE:tloop(X, Tlist ,TraceData);

        {From, {start, Start, Opts}} ->
            TraceSetupMod = get_trace_setup_mod(Opts),
            TraceMax = get_trace_max(Opts),
            case TraceSetupMod:start_tracer(Start) of
                {ok, NewTracer} ->
                    From ! {self(), started},
                    save_start_trace({start, Start, Opts}),
                    ?MODULE:tloop(X#t{trace_max = TraceMax,
                                      tracer = NewTracer}, Tlist ,[]);
                {error, _} = Error ->
                    From ! {self(), Error},
                    ?MODULE:tloop(X, Tlist ,Buf)
            end;

        _X ->
            %%?info_msg("mytracer got: ~p~n",[_X]),
            ?MODULE:tloop(X, Tlist ,Buf)
    end.

show_arg(ArgN, {M,F,A}) ->
    Sep = pad(35, $-),
    ArgStr = "argument "++integer_to_list(ArgN)++":",
    ?info_msg("~nCall: ~p:~p/~p , ~s~n~s~n~p~n",
              [M,F,length(A),ArgStr,Sep,lists:nth(ArgN,A)]).

show_rec(ArgN, {M,F,A}) ->
    Sep = pad(35, $-),
    Fname = edbg:find_source(M),
    {ok, Defs} = pp_record:read(Fname),
    ArgStr = "argument "++integer_to_list(ArgN)++":",
    ?info_msg("~nCall: ~p:~p/~p , ~s~n~s~n~s~n",
              [M,F,length(A),ArgStr,Sep,
               pp_record:print(lists:nth(ArgN,A), Defs)]).


find_mf(At, Buf, Mstr, Fstr) ->
    Mod = list_to_atom(Mstr),
    %% First get the set of trace messages to investigate
    L = lists:takewhile(
          fun({N,_}) when N>=At -> true;
             (_)                -> false
          end, Buf),
    %% Discard non-matching calls
    R = lists:dropwhile(
          fun({_N,{trace,_Pid,call,{M,_,_}, _As}}) when M == Mod andalso
                                                        Fstr == "" ->
                  false;
             ({_N,{trace_ts,_Pid,call,{M,_,_},_TS, _As}}) when M == Mod andalso
                                                               Fstr == "" ->
                  false;
             ({_N,{trace,_Pid,call,{M,F,_}, _As}}) when M == Mod ->
                  not(lists:prefix(Fstr, atom_to_list(F)));
             ({_N,{trace_ts,_Pid,call,{M,F,_},_TS, _As}}) when M == Mod ->
                  not(lists:prefix(Fstr, atom_to_list(F)));
             (_) ->
                  true
          end, lists:reverse(L)),
    case R of
        [{N,_}|_] -> N;
        _         -> not_found
    end.

find_mf_av(At, Buf, Mstr, Fstr, An, Av) ->
    Mod = list_to_atom(Mstr),
    %% First get the set of trace messages to investigate
    L = lists:takewhile(
          fun({N,_}) when N>=At -> true;
             (_)                -> false
          end, Buf),
    %% Discard non-matching calls
    R = lists:dropwhile(
          fun({_N,{trace,_Pid,call,{M,F,A}, _As}}) when M == Mod andalso
                                                   length(A) >= An ->
                  do_find_mf_av(Fstr, An, Av, F, A);
             ({_N,{trace_ts,_Pid,call,{M,F,A},_TS, _As}}) when M == Mod andalso
                                                          length(A) >= An ->
                  do_find_mf_av(Fstr, An, Av, F, A);
             (_) ->
                  true
          end, lists:reverse(L)),
    case R of
        [{N,_}|_] -> N;
        _         -> not_found
    end.

do_find_mf_av(Fstr, An, Av, F, A) ->
    case lists:prefix(Fstr, atom_to_list(F)) of
        true ->
            ArgStr = lists:flatten(io_lib:format("~p",[lists:nth(An,A)])),
            try re:run(ArgStr,Av) of
                nomatch -> true;
                _       -> false
            catch
                _:_ -> true
            end;
        _ ->
            true
    end.

get_buf_at(At, Buf) ->
    lists:takewhile(
      fun({N,_}) when N>=At -> true;
         (_)                -> false
      end, Buf).

get_buf_before_at(At, Buf) ->
    lists:dropwhile(
      fun({N,_}) when N>=At -> true;
         (_)                -> false
      end, Buf).


find_retval(At, Buf, Str) ->
    %% First get the set of trace messages to investigate
    L = get_buf_at(At, Buf),
    %% Discard non-matching return values
    try
        lists:foldl(
          fun({N,{trace,_Pid,return_from, MFA, Value, _As}}=X,_Acc) ->
                  do_find_retval(N, Str, Value, X, MFA, Buf);
             ({N,{trace_ts,_Pid,return_from, MFA, Value, _TS, _As}}=X,_Acc) ->
                  do_find_retval(N, Str, Value, X, MFA, Buf);
             (X, Acc) ->
                  [X|Acc]
          end, [], lists:reverse(L)),
        not_found
    catch
        throw:{matching_call,{N,_}} -> N;
        _:_                         -> not_found
    end.

do_find_retval(At, Str, Value, X, MFA, Buf) ->
    L = get_buf_before_at(At, Buf),
    ValStr = lists:flatten(io_lib:format("~p",[Value])),
    try re:run(ValStr, Str) of
        nomatch -> [X|Buf];
        _       -> find_matching_call(MFA, L, 0)
    catch
        _:_ -> [X|Buf]
    end.

%% X = {Trace(_ts), Pid, CallOrReturnFrom, MFA, ...}
-define(m(X), element(1,element(4,X))).
-define(f(X), element(2,element(4,X))).
-define(a(X), element(3,element(4,X))).
-define(l(X), length(element(3,element(4,X)))).

%% Will throw exception at success; crash if nothing is found!
find_matching_call({M,F,A}, [{_N,Trace}=X|_], 0)
  when element(3, Trace) == call andalso
       ?m(Trace) == M andalso
       ?f(Trace) == F andalso
       ?l(Trace) == A ->
    throw({matching_call,X});
find_matching_call({M,F,A}=MFA, [{_N,Trace}|L], N)
  when element(3, Trace) == call andalso
       ?m(Trace) == M andalso
       ?f(Trace) == F andalso
       ?l(Trace) == A ->
    find_matching_call(MFA, L, N-1);
find_matching_call({M,F,A}=MFA, [{_N,Trace}|L], N)
  when element(3, Trace) == return_from andalso
       ?m(Trace) == M andalso
       ?f(Trace) == F andalso
       ?a(Trace) == A ->
    find_matching_call(MFA, L, N+1);
find_matching_call(MFA, [{_N,_Trace}|L], N) ->
    find_matching_call(MFA, L, N).


get_trace_setup_mod(Opts) ->
    get_opts(Opts, setup_mod, edbg_trace_filter).

get_trace_max(Opts) ->
    get_opts(Opts, trace_max, 10000).

get_opts(Opts, Key, Default) ->
    case lists:keyfind(Key, 1, Opts) of
        {Key, Mod} -> Mod;
        _          -> Default
    end.


save_start_trace(X) ->
    {ok,Fd} = file:open("trace.edbg",[write]),
    try
        io:format(Fd, "~p.~n", [X])
    after
        file:close(Fd)
    end.

field_size([{N,_}|_]) ->
    integer_to_list(length(integer_to_list(N)));
field_size(_) ->
    "1". % shouldn't happen...

list_trace(Tlist, Buf) ->
    list_trace(standard_io, Tlist, Buf).
list_trace(IoDevice, Tlist, Buf) ->
    maybe_put_first_timestamp(Buf),
    Fs = field_size(Buf),
    Zlist =
        lists:foldr(

          %% C A L L
          fun({N,{trace, Pid, call, {M,F,A}, As}},
              #tlist{level = LevelMap,
                     memory = MemoryP,
                     at = At,
                     page = Page} = Z)
                when ?inside(At,N,Page) ->
                  Level = maps:get(Pid, LevelMap, 0),
                  MPid = mpid(MemoryP, Pid, As),
                  ?info_msg(IoDevice, "~"++Fs++".s:~s ~s ~p:~p/~p~n",
                           [integer_to_list(N),pad(Level),MPid,M,F,length(A)]),
                  Z#tlist{level = maps:put(Pid, Level+1, LevelMap)};

             ({N,{trace_ts, Pid, call, {M,F,A}, TS, As}},
              #tlist{level = LevelMap,
                     memory = MemoryP,
                     at = At,
                     page = Page} = Z)
                when ?inside(At,N,Page) ->
                  Level = maps:get(Pid, LevelMap, 0),
                  MPid = mpid(MemoryP, Pid, As),
                  ?info_msg(IoDevice, "~"++Fs++".s:~s ~s ~p:~p/~p - ~p~n",
                           [integer_to_list(N),pad(Level),MPid,M,F,length(A),
                            xts(TS)]),
                  Z#tlist{level = maps:put(Pid, Level+1, LevelMap)};

             ({_N,{trace, Pid, call, {_M,_F,_A}, _As}},
              #tlist{level = LevelMap} = Z) ->
                  Level = maps:get(Pid, LevelMap, 0),
                  Z#tlist{level = maps:put(Pid, Level+1, LevelMap)};

             ({_N,{trace_ts, Pid, call, {_M,_F,_A}, _TS, _As}},
              #tlist{level = LevelMap} = Z) ->
                  Level = maps:get(Pid, LevelMap, 0),
                  Z#tlist{level = maps:put(Pid, Level+1, LevelMap)};

             %% R E T U R N _ F R O M
             ({_N,{trace, Pid, return_from, _MFA, _Value, _As}},
              #tlist{level = LevelMap} = Z) ->
                  Level = maps:get(Pid, LevelMap, 0),
                  Z#tlist{level = maps:put(Pid,erlang:max(Level-1,0),LevelMap)};

             ({_N,{trace_ts, Pid, return_from, _MFA, _Value, _TS, _As}},
              #tlist{level = LevelMap} = Z) ->
                  Level = maps:get(Pid, LevelMap, 0),
                  Z#tlist{level = maps:put(Pid,erlang:max(Level-1,0),LevelMap)};

             %% S E N D
             ({N,{trace, FromPid, send, Msg, ToPid, _As}},
              #tlist{send_receive = true,
                     level = LevelMap,
                     at = At,
                     page = Page} = Z)
                when ?inside(At,N,Page) ->
                  Level = maps:get(FromPid, LevelMap, 0),
                  ?info_msg(IoDevice, "~"++Fs++".s:~s >>> Send(~p) -> To(~p)  ~s~n",
                            [integer_to_list(N),pad(Level),
                             FromPid,ToPid,truncate(Msg)]),
                  Z;
             ({_N,{trace, _FromPid, send, _Msg, _ToPid, _As}}, Z) ->
                  Z;

             %% R E C E I V E
             ({N,{trace, ToPid, 'receive', Msg, _As}},
              #tlist{send_receive = true,
                     level = LevelMap,
                     at = At,
                     page = Page} = Z)
                when ?inside(At,N,Page) ->
                  Level = maps:get(ToPid, LevelMap, 0),
                  ?info_msg(IoDevice, "~"++Fs++".s:~s <<< Receive(~p)  ~s~n",
                            [integer_to_list(N),pad(Level),
                             ToPid,truncate(Msg)]),
                  Z;
             ({_N,{trace, _ToPid, 'receive', _Msg, _As}}, Z) ->
                  Z

          end, Tlist#tlist{level = maps:new()}, Buf),

    NewAt = Tlist#tlist.at + Tlist#tlist.page + 1,
    Zlist#tlist{at = NewAt}.

mpid(true = _MemoryP, Pid, As) ->
    case lists:keyfind(memory, 1, As) of
        {_, Mem} when is_integer(Mem) ->
            pid_to_list(Pid)++"("++integer_to_list(Mem)++")";
        _ ->
            pid_to_list(Pid)
    end;
mpid(_MemoryP , Pid, _As) ->
    pid_to_list(Pid).


truncate(Term) ->
    truncate(Term, 20).

truncate(Term, Length) ->
    string:slice(io_lib:format("~p",[Term]), 0, Length)++"...".

%% Elapsed monotonic time since first trace message
xts(TS) ->
    case get(first_monotonic_timestamp) of
        undefined ->
            0;
        XTS ->
            TS - XTS
    end.

maybe_put_first_timestamp(Buf) ->
    case get(first_monotonic_timestamp) of
        undefined ->
            case Buf of
                [{_N,{trace_ts, _Pid, call, _MFA, _TS, _As}}|_] ->
                    put(first_monotonic_timestamp,
                        get_first_monotonic_timestamp(Buf));
                [{_N,{trace_ts, _Pid, return_from, _MFA, _Value, _TS,_As}}|_] ->
                    put(first_monotonic_timestamp,
                        get_first_monotonic_timestamp(Buf));
                _ ->
                    undefined
            end;
        TS ->
            TS
    end.

get_first_monotonic_timestamp(Buf) ->
    case lists:reverse(Buf) of
        [{_N,{trace_ts, _Pid, call, _MFA, TS, _As}}|_] ->
            TS;
        [{_N,{trace_ts, _Pid, return_from, _MFA, _Value, TS, _As}}|_] ->
            TS
    end.


get_return_value(N, [{I,_}|T]) when I < N ->
    get_return_value(N, T);
get_return_value(N, [{N,{trace, _Pid, call, {M,F,A}, _As}}|T]) ->
    find_return_value({M,F,length(A)}, T);
get_return_value(N, [{N,{trace_ts, _Pid, call, {M,F,A}, _TS, _As}}|T]) ->
    find_return_value({M,F,length(A)}, T);
get_return_value(N, [{I,_}|_]) when I > N ->
    not_found;
get_return_value(_, []) ->
    not_found.

find_return_value(MFA, T) ->
    find_return_value(MFA, T, 0).

find_return_value(MFA,[{_,{trace,_Pid,return_from,MFA,Val,_As}}|_],0 = _Depth)->
    {ok, MFA, Val};
find_return_value(MFA, [{_,{trace_ts,_Pid,return_from,MFA,Val,_TS,_As}}|_],
                  0 = _Depth) ->
    {ok, MFA, Val};
find_return_value(MFA, [{_,{trace,_Pid,return_from,MFA,_,_As}}|T], Depth)
  when Depth > 0 ->
    find_return_value(MFA, T, Depth-1);
find_return_value(MFA, [{_,{trace_ts,_Pid,return_from,MFA,_,_TS,_As}}|T], Depth)
  when Depth > 0 ->
    find_return_value(MFA, T, Depth-1);
find_return_value(MFA, [{_,{trace, _Pid, call, MFA,_As}}|T], Depth) ->
    find_return_value(MFA, T, Depth+1);
find_return_value(MFA, [_|T], Depth) ->
    find_return_value(MFA, T, Depth);
find_return_value(_MFA, [], _Depth) ->
    not_found.


mlist(N, Buf) ->
    try
        case lists:keyfind(N, 1, Buf) of
            {_,{trace, _Pid, call, MFA, _As}} ->
                do_mlist(MFA);

            {_,{trace_ts, _Pid, call, MFA, _TS, _As}} ->
                do_mlist(MFA);

            {_,{trace, SendPid, send, Msg, ToPid, _As}} ->
                show_send_msg(SendPid, ToPid, Msg);

            {_,{trace, RecvPid, 'receive', Msg, _As}} ->
                show_recv_msg(RecvPid, Msg);

            _ ->
                ?info_msg("not found~n",[])
        end
    catch
        _:Err ->
            ?info_msg(?c_err("CRASH: ~p") ++ " ~p~n",
                     [Err,erlang:get_stacktrace()])
    end.

show_send_msg(SendPid, ToPid, Msg) ->
    ?info_msg("~nMessage sent by: ~p  to: ~p~n~p~n",
                      [SendPid,ToPid,Msg]).

show_recv_msg(RecvPid, Msg) ->
    ?info_msg("~nMessage received by: ~p~n~p~n",
                      [RecvPid,Msg]).


do_mlist({M,F,A}) ->
    Fname = edbg:find_source(M),
    {ok, SrcBin, Fname} = erl_prim_loader:get_file(Fname),
    LF = atom_to_list(F),
    Src = binary_to_list(SrcBin),
    %% '.*?' ::= ungreedy match!
    RegExp = "\\n"++LF++"\\(.*?->",
    %% 'dotall' ::= allow multiline function headers
    case re:run(Src, RegExp, [global,dotall,report_errors]) of
        {match, MatchList} ->
            {FmtStr, Args} = mk_print_match(SrcBin, MatchList),
            Sep = pad(35, $-),
            ?info_msg("~nCall: ~p:~p/~p~n~s~n"++FmtStr++"~n~s~n",
                      [M,F,length(A),Sep|Args]++[Sep]);
        Else ->
            ?info_msg("nomatch: ~p~n",[Else])
    end.


mk_print_match(SrcBin, MatchList) ->
    F = fun([{Start,Length}], {FmtStrAcc, ArgsAcc}) ->
                <<_:Start/binary,Match:Length/binary,_/binary>> = SrcBin,
                Str = binary_to_list(Match),
                {"~s~n"++FmtStrAcc, [Str|ArgsAcc]}
        end,
    lists:foldr(F, {"",[]}, MatchList).



pad(0) -> [];
pad(N) ->
    pad(N, $\s).

pad(N,C) ->
    lists:duplicate(N,C).

send(Pid, Msg) ->
    Pid ! {trace, self(), Msg},
    receive
        {Pid, ok}   -> ok;
        {Pid, stop} -> exit(stop)
    end.

reply(Pid, Msg) ->
    Pid ! {self(), Msg}.
