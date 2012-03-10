-module(jobs_eqc_queue).

-include_lib("eqc/include/eqc.hrl").
-include("jobs.hrl").

-compile(export_all).

-record(model,
        { time = jobs_lib:timestamp(),
          st   = undefined }).

g_job() ->
    {make_ref(), make_ref()}.

g_scheduling_order() ->
    elements([fifo, lifo]).

g_options(jobs_queue) -> return([fifo]);
g_options(jobs_queue_list) -> return([lifo]).

g_queue_record() ->
    ?LET(N, nat(),
        #queue { max_time = N }).

g_start_time() ->
    ?LET({T, N}, {jobs_lib:timestamp(), nat()},
         T + N).

g_model_type() ->
    oneof([jobs_queue]).

g_model(Ty) ->
    ?SIZED(Size, g_model(Size, Ty)).

g_model(0, Ty) ->
    oneof([{call, ?MODULE, new, [Ty,
                                 g_options(Ty),
                                 g_queue_record(),
                                 g_start_time()]}]);
g_model(N, Ty) ->
    frequency([{1, g_model(0, Ty)},
               {N,
                  ?LET(M, g_model(max(0, N-2), Ty),
                       frequency(
                         [
                          {200, {call, ?MODULE, advance_time, [M, nat()]}},
                          {200, {call, ?MODULE, in, [Ty, g_job(), M]}},
                          {100, {call, ?MODULE, out, [Ty, nat(), M]}},
                          {1,   {call, ?MODULE, empty, [Ty, M]}}
                         ]))}
              ]).

new(Mod, Opts, Q, T) ->
    #model { st = Mod:new(Opts, Q),
             time = T}.

advance_time(#model { time = T} = M, N) ->
    M#model { time = T + N}.

in(Mod, Job, #model { time = T, st = Q} = M) ->
    M#model { st = Mod:in(T, Job, Q)}.

out(Mod, N, #model { st = Q} = M) ->
    NQ = element(2, Mod:out(N, Q)),
    M#model { st = NQ }.

empty(Mod, #model { st = Q} = M) ->
    M#model { st = Mod:empty(Q)}.

is_empty(M, #model { st = Q}) ->
    M:is_empty(Q).

peek(M, #model { st = Q}) ->
    M:peek(Q).

all(M, #model { st = Q}) ->
    M:all(Q).

info(M, I, #model { st = Q}) ->
    M:info(I, Q).

g_info() ->
    oneof([oldest_job, length, max_time]).

obs() ->
    ?LET(Ty, g_model_type(),
         begin
             M = g_model(Ty),
             oneof([{call, ?MODULE, all, [Ty, M]},
                    {call, ?MODULE, peek, [Ty, M]},
                    {call, ?MODULE, info, [Ty, g_info(), M]},
                    {call, ?MODULE, is_empty, [Ty, M]}])
         end).

model({call, ?MODULE, F, [W | Args]}) when W == jobs_queue;
                                           W == jobs_queue_list ->
    apply(?MODULE, F, model([jobs_queue_model | Args]));
model({call, ?MODULE, F, Args}) ->
    apply(?MODULE, F, model(Args));
model([H|T]) ->
    [model(H) | model(T)];
model(X) ->
    X.

prop_oldest_job_match() ->
    ?LET(Ty, g_model_type(),
         ?FORALL(M, g_model(Ty),
            begin
                R = eval(M),
                Repr = Ty:representation(R#model.st),
                OJ = proplists:get_value(oldest_job, Repr),
                Cts = proplists:get_value(contents, Repr),
                case OJ of
                    undefined ->
                        Cts == [];
                    V ->
                        lists:min([TS || {TS, _} <- Cts]) == V
                end
            end)).

prop_queue() ->
    ?LET(Ty, g_model_type(),
        ?FORALL(M, g_model(Ty),
            equals(
              catching(fun() ->
                               R = eval(M),
                               Ty:representation(R#model.st)
                       end, e),
              catching(fun () ->
                               R = model(M),
                               jobs_queue_model:representation(R#model.st)
                       end, q)))).

prop_observe() ->
    ?FORALL(Obs, obs(),
            equals(
              catching(fun() -> eval(Obs) end, e),
              catching(fun() -> model(Obs) end, m))).

catching(F, T) ->
        try F()
        catch C:E ->
                io:format("Exception: ~p:~p~n", [C, E]),
                T
        end.

