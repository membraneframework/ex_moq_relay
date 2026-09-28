# ExMoQ.Relay

[![Hex.pm](https://img.shields.io/hexpm/v/ex_moq_relay.svg)](https://hex.pm/packages/ex_moq_relay)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/ex_moq_relay)

Runs a [moq-relay](https://doc.moq.dev/bin/relay) binary as a supervised OS
process from Elixir: finds the binary, picks free ports, renders the command
line, waits until the relay accepts connections, and hands its output and
exit status to the caller. Useful for integration tests, demos and local
tooling around Media over QUIC.

## Installation

```elixir
def deps do
  [
    {:ex_moq_relay, "~> 0.1.0"}
  ]
end
```

It needs a moq-relay binary, 0.15.0 or later, from the `:binary` option,
`$MOQ_RELAY`, or `moq-relay` on `$PATH` (e.g. `cargo install moq-relay`, or a
[release](https://github.com/moq-dev/moq/releases)).

## Usage

```elixir
{:ok, relay} = ExMoQ.Relay.start_link(tcp: :auto, web: :auto)
ExMoQ.Relay.tcp_url(relay)       #=> "tcp://127.0.0.1:54321"   lossless qmux
ExMoQ.Relay.quic_url(relay)      #=> "https://127.0.0.1:54322" QUIC, generated certificate
ExMoQ.Relay.web_url(relay)       #=> "http://127.0.0.1:54323"  /health, /certificate.sha256, /fetch
ExMoQ.Relay.internal_url(relay)  #=> "http://127.0.0.1:54324"  /health, /metrics, /sessions
ExMoQ.Relay.status(relay)        #=> %{alive?: true, exit_status: nil, os_pid: 8123, ip: ..., ports: ..., binary: ...}
```

Under a supervisor, e.g. a relay reachable from other hosts with its web
listener on the QUIC port number (TCP and UDP ports are separate):

```elixir
{ExMoQ.Relay, ip: {0, 0, 0, 0}, quic: 4443, web: 4443, internal: 9101, on_exit: :stop}
```

`start_link/1` blocks until the relay accepts connections on the internal
listener (else the web one, else the TCP one) and returns `{:error, reason}`
with the relay's first output lines otherwise. The options and caveats are
documented in `ExMoQ.Relay`.

In ExUnit, `ExMoQ.Test.Relay.start_supervised!/1` runs a relay for the current
test; add the package with `only: :test` for that.

## Copyright and License

Copyright 2026, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=ex_moq_relay)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=membrane-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=ex_moq_relay)

Licensed under the [Apache License, Version 2.0](LICENSE)
