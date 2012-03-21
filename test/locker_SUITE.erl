-module(locker_SUITE).
-compile([export_all]).
-include_lib("test_server/include/test_server.hrl").
-include_lib("eqc/include/eqc.hrl").

all() ->
    [
     api,
     quorum,
     no_quorum_possible,
     release,
     lease_extend,
     one_node_down,
     extend_propagates,
     add_remove_node,
     replica,
     promote
    ].

api(_) ->
    [A, B, C] = Cluster = setup([a, b, c]),
    ok = rpc:call(A, locker, set_nodes, [Cluster, Cluster, []]),

    {ok, Cluster, [], 2} = rpc:call(A, locker, get_nodes, []),

    ok = rpc:call(A, locker, set_w, [[A], 3]),
    {ok, Cluster, [], 3} = rpc:call(A, locker, get_nodes, []),
    ok = rpc:call(A, locker, set_w, [[A], 2]),

    {ok, 2, 3, 3} = rpc:call(A, locker, lock, [123, self()]),
    %% slave:stop(C),
    Pid = rpc:call(C, erlang, whereis, [locker]),
    true = rpc:call(C, erlang, exit, [Pid, kill]),
    false = rpc:call(C, erlang, is_process_alive, [Pid]),
    {ok, 2, 2, 2} = rpc:call(A, locker, release, [123, self()]),
    {ok, 2, 2, 2} = rpc:call(B, locker, lock, [123, self()]),

    teardown([A, B, C]).

quorum(_) ->
    [A, B, C] = Cluster = setup([a, b, c]),
    ok = rpc:call(A, locker, set_nodes, [Cluster, Cluster, []]),

    Parent = self(),
    spawn(fun() ->
                  Parent ! {1, catch rpc:call(A, locker, lock, [123, Parent])}
          end),
    spawn(fun() ->
                  Parent ! {2, catch rpc:call(B, locker, lock, [123, Parent])}
          end),
    receive {1, P1} -> P1 after 1000 -> throw(timeout) end,
    receive {2, P2} -> P2 after 1000 -> throw(timeout) end,

    ?line {ok, Pid} = rpc:call(A, locker, pid, [123]),
    ?line {ok, Pid} = rpc:call(B, locker, pid, [123]),
    ?line {ok, Pid} = rpc:call(C, locker, pid, [123]),

    {ok, [], [{123, {Pid, _}}], _, _} = rpc:call(A, locker, get_debug_state, []),
    {ok, [], [{123, {Pid, _}}], _, _} = rpc:call(B, locker, get_debug_state, []),
    {ok, [], [{123, {Pid, _}}], _, _} = rpc:call(C, locker, get_debug_state, []),

    teardown([A, B, C]).

no_quorum_possible(_) ->
    [A, B, C] = setup([a, b, c]),
    ok = rpc:call(A, locker, set_nodes, [[A, B], [A, B], []]),

    Parent = self(),
    spawn(fun() ->
                  Parent ! {1, catch rpc:call(A, locker, lock, [123, Parent])}
          end),
    spawn(fun() ->
                  Parent ! {2, catch rpc:call(B, locker, lock, [123, Parent])}
          end),

    {error, no_quorum} = receive {1, P1} -> P1 after 1000 -> throw(timeout) end,
    {error, no_quorum} = receive {2, P2} -> P2 after 1000 -> throw(timeout) end,

    {error, not_found} = rpc:call(A, locker, pid, [123]),
    {error, not_found} = rpc:call(B, locker, pid, [123]),
    {error, not_found} = rpc:call(C, locker, pid, [123]),

    {ok, [], [], _, _} = rpc:call(A, locker, get_debug_state, []),
    {ok, [], [], _, _} = rpc:call(B, locker, get_debug_state, []),
    {ok, [], [], _, _} = rpc:call(C, locker, get_debug_state, []),

    teardown([A, B, C]).

release(_) ->
    [A, B, C] = Cluster = setup([a, b, c]),
    ok = rpc:call(A, locker, set_nodes, [Cluster, Cluster, []]),

    Value = self(),
    {ok, 2, 3, 3} = rpc:call(A, locker, lock, [123, Value]),

    {ok, Value} = rpc:call(A, locker, pid, [123]),
    {ok, Value} = rpc:call(B, locker, pid, [123]),
    {ok, Value} = rpc:call(C, locker, pid, [123]),
    slave:stop(A),
    slave:stop(B),

    {error, no_quorum} = rpc:call(C, locker, release, [123, Value]),
    {ok, Value} = rpc:call(C, locker, pid, [123]),

    teardown([A, B, C]).

one_node_down(_) ->
    [A, B, C] = Cluster = setup([a, b, c]),
    ok = rpc:call(A, locker, set_nodes, [Cluster, Cluster, []]),
    slave:stop(C),

    Pid = self(),
    spawn(fun() ->
                  Pid ! {1, catch rpc:call(A, locker, lock, [123, Pid])}
          end),
    receive {1, P1} -> P1 after 1000 -> throw(timeout) end,

    {ok, Pid} = rpc:call(A, locker, pid, [123]),
    {ok, Pid} = rpc:call(B, locker, pid, [123]),

    {ok, [], [{123, {Pid, _}}], _, _} = rpc:call(A, locker, get_debug_state, []),
    {ok, [], [{123, {Pid, _}}], _, _} = rpc:call(B, locker, get_debug_state, []),

    teardown([A, B, C]).

extend_propagates(_) ->
    [A, B, C] = setup([a, b, c]),
    ok = rpc:call(A, locker, set_nodes, [[A, B], [A, B], []]),

    Pid = self(),
    {ok, 2, 2, 2} = rpc:call(A, locker, lock, [123, Pid]),

    {ok, Pid} = rpc:call(A, locker, pid, [123]),
    {ok, Pid} = rpc:call(B, locker, pid, [123]),
    {error, not_found} = rpc:call(C, locker, pid, [123]),

    {ok, [], [{123, {Pid, _}}], _, _} = state(A),
    {ok, [], [{123, {Pid, _}}], _, _} = state(B),
    {ok, [], [], _, _} = state(C),

    ok = rpc:call(A, locker, set_nodes, [[A, B, C], [A, B], [C]]),

    ok = rpc:call(A, locker, extend_lease, [123, Pid, 2000]),

    {ok, [], [{123, {Pid, ExA}}], _, _} = state(A),
    {ok, [], [{123, {Pid, ExB}}], _, _} = state(B),
    {ok, [], [{123, {Pid, ExC}}], _, _} = state(C),

    abs((ExA - ExB)) < 3 orelse throw(too_much_drift),
    abs((ExB - ExC)) < 3 orelse throw(too_much_drift),
    abs((ExA - ExC)) < 3 orelse throw(too_much_drift),

    teardown([A, B, C]).


lease_extend(_) ->
    [A, B, C] = Cluster = setup([a, b, c]),
    ok = rpc:call(A, locker, set_nodes, [Cluster, Cluster, []]),

    Pid = self(),
    {ok, _, _, _} = rpc:call(A, locker, lock, [123, Pid]),
    {ok, Pid} = rpc:call(A, locker, pid, [123]),
    {ok, Pid} = rpc:call(B, locker, pid, [123]),
    {ok, Pid} = rpc:call(C, locker, pid, [123]),

    timer:sleep(2000),
    rpc:sbcast([A, B, C], locker, expire_leases),

    {error, not_found} = rpc:call(A, locker, pid, [123]),
    {error, not_found} = rpc:call(B, locker, pid, [123]),
    {error, not_found} = rpc:call(C, locker, pid, [123]),

    {ok, _, _, _} = rpc:call(A, locker, lock, [123, Pid]),
    {ok, Pid} = rpc:call(A, locker, pid, [123]),
    {ok, Pid} = rpc:call(B, locker, pid, [123]),
    {ok, Pid} = rpc:call(C, locker, pid, [123]),


    ok = rpc:call(B, locker, extend_lease, [123, Pid, 2000]),
    rpc:sbcast([A, B, C], locker, expire_leases),
    {ok, Pid} = rpc:call(A, locker, pid, [123]),
    {ok, Pid} = rpc:call(B, locker, pid, [123]),
    {ok, Pid} = rpc:call(C, locker, pid, [123]),

    ok.

add_remove_node(_) ->
    [A, B, C] = Cluster = setup([a, b, c]),
    ok = rpc:call(A, locker, set_nodes, [Cluster, Cluster, []]),

    {ok, 2, 3, 3} = rpc:call(A, locker, lock, [123, self()]),
    {ok, 2, 3, 3} = rpc:call(B, locker, release, [123, self()]),

    ok = rpc:call(A, locker, set_nodes, [Cluster, [A, B], []]),
    {ok, 2, 2, 2} = rpc:call(A, locker, lock, [123, self()]),

    teardown([A, B, C]).

replica(_) ->
    [A, B, C] = Cluster = setup([a, b, c]),
    ok = rpc:call(A, locker, set_nodes, [Cluster, [A, B], [C]]),

    {ok, [A, B], [C], 2} = rpc:call(A, locker, get_nodes, []),
    {ok, [A, B], [C], 2} = rpc:call(B, locker, get_nodes, []),
    {ok, [A, B], [C], 2} = rpc:call(C, locker, get_nodes, []),

    Pid = self(),
    {ok, 2, 2, 3} = rpc:call(A, locker, lock, [123, Pid]),
    {ok, Pid} = rpc:call(A, locker, pid, [123]),
    {ok, Pid} = rpc:call(B, locker, pid, [123]),
    {ok, Pid} = rpc:call(C, locker, pid, [123]),

    slave:stop(B),

    {error, no_quorum} = rpc:call(A, locker, release, [123, Pid]),

    teardown([A, B, C]).

promote(_) ->
    [A, B, C] = Cluster = setup([a, b, c]),
    ok = rpc:call(A, locker, set_nodes, [Cluster, [A, B], [C]]),

    Pid = self(),
    {ok, 2, 2, 3} = rpc:call(A, locker, lock, [123, Pid]),
    {ok, Pid} = rpc:call(A, locker, pid, [123]),
    {ok, Pid} = rpc:call(B, locker, pid, [123]),
    {ok, Pid} = rpc:call(C, locker, pid, [123]),


    ok = rpc:call(A, locker, set_nodes, [Cluster, [A, B, C], []]),
    {ok, 2, 3, 3} = rpc:call(A, locker, release, [123, Pid]),

    teardown([A, B, C]).


setup(Name) when is_atom(Name) ->
    error_logger:info_msg("starting ~p~n", [Name]),
    {ok, Node} = slave:start_link(list_to_atom(net_adm:localhost()), Name),

    true = rpc:call(Node, code, add_path, ["/home/knutin/git/locker/ebin"]),
    {ok, _} = rpc:call(Node, locker, start_link, [2]),

    {ok, _, _, R1, R2} = rpc:call(Node, locker, get_debug_state, []),
    {ok, cancel} = rpc:call(Node, timer, cancel, [R1]),
    {ok, cancel} = rpc:call(Node, timer, cancel, [R2]),
    Node;

setup(NodeNames) ->
    lists:map(fun setup/1, NodeNames).


teardown(Nodes) ->
    lists:map(fun slave:stop/1, Nodes).

state(N) ->
    rpc:call(N, locker, get_debug_state, []).
