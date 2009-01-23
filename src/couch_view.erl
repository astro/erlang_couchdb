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
%% @doc Semi-automatic view installer
%% 
%% Updates at http://github.com/astro/erlang_couchdb/
-module(couch_view).

%% API
-export([install_from_dir/2]).


%%====================================================================
%% API
%%====================================================================

%% Install views from a directory:
%%
%% dir/designdocument1_viewname1_map.js
%% dir/designdocument1_viewname1_reduce.js
%%
%% dir/designdocument1_viewname2_map.js
%% dir/designdocument1_viewname2_reduce.js
%%
%% dir/designdocument2_viewname1_map.js
%% dir/designdocument2_viewname1_reduce.js
%%
%% dir/designdocument2_viewname2_map.js
%% dir/designdocument2_viewname2_reduce.js
%%
%% dir/${designdocument}_${view}_${function}.js
install_from_dir(Db, Dir) ->
    {ok, Files} = file:list_dir(Dir),
    Functions =
	lists:foldl(fun(Filename, R) ->
			    case split_filename(Filename) of
				{D, V, F} ->
				    {ok, X} =
					file:read_file(Dir ++ "/" ++ Filename),
				    [{D, V, {F, X}} | R];
				false ->
				    R
			    end
		    end, [], Files),
    %% Group by D:
    Design =
	lists:foldl(
	  fun({D, V, FX}, R) ->
		  VFX = case lists:keysearch(D, 1, R) of
			    {value, {D, VFX_}} -> VFX_;
			    false -> []
			end,
		  VFX2 = [{V, FX} | VFX],
		  lists:keystore(D, 1, R, {D, VFX2})
	  end, [], Functions),
    %% Group by V:
    DesignGrouped =
	[{D, lists:foldl(
	       fun({V, FX1}, R) ->
		       FX = case lists:keysearch(V, 1, R) of
				{value, {V, FX_}} ->
				    FX_;
				false ->
				    []
			    end,
		       FX2 = [FX1 | FX],
		       lists:keystore(V, 1, R, {V, FX2})
	       end, [], VFX)}
	 || {D, VFX} <- Design],
    %% Produce JSON:
    D_JSON = [{D, {struct, [{language, <<"javascript">>},
			    {views, {struct, [{V, {struct, FX}}
					      || {V, FX} <- VFX]}}]}}
	      || {D, VFX} <- DesignGrouped],
    error_logger:info_msg("Installing views for database ~p:~n~p~n",
			  [Db, D_JSON]),
    {atomic, _} =
	couch_lier:transaction(
	  fun() ->
		  lists:foreach(
		    fun({D, JSON}) ->
			    couch_lier:write(
			      Db, 
			      list_to_binary(["_design/", D]),
			      JSON)
		    end, D_JSON)
	  end).
			       

%%====================================================================
%% Internal functions
%%====================================================================

split_filename(Filename) ->
    case string:tokens(Filename, ".") of
	[Filename1, "js"] ->
	    case string:tokens(Filename1, "_") of
		[S1, S2 | [_ | _] = R] ->
		    S3 = string:join(R, $_),
		    {list_to_binary(S1), list_to_binary(S2), list_to_binary(S3)};
		_ ->
		    false
	    end;
	_ ->
	    false
    end.
