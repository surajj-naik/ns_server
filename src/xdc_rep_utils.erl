%% @author Couchbase <info@couchbase.com>
%% @copyright 2011 Couchbase, Inc.
%%
% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

% XDC Replication Specific Utility Functions

-module(xdc_rep_utils).

-export([remote_vbucketmap_nodelist/1, local_couch_uri_for_vbucket/2]).
-export([remote_couch_uri_for_vbucket/3, my_active_vbuckets/1]).
-export([lists_difference/2, node_uuid/0, info_doc_id/1]).


% Given a remote bucket URI, this function fetches the node list and the vbucket
% map.
remote_vbucketmap_nodelist(BucketURI) ->
    case httpc:request(get, {BucketURI, []}, [], []) of
    {ok, {{_, 404, _}, _, _}} ->
        not_present;
    {ok, {_, _, JsonStr}} ->
        {KVList} = ejson:decode(JsonStr),
        {VbucketServerMap} = couch_util:get_value(<<"vBucketServerMap">>,
                                                  KVList),
        VbucketMap = couch_util:get_value(<<"vBucketMap">>, VbucketServerMap),
        NodeList = couch_util:get_value(<<"nodes">>, KVList),
        {ok, {VbucketMap, NodeList}}
    end.


% Given a Bucket name and a vbucket id, this function computes the Couch URI to
% locally access it.
local_couch_uri_for_vbucket(BucketName, VbucketId) ->
    iolist_to_binary([BucketName, $/, integer_to_list(VbucketId)]).


% Given the vbucket map and node list of a remote bucket and a vbucket id, this
% function computes the CAPI URI to access it.
remote_couch_uri_for_vbucket(VbucketMap, NodeList, VbucketId) ->
    [Owner | _ ] = lists:nth(VbucketId+1, VbucketMap),
    {OwnerNodeProps} = lists:nth(Owner+1, NodeList),
    CapiBase = couch_util:get_value(<<"couchApiBase">>, OwnerNodeProps),
    CapiBase.


% Given a bucket config, this function computes a list of active vbuckets
% currently owned by the executing node.
my_active_vbuckets(BucketConfig) ->
    VBucketMap = couch_util:get_value(map, BucketConfig),
    [Ordinal-1 ||
        {Ordinal, Owner} <- misc:enumerate([Head || [Head|_] <- VBucketMap]),
        Owner == node()].


% Computes the differences between two lists and returns them as a tuple.
lists_difference(List1, List2) ->
    {List1 -- List2, List2 -- List1}.


% Fetches the UUID of the current node.
node_uuid() ->
    {value, UUID} = ns_config:search_node(uuid),
    UUID.


% Given an XDC doc id, this function generates the correspondence replication
% info doc id.
info_doc_id(XDocId) ->
    UUID = node_uuid(),
    <<XDocId/binary, "_info_", UUID/binary>>.
