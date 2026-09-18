[windows]
set shell := ["powershell.exe", "-NoLogo", "-NoProfile", "-Command"]

# list recipes
default:
    @just --list

# compile sources
build:
    rebar3 compile

# format sources in place
fmt:
    rebar3 fmt

# fail when sources are not formatted
fmt-check:
    rebar3 fmt --check

# cross reference analysis and dialyzer
lint:
    rebar3 xref
    rebar3 dialyzer

# unit, property and integration tests
test:
    rebar3 do eunit, ct

# the same gates ci runs, cheapest first
check: fmt-check lint test

# erlang shell with the application started
shell:
    rebar3 shell

# self-contained production release with erts
release:
    rebar3 as prod release

# remove build artifacts
clean:
    rebar3 clean --all
