%% @author Couchbase <info@couchbase.com>
%% @copyright 2018-2019 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
-module(ldap_auth).

-include("ns_common.hrl").

-include_lib("eldap/include/eldap.hrl").
-include("cut.hrl").

-export([authenticate/2,
         authenticate/3,
         user_groups/1,
         user_groups/2,
         format_error/1]).

authenticate(Username, Password) ->
    authenticate(Username, Password, ldap_util:build_settings()).

authenticate(Username, Password, Settings) ->
    case proplists:get_value(authentication_enabled, Settings) of
        true ->
            case get_user_DN(Username, Settings) of
                {ok, DN} ->
                    case ldap_util:with_authenticated_connection(
                           DN, Password, Settings, fun (_) -> ok end) of
                        ok -> true;
                        {error, _} -> false
                    end;
                {error, _} -> false
            end;
        false ->
            ?log_debug("LDAP authentication is disabled"),
            false
    end.

with_query_connection(Settings, Fun) ->
    DN = proplists:get_value(query_dn, Settings),
    {password, Pass} = proplists:get_value(query_pass, Settings),
    ldap_util:with_authenticated_connection(DN, Pass, Settings, Fun).

get_user_DN(Username, Settings) ->
    Map = proplists:get_value(user_dn_mapping, Settings),
    case map_user_to_DN(Username, Settings, Map) of
        {ok, DN} ->
            ?log_debug("Username->DN: Constructed DN: ~p for ~p",
                       [ns_config_log:tag_user_name(DN),
                        ns_config_log:tag_user_name(Username)]),
            {ok, DN};
        {error, Error} ->
            ?log_error("Username->DN: Mapping username to LDAP DN failed for "
                       "username ~p with reason ~p",
                       [ns_config_log:tag_user_name(Username), Error]),
            {error, Error}
    end.

map_user_to_DN(Username, _Settings, []) ->
    ?log_debug("Username->DN: rule not found for ~p",
               [ns_config_log:tag_user_name(Username)]),
    {ok, Username};
map_user_to_DN(Username, Settings, [{Re, {Type, Template}} = Rule|T]) ->
    case re:run(Username, Re, [{capture, all_but_first, list}]) of
        nomatch -> map_user_to_DN(Username, Settings, T);
        {match, Captured} ->
            ?log_debug("Username->DN: using rule ~p for ~p",
                       [Rule, ns_config_log:tag_user_name(Username)]),
            ReplaceRe = ?cut(lists:flatten(io_lib:format("\\{~b\\}", [_]))),
            Subs = [{ReplaceRe(N), ldap_util:escape(S)} ||
                        {N, S} <- misc:enumerate(Captured, 0)],
            [Res] = ldap_util:replace_expressions([Template], Subs),
            case Type of
                template -> {ok, Res};
                'query' -> dn_query(Res, Settings)
            end
    end.

dn_query(Query, Settings) ->
    Timeout = proplists:get_value(request_timeout, Settings),
    with_query_connection(
      Settings,
      fun (Handle) ->
              dn_query(Handle, Query, Timeout)
      end).

dn_query(Handle, Query, Timeout) ->
    case ldap_util:parse_url("ldap:///" ++ Query) of
        {ok, URLProps} ->
            Base = proplists:get_value(dn, URLProps, ""),
            Scope = proplists:get_value(scope, URLProps, "one"),
            Filter = proplists:get_value(filter, URLProps, "(objectClass=*)"),
            case ldap_util:search(Handle, Base, ["objectClass"], Scope, Filter,
                                  Timeout) of
                {ok, [#eldap_entry{object_name = DN}]} -> {ok, DN};
                {ok, []} -> {error, dn_not_found};
                {ok, [_|_]} -> {error, not_unique_username};
                {error, Reason} -> {error, {dn_search_failed, Reason}}
            end;
        {error, Error} ->
            {error, {ldap_url_parse_error, Query, Error}}
    end.

user_groups(User) ->
    user_groups(User, ldap_util:build_settings()).
user_groups(User, Settings) ->
    with_query_connection(
      Settings,
      fun (Handle) ->
              Query = proplists:get_value(groups_query, Settings),
              Res = get_groups(Handle, User, Settings, Query),
              ?log_debug("Groups search for ~p: ~p",
                         [ns_config_log:tag_user_name(User), Res]),
              Res
      end).

get_groups(Handle, Username, Settings, QueryStr) ->
    Timeout = proplists:get_value(request_timeout, Settings),
    GetDN =
        fun () ->
                case get_user_DN(Username, Settings) of
                    {ok, DN} -> DN;
                    {error, Reason} ->
                        throw({error, {username_to_dn_map_failed, Reason}})
                end
        end,
    QueryFun =
        fun (G) ->
                Replace = [{"%D", G},
                           {"%u", ?cut(throw({error, user_placeholder}))}],
                run_query(Handle, QueryStr, Replace, Timeout)
        end,
    EscapedUser = ldap_util:escape(Username),
    MaxDepth = proplists:get_value(nested_groups_max_depth, Settings),
    NestedEnabled = proplists:get_bool(nested_groups_enabled, Settings),
    try
        UserGroups = run_query(Handle, QueryStr, [{"%u", EscapedUser},
                                                  {"%D", GetDN}], Timeout),
        case NestedEnabled of
            true -> {ok, get_nested_groups(QueryFun, UserGroups,
                                           UserGroups, MaxDepth)};
            false -> {ok, UserGroups}
        end
    catch
        throw:{error, _} = Error -> Error
    end.

get_nested_groups(_QueryFun, [], Discovered, _MaxDepth) -> Discovered;
get_nested_groups(_QueryFun, _, _, 0) -> throw({error, max_depth});
get_nested_groups(QueryFun, Groups, Discovered, MaxDepth) ->
    NewGroups = lists:flatmap(QueryFun, Groups),
    NewUniqueGroups = lists:usort(NewGroups) -- Discovered,
    ?log_debug("Discovered new groups: ~p (~p)", [NewUniqueGroups, Discovered]),
    get_nested_groups(QueryFun, NewUniqueGroups,
                      NewUniqueGroups ++ Discovered, MaxDepth - 1).

run_query(_Handle, undefined, _ReplacePairs, _Timeout) -> [];
run_query(Handle, Query, ReplacePairs, Timeout) ->
    URLProps =
        case ldap_util:parse_url("ldap:///" ++ Query, ReplacePairs) of
            {ok, Props} -> Props;
            {error, Reason} ->
                throw({error, {invalid_groups_query, Query, Reason}})
        end,

    Base = proplists:get_value(dn, URLProps, ""),
    Scope = proplists:get_value(scope, URLProps, "base"),
    Attrs = proplists:get_value(attributes, URLProps, ["objectClass"]),
    Filter = proplists:get_value(filter, URLProps, "(objectClass=*)"),
    case ldap_util:search(Handle, Base, Attrs, Scope, Filter, Timeout) of
        {ok, L} -> groups_search_res(L, search_type(URLProps));
        {error, Reason2} -> throw({error, {ldap_search_failed, Reason2}})
    end.

groups_search_res([], {attribute, _}) -> {ok, []};
groups_search_res([#eldap_entry{attributes = Attrs}], {attribute, GroupAttr}) ->
    AttrsLower = [{string:to_lower(K), V} || {K, V} <- Attrs],
    proplists:get_value(string:to_lower(GroupAttr), AttrsLower, []);
groups_search_res([_|_], {attribute, _}) ->
    throw({error, not_unique_username});
groups_search_res(Entries, entries) when is_list(Entries) ->
    [DN || #eldap_entry{object_name = DN} <- Entries].

search_type(URLProps) ->
    case proplists:get_value(attributes, URLProps, []) of
        [] -> entries;
        [Attr] -> {attribute, Attr}
    end.

format_error({ldap_search_failed, Reason}) ->
    io_lib:format("LDAP search returned error: ~s", [format_error(Reason)]);
format_error({connect_failed, _}) ->
    "Connot connect to the server";
format_error({start_tls_failed, _}) ->
    "Failed to use StartTLS extension";
format_error({ldap_url_parse_error, URL, Error}) ->
    io_lib:format("Failed to parse ldap url ~p (~s)", [URL, format_error(Error)]);
format_error({dn_search_failed, Reason}) ->
    io_lib:format("LDAP search for user DN failed with reason '~s'",
                  [format_error(Reason)]);
format_error(dn_not_found) ->
    "LDAP DN not found";
format_error(not_unique_username) ->
    "Search returned more than one entry for given username";
format_error({invalid_filter, Filter, Reason}) ->
    io_lib:format("Invalid ldap filter ~p (~s)", [Filter, Reason]);
format_error({username_to_dn_map_failed, R}) ->
    io_lib:format("Failed to map username to DN: ~s", [format_error(R)]);
format_error({invalid_scheme, S}) ->
    io_lib:format("Invalid scheme ~p", [S]);
format_error(malformed_url) ->
    "Malformed LDAP URL";
format_error({invalid_dn, DN}) ->
    io_lib:format("Invalid ldap DN '~s'", [DN]);
format_error({invalid_scope, Scope}) ->
    io_lib:format("Invalid ldap scope: ~p, possible values are one, "
                  "base or sub", [Scope]);
format_error(user_placeholder) ->
    "%u placeholder is not allowed in nested groups search";
format_error(max_depth) ->
    "Nested search max depth has been reached";
format_error(Error) ->
    io_lib:format("~p", [Error]).
