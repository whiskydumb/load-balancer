# lb

Layer 4 TCP load balancer built on Erlang/OTP with no runtime dependencies.

## Balancing strategies

Every strategy honours backend weights.

| Strategy      | Algorithm                                              | Fits when                                 |
| ------------- | ------------------------------------------------------ | ----------------------------------------- |
| `round_robin` | smooth weighted round robin, as in nginx               | backends are alike, connections are short |
| `least_conn`  | power of two choices over active connections by weight | connection lifetimes vary widely          |
| `source_hash` | weighted rendezvous hashing of the client address      | a client must stick to one backend        |

## Requirements

- Erlang/OTP 27 or newer
- [rebar3](https://rebar3.org) 3.24 or newer
- [just](https://github.com/casey/just) for task shortcuts (optional)

## Development

```sh
just build       # compile
just fmt         # format with erlfmt
just check       # fmt-check, xref, dialyzer, tests
just shell       # erlang shell with the application started
just release     # production release in _build/prod/rel/lb
```

Run `just` without arguments to list every recipe.
