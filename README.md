# ExMoQ.Relay

[![Hex.pm](https://img.shields.io/hexpm/v/ex_moq_relay.svg)](https://hex.pm/packages/ex_moq_relay)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/ex_moq_relay)

Runs a [moq-relay](https://doc.moq.dev/bin/relay) binary as a supervised OS
process from Elixir, for integration tests, demos and local tooling around
Media over QUIC.

## Installation

```elixir
def deps do
  [
    {:ex_moq_relay, "~> 0.1.0"}
  ]
end
```

It runs moq-relay 0.15.0 or later, installed with `cargo install moq-relay`
or from a [release](https://github.com/moq-dev/moq/releases).

## Usage

```elixir
{:ok, relay} = ExMoQ.Relay.start_link(%ExMoQ.Relay{tcp: :auto, web: :auto})
%ExMoQ.Relay.Info{tcp_url: tcp_url, web_url: web_url} = ExMoQ.Relay.info(relay)
tcp_url  #=> "tcp://127.0.0.1:54321"
web_url  #=> "http://127.0.0.1:54322"
ExMoQ.Relay.stop(relay)
```

For available options, see `ExMoQ.Relay`.

## Copyright and License

Copyright 2026, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=ex_moq_relay)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=membrane-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=ex_moq_relay)

Licensed under the [Apache License, Version 2.0](LICENSE)
