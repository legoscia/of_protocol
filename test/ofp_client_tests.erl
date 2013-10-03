-module(ofp_client_tests).

-include_lib("eunit/include/eunit.hrl").
-include("of_protocol.hrl").
-include("ofp_v4.hrl").

-define(LISTEN_ADDRESS, {127, 0, 0, 1}).

%% Generators ------------------------------------------------------------------

change_role_generation_id_test_() ->
    {setup,
     fun generation_id_setup/0,
     fun generation_id_teardown/1,
     fun change_roles/1
    }.

active_controller_test_() ->
    {foreach,
     fun active_controller_setup/0,
     fun active_controller_teardown/1,
     [fun expect_hello/1,
      fun expect_client_terminate/1]}.

%% Tests ----------------------------------------------------------------------

change_roles(State) ->
    {"Test if the ofp_client responds with the correct generation id "
     "depending on the role request",
     fun() ->
             [begin
                  ok = change_roles(generation_id() - N,
                                    max_generation_id(), N, State)
              end || N <- lists:seq(1, 10)]
     end}.

change_roles(_, _, 0, _) ->
    ok;
change_roles(CurrentGenId, LastGenId, N, State) ->
    {RoleReply, NewState} =
        ofp_client:change_role(?VERSION, Role = role(), CurrentGenId, State),
    case Role of
        R when R == nochange orelse R == equal ->
            ?assertEqual(LastGenId,
                         RoleReply#ofp_role_reply.generation_id),
            change_roles(CurrentGenId, LastGenId, N - 1, NewState);
        R when R == master orelse R == slave ->
            ?assertEqual(CurrentGenId,
                         RoleReply#ofp_role_reply.generation_id),
            change_roles(CurrentGenId + 1,
                         RoleReply#ofp_role_reply.generation_id,
                         N - 1,
                         NewState)
    end.

expect_hello({Tid, ListenSocket, ControllerSocket}) ->
    {"Test if the ofp_client started with a socket holding an established "
     "connection will send a hello message",
     fun() ->
             {ok, OFPClientSocket} = gen_tcp:accept(ListenSocket),
             {ok, Pid} = ofp_client:start_link(Tid, "ID",
                                                {socket, OFPClientSocket, tcp},
                                                [{versions, [4]}]),
             {ok, BinMsg} = gen_tcp:recv(ControllerSocket, 0),
             {ok, DecodedMsg, _}  = of_protocol:decode(BinMsg),
             ?assertMatch(#ofp_message{body = #ofp_hello{}}, DecodedMsg),
             ofp_client:stop(Pid),
             gen_tcp:close(ControllerSocket)
     end}.

expect_client_terminate({Tid, ListenSocket, ControllerSocket}) ->
    {"Test if the ofp_client started with a socket holding an established "
     "connection will stop when the connection is terminated by the controller",
     fun() ->
             erlang:process_flag(trap_exit, true),
             {ok, OFPClientSocket} = gen_tcp:accept(ListenSocket),
             {ok, Pid} = ofp_client:start_link(Tid, "ID",
                                               {socket, OFPClientSocket, tcp},
                                               [{versions, [4]}]),
             ok = gen_tcp:controlling_process(OFPClientSocket, Pid),
             ok = gen_tcp:close(ControllerSocket),
             ClientTeminatedNormally = receive
                                           {'EXIT', Pid, normal} ->
                                               true
                                       after 3000 ->
                                               false
                                       end,
             ?assert(ClientTeminatedNormally),
             ?assertNot(erlang:is_process_alive(Pid))
     end}.

%% Fixtures -------------------------------------------------------------------

generation_id_setup() ->
    random:seed(erlang:now()),
    mock_ofp_channel(),
    mock_ofp_client_state().

generation_id_teardown(_) ->
    unmock_ofp_channel().

active_controller_setup() ->
    random:seed(erlang:now()),
    {ok, ListenSocket} = gen_tcp:listen(Port = random_port(),
                                        [{ip, ?LISTEN_ADDRESS}]),
    {ok, ControllerSocket} = gen_tcp:connect(?LISTEN_ADDRESS, Port,
                                             [{active, false}, binary]),
    {ets:new(dummy, [public]), ListenSocket, ControllerSocket}.

active_controller_teardown({_Tid, ListenSocket, ControllerSocket}) ->
    ok = gen_tcp:close(ListenSocket),
    ok = gen_tcp:close(ControllerSocket).

%% Helper functions ------------------------------------------------------------

generation_id() ->
    random:uniform(16#FFFFFFFFFFFFFFFF).

max_generation_id() ->
    16#FFFFFFFFFFFFFFFF.

role() ->
    Roles = [nochange, equal, master, slave],
    lists:nth(random:uniform(length(Roles)), Roles).

mock_ofp_channel() ->
    ok = meck:new(ofp_channel),
    ok = meck:expect(ofp_channel, make_slaves,
                     fun(_, _) ->
                             ok
                     end).

mock_ofp_client_state() ->
    DummyTid = ets:new(dummy, []),
    {ok, State, 0} = ofp_client:init({DummyTid,
                                      resource_id,
                                      {remote_peer, ip, port, proto},
                                      parent,
                                      [],
                                      main,
                                      sup}),
    State.

unmock_ofp_channel() ->
    ok = meck:unload(ofp_channel).

random_port() ->
    random:uniform(49152) + 16383.
