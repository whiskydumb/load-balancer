# lb

Layer 4 TCP load balancer built on Erlang/OTP with no runtime dependencies.

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
