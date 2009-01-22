%% Copyright (c) 2009 Stephan Maka <stephan@spaceboyz.net>
%% 
%% Permission is hereby granted, free of charge, to any person
%% obtaining a copy of this software and associated documentation
%% files (the "Software"), to deal in the Software without
%% restriction, including without limitation the rights to use,
%% copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the
%% Software is furnished to do so, subject to the following
%% conditions:
%% 
%% The above copyright notice and this permission notice shall be
%% included in all copies or substantial portions of the Software.
%% 
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
%% EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
%% OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
%% NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
%% HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
%% WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
%% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
%% OTHER DEALINGS IN THE SOFTWARE.
%% 
%% 
%% @author Stephan Maka <stephan@spaceboyz.net>
%% @copyright 2009 Stephan Maka
%% @version 0.2.2
%% @doc A transactional layer for CouchDB
%% 
%% Updates at http://github.com/astro/erlang_couchdb/
-module(couch_layer).

%% API
-export([create_database/3, transaction/1, read/2, write/2, write/3, delete/2]).

-record(couchdb_database, {name,
			   server,
			   port}).

-define(MAX_TRANSACTION_RESTARTS, 100).
-define(DOC(Db, Id), {couch_layer_transaction_document, Db, Id}).
-record(doc, {id,
	      rev = unknown,
	      must_write = false,
	      delete = false,
	      content = {struct, []}}).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: 
%% Description:
%%--------------------------------------------------------------------

create_database(Name, Server, Port) ->
    mnesia:create_table(couchdb_database,
			[{attributes, record_info(fields, couchdb_database)}]),
    erlang_couchdb:create_database({Server, Port}, atom_to_list(Name)),
    {atomic, ok} =
	mnesia:transaction(
	  fun() ->
		  mnesia:write(#couchdb_database{name = Name,
						 server = Server,
						 port = Port})
	  end).

transaction(Fun) ->
    transaction(Fun, 1).

transaction(_, Try) when Try > ?MAX_TRANSACTION_RESTARTS ->
    exit(transaction_restarts_exceeded);

transaction(Fun, Try) ->
    case catch run_transaction(Fun) of
	{transaction_aborted, Reason} ->
	    error_logger:info_msg("Transaction try ~p restarting, reason: ~p~n",
				  [Try, Reason]),
	    cleanup_transaction(),
	    transaction(Fun, Try + 1);
	{'EXIT', Reason} ->
	    cleanup_transaction(),
	    {aborted, Reason};
	Result ->
	    cleanup_transaction(),
	    Result
    end.

read(Db, Id) ->
    [#couchdb_database{server = Server,
		       port = Port}] = mnesia:dirty_read(couchdb_database, Db),
    case get(?DOC(Db, Id)) of
	undefined ->
	    {json, Content} =
		erlang_couchdb:retrieve_document({Server, Port},
						 atom_to_list(Db),
						 Id),
	    Rev = content_rev(Content),
	    put(?DOC(Db, Id), #doc{id = Id,
				   rev = Rev,
				   content = Content}),
	    Content;
	#doc{rev = unknown} = Document ->
	    {json, Content} =
		erlang_couchdb:retrieve_document({Server, Port},
						 atom_to_list(Db),
						 Id),
	    Rev = content_rev(Content),
	    put(?DOC(Db, Id), Document#doc{rev = Rev}),
	    Content;
	#doc{content = Content} ->
	    Content
    end.

write(Db, Content) ->
    {id, Id} = content_id(Content),
    write(Db, Id, Content).

write(Db, Id, Content) ->
    case get(?DOC(Db, Id)) of
	undefined ->
	    put(?DOC(Db, Id), #doc{id = Id,
				   must_write = true,
				   content = Content});
	#doc{} = Doc ->
	    put(?DOC(Db, Id), Doc#doc{must_write = true,
				      content = Content})
    end,
    put(couch_layer_transaction_write, true).

delete(Db, Id) ->
    case get(?DOC(Db, Id)) of
	undefined ->
	    put(?DOC(Db, Id), #doc{id = Id,
				   must_write = true,
				   delete = true});
	#doc{} = Doc ->
	    put(?DOC(Db, Id), Doc#doc{must_write = true,
				      delete = true})
    end,
    put(couch_layer_transaction_write, true).


%%====================================================================
%% Internal functions
%%====================================================================

run_transaction(Fun) ->
    put(couch_layer_transaction_write, false),

    FunResult = Fun(),

    case get(couch_layer_transaction_write) of
	false ->
	    ok;
	true ->
	    %% Fetch unknown revisions
	    lists:foreach(
	      fun({?DOC(Db, Id), #doc{rev = unknown}}) ->
		      read(Db, Id);
		 (_) -> ignore
	      end, get()),
	    
	    %% Group documents by database
	    DbDocuments =
		lists:foldl(
		  fun({?DOC(Db, _Id), Document}, DbDocuments) ->
			  case lists:keysearch(Db, 1, DbDocuments) of
			      {value, {Db, Documents}} ->
				  lists:keystore(Db, 1, DbDocuments, {Db, [Document | Documents]});
			      false ->
				  lists:keystore(Db, 1, DbDocuments, {Db, [Document]})
			  end;
		     (_, DbDocuments) ->
			  DbDocuments
		  end, [], get()),
	    %% Write atomically by database
	    lists:foreach(
	      fun({Db, Documents1}) ->
		      Documents =
			  lists:map(fun doc_update_content/1, Documents1),
		      JSON =
			  lists:map(fun(#doc{content = {struct, Content}}) ->
					    Content
				    end, Documents),
		      [#couchdb_database{server = Server,
					 port = Port}] = mnesia:dirty_read(couchdb_database, Db),
		      {json, {struct, RDoc}} =
			  erlang_couchdb:create_documents({Server, Port},
							  atom_to_list(Db),
							  JSON),
		      case lists:keysearch(<<"ok">>, 1, RDoc) of
			  {value, {_, true}} ->
			      ok;
			  false ->
			      case lists:keysearch(<<"error">>, 1, RDoc) of
				  {value, {_, Reason}} ->
				      throw({transaction_aborted, Reason})
			      end
		      end
	      end, DbDocuments)
    end,

    {atomic, FunResult}.


cleanup_transaction() ->
    lists:foreach(
      fun({?DOC(_Db, _Id) = Key, #doc{}}) ->
	      erase(Key);
	 (_) -> ignore
      end, get()).


doc_update_content(#doc{id = Id,
			rev = Rev,
			delete = Delete,
			content = {struct, Content1}} = Document) ->
    Content2 = case Delete of
		   false -> Content1;
		   true -> [{<<"_deleted">>, true}]
	       end,
    Content3 =
	lists:keystore(<<"_id">>, 1, Content2,
		       {<<"_id">>, Id}),
    Content4 = if
		   is_binary(Rev) ->
		       lists:keystore(<<"_rev">>, 1, Content3,
				      {<<"_rev">>, Rev});
		   true ->
		       lists:keydelete(<<"_rev">>, 1, Content3)
	       end,
    Document#doc{content = {struct, Content4}}.


content_id({struct, Dict}) ->
    case lists:keysearch(<<"_id">>, 1, Dict) of
	{value, {_, Id}} -> {id, Id};
	false -> document_without_id
    end.

content_rev({struct, Dict}) ->
    case lists:keysearch(<<"_rev">>, 1, Dict) of
	{value, {_, Rev}} -> Rev;
	false -> none
    end.
