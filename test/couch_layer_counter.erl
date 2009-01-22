-module(couch_layer_counter).

-export([run/0, run/3]).


-define(WORKER_COUNT, 30).

run() ->
    run(counter, "localhost", 5984).

run(Db, Host, Port) ->
    couch_layer:create_database(Db, Host, Port),

    %% Initialize counter
    {atomic, 0} =
	couch_layer:transaction(
	  fun() ->
		  set_counter_t(Db, 0),
		  0
	  end),

    %% Count in parallel
    I = self(),
    Workers = lists:map(fun(_) ->
				spawn_link(fun() ->
						   counter(Db),
						   I ! {worker_done, self()}
					   end)
			end, lists:seq(1, ?WORKER_COUNT)),
    ok = wait_for_workers(Workers),
    
    %% Check for value
    {atomic, ?WORKER_COUNT} =
	couch_layer:transaction(
	  fun() ->
		  get_counter_t(Db)
	  end).
		      

wait_for_workers([]) ->
    ok;

wait_for_workers(Workers) ->
    receive
	{worker_done, Pid} ->
	    case lists:delete(Pid, Workers) of
		Workers ->
		    exit({done_from_unknown_worker, Pid});
		NewWorkers ->
		    wait_for_workers(NewWorkers)
	    end
    end.


%% Counter worker

counter(Db) ->
    {atomic, ok} =
	couch_layer:transaction(
	  fun() ->
		  Counter = get_counter_t(Db),
		  set_counter_t(Db, Counter + 1),
		  ok
	  end).


%% In-transaction getter

get_counter_t(Db) ->
    case couch_layer:read(Db, counter) of
	{struct, []} -> 0;
	{struct, Doc} ->
	    {value, {<<"value">>, Counter}} =
		lists:keysearch(<<"value">>, 1, Doc),
	    Counter
    end.

%% In-transaction setter

set_counter_t(Db, Counter) ->
    couch_layer:write(Db, counter, {struct, [{<<"value">>, Counter}]}).
