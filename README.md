# lb

[![ci](https://github.com/whiskydumb/load-balancer/actions/workflows/ci.yml/badge.svg)](https://github.com/whiskydumb/load-balancer/actions/workflows/ci.yml)

Layer 4 TCP load balancer on Erlang/OTP, with nothing outside the standard
library at runtime.

- weighted balancing: smooth round robin, least connections, source hashing
- active health checks with hysteresis, plus failed client connects as evidence
- backpressure from the kernel backlog down to each direction of a connection
- admin API over HTTP for status, metrics and changes to pools while running
- prometheus metrics, optional json logs
- graceful shutdown that turns new clients away and lets open ones finish

## Quick start

```sh
just build       # compile
just shell       # erlang shell with config/sys.config loaded
just check       # fmt-check, xref, dialyzer, tests
```

`config/sys.config` ships a listener on port 8080 in front of two backends on
ports 9001 and 9002, and the admin API on `127.0.0.1:9900`. Run `just` with no
arguments to list every recipe.

Requirements: Erlang/OTP 27 or newer, [rebar3](https://rebar3.org),
and [just](https://github.com/casey/just) for the shortcuts.

## Configuration

The node validates its configuration before the supervision tree starts, so a
typo stops the boot with a message naming the exact path:

```
listeners[1].port: expected an integer in 0..65535, got 70000
```

```erlang
{lb, [
    {listeners, [
        #{name => web, port => 8080, pool => web_backends}
    ]},
    {pools, [
        #{
            name => web_backends,
            strategy => round_robin,
            connect_timeout => 2000,
            health_check => #{interval => 5000, timeout => 1000, rise => 2, fall => 3},
            backends => [
                #{host => "127.0.0.1", port => 9001, weight => 1},
                #{host => "127.0.0.1", port => 9002, weight => 2}
            ]
        }
    ]},
    {admin, #{enabled => true, ip => "127.0.0.1", port => 9900}}
]}
```

### Listener

| Option             | Default     | Meaning                                              |
| ------------------ | ----------- | ---------------------------------------------------- |
| `name`             | required    | used in logs, metrics and the admin API              |
| `port`             | required    | 0 lets the operating system pick a free port         |
| `pool`             | required    | pool this listener sends its clients to              |
| `ip`               | `{0,0,0,0}` | address to bind                                      |
| `acceptors`        | 10          | processes waiting in accept                          |
| `backlog`          | 1024        | kernel queue of clients waiting to be accepted       |
| `max_connections`  | 10000       | beyond this clients wait in the backlog              |
| `idle_timeout`     | 3600000 ms  | closes a connection once both directions go quiet    |
| `connect_attempts` | 3           | backends one client may try before it is turned away |
| `drain_timeout`    | 5000 ms     | grace open connections get when the node stops       |

### Pool

| Option            | Default       | Meaning                                    |
| ----------------- | ------------- | ------------------------------------------ |
| `name`            | required      | referenced by listeners and the admin API  |
| `strategy`        | `round_robin` | see below                                  |
| `connect_timeout` | 5000 ms       | how long one attempt on a backend may take |
| `backends`        | `[]`          | may also be filled through the admin API   |
| `health_check`    | see below     | active probing of the backends             |

A backend takes `host` and `port`, plus a `weight` from 1 to 100 that defaults
to 1. A host may be written as a string, binary, atom or address tuple, so
`"127.0.0.1"` and `{127,0,0,1}` name the same backend.

### Health check

| Option     | Default | Meaning                                   |
| ---------- | ------- | ----------------------------------------- |
| `enabled`  | true    | with probes off no failure is acted upon  |
| `interval` | 5000 ms | time between probes, spread by 10% jitter |
| `timeout`  | 2000 ms | how long one probe may take               |
| `rise`     | 2       | successes in a row to return to rotation  |
| `fall`     | 3       | failures in a row to leave rotation       |

### Admin API and environment

| Option    | Default       | Meaning                           |
| --------- | ------------- | --------------------------------- |
| `enabled` | false         | admin API is off unless asked for |
| `ip`      | `{127,0,0,1}` | address to bind                   |
| `port`    | 9900          | port to bind                      |

| Variable         | Meaning                                                  |
| ---------------- | -------------------------------------------------------- |
| `LB_ADMIN_TOKEN` | bearer token for the admin API; only its digest is kept  |
| `LB_LOG_FORMAT`  | `json` writes one object per line, anything else is text |

## Balancing strategies

Every strategy honours backend weights.

| Strategy      | Algorithm                                              | Fits when                                 |
| ------------- | ------------------------------------------------------ | ----------------------------------------- |
| `round_robin` | smooth weighted round robin, as in nginx               | backends are alike, connections are short |
| `least_conn`  | power of two choices over active connections by weight | connection lifetimes vary widely          |
| `source_hash` | weighted rendezvous hashing of the client address      | a client must stick to one backend        |

## Health

A backend serves new connections while it is healthy and not drained by an
operator. Health moves on consecutive results: `fall` failures in a row take a
backend out, `rise` successes in a row bring it back, so one lost probe changes
nothing. Probes are plain TCP connects, one prober per backend, spread by
jitter. Client connections that fail to reach a backend count as failures too,
which takes a dead backend out well before the next probe would.

## Admin API

Everything but `/health` needs `Authorization: Bearer $LB_ADMIN_TOKEN`.
Tokens are compared as digests, in constant time.

| Request                                          | Does                                     |
| ------------------------------------------------ | ---------------------------------------- |
| `GET /health`                                    | liveness, open so probes need no secrets |
| `GET /metrics`                                   | prometheus text format                   |
| `GET /pools`                                     | pools with health, weights and counters  |
| `GET /listeners`                                 | listeners with ports and counters        |
| `POST /pools/{pool}/backends`                    | add a backend                            |
| `DELETE /pools/{pool}/backends/{host:port}`      | remove a backend                         |
| `POST /pools/{pool}/backends/{host:port}/drain`  | stop new connections to it               |
| `POST /pools/{pool}/backends/{host:port}/enable` | put it back in rotation                  |

```sh
export TOKEN=...   # same value as LB_ADMIN_TOKEN

curl -H "authorization: Bearer $TOKEN" localhost:9900/pools

curl -H "authorization: Bearer $TOKEN" -X POST \
    -d '{"host": "10.0.0.7", "port": 9003, "weight": 2}' \
    localhost:9900/pools/web_backends/backends

curl -H "authorization: Bearer $TOKEN" -X POST \
    localhost:9900/pools/web_backends/backends/10.0.0.7:9003/drain
```

Rejected input comes back explained:

```json
{"error": "invalid backend", "problems": ["port: expected an integer in 1..65535, got 70000"]}
```

Changes made this way apply immediately and survive a pool restart, but not a
node restart: the config file remains the source of truth.

## Metrics

| Metric                                   | Type    | Labels              |
| ---------------------------------------- | ------- | ------------------- |
| `lb_listener_connections_accepted_total` | counter | listener            |
| `lb_listener_connections_active`         | gauge   | listener            |
| `lb_listener_bytes_total`                | counter | listener, direction |
| `lb_listener_no_backend_total`           | counter | listener            |
| `lb_backend_up`                          | gauge   | pool, backend       |
| `lb_backend_draining`                    | gauge   | pool, backend       |
| `lb_backend_connections_active`          | gauge   | pool, backend       |
| `lb_backend_connections_total`           | counter | pool, backend       |
| `lb_backend_connect_failures_total`      | counter | pool, backend       |
| `lb_vm_processes`, `lb_vm_memory_bytes`  | gauge   | none                |

Counters survive a restart of the listener or pool that owns them; only a node
restart sets them back to zero.

## Architecture

```
lb_sup                          rest_for_one
+-- lb_tables                   owns the shared ets tables
+-- lb_pools_sup                one_for_one
|   `-- lb_pool_sup             per pool, rest_for_one
|       +-- lb_pool             membership, health, connection accounting
|       `-- lb_health_sup       one prober per backend
+-- lb_listeners_sup            one_for_one
|   `-- lb_listener_sup         per listener, rest_for_one
|       +-- lb_listener         listen socket, connection limit, draining
|       `-- lb_acceptor_sup     acceptors waiting in accept
`-- lb_admin                    admin api, only when enabled
```

A connection travels like this:

1. an acceptor takes it and asks the listener for a proxy; at `max_connections`
   that request waits, so further clients stay in the kernel backlog;
2. the proxy picks a backend by reading the pool's published selector straight
   from ets, without calling any process;
3. it connects, trying other backends up to `connect_attempts`, and every
   failed attempt counts against that backend's health;
4. two pumps move bytes, one per direction, until both sides are done or the
   connection falls idle.

Decisions worth knowing:

- **Picks never call a process.** A pool publishes an immutable selector into
  ets whenever membership or health changes; connections only read it, so a
  busy or restarting pool cannot stall traffic.
- **A pump per direction.** A single relay loop that blocks sending to a backend
  which writes before it reads stops reading that backend and deadlocks with
  it. With a pump each way, a blocked send stalls only its own direction.
- **Slots are released by monitors.** The pool monitors connection processes,
  so a connection that crashes cannot leak a backend slot.
- **State outlives its owner.** Membership, counters and open connections live
  in ets tables owned by a process in front of the pools, so a restarted pool
  adopts the connections that are still open and keeps runtime changes.
- **Health lives in the pool.** Probers hold no state, which means a restarted
  prober can never disagree with the pool about a backend.

## Development

```sh
just fmt         # erlfmt
just lint        # xref and dialyzer
just test        # eunit, property tests and common test
just check       # everything ci runs, cheapest first
just release     # self-contained release in _build/prod/rel/lb
```

Tests come in three shapes: eunit for units, PropEr properties for the parts
with invariants worth stating (balancing, hysteresis, config, log format, and a
stateful model of the pool), and Common Test suites that drive the whole
application over real sockets. CI runs the same gates on OTP 27, 28 and 29.

## Limits

- TCP only: no TLS termination and no routing on request contents.
- One node: no clustering, no shared state between balancers beyond the fact
  that `source_hash` picks the same backend everywhere for the same client.
- Changes made through the admin API are not written back to the config file.
