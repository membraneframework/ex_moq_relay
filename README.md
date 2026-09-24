# moq_relay_runner

Runs a [moq-relay](https://doc.moq.dev/bin/relay) binary as a supervised OS
process from Elixir: finds the binary, picks free ports, renders the command
line, waits until the relay accepts connections, and hands its output and
exit status to the caller.

```elixir
{:ok, relay} = MoqRelay.start_link(tcp: :auto)
MoqRelay.tcp_url(relay)       #=> "tcp://127.0.0.1:54321"   lossless qmux
MoqRelay.quic_url(relay)      #=> "https://127.0.0.1:54322" QUIC, generated certificate
MoqRelay.internal_url(relay)  #=> "http://127.0.0.1:54323"  /health, /metrics, /sessions
MoqRelay.status(relay)        #=> %{alive?: true, exit_status: nil, os_pid: 8123, ports: ..., binary: ...}
```

Under a supervisor: `{MoqRelay, quic: 4443, internal: 9101, on_exit: :stop}`.

The relay comes from the `:binary` option, `$MOQ_RELAY`, or `moq-relay` on
`$PATH`. `start_link/1` blocks until the internal listener (or the TCP one)
accepts a connection, and returns `{:error, reason}` with the relay's first
output lines otherwise, including `{:renamed_flags, lines}` when the binary
is from before the flags below.

Options: `:quic`, `:tcp`, `:internal` (`:auto`, a port, or `nil`),
`:tls_generate`, `:auth_public`, `:log_level`, `:args`, `:on_output`,
`:log_output`, `:ready`, `:ready_timeout`, `:on_exit`, `:name`. See
`MoqRelay` for each.

## Relay versions

The command line is moq-relay 0.14.18's (moq-dev `927051b50` and later):
`--listen`, `--listen-tcp-bind`, `--listen-tls-generate`,
`--internal-listen`, `--auth-public` with path patterns. Earlier relays took
`--server-bind`, `--tls-generate` and `--web-http-listen` and are not
supported; `MoqRelay.version/1` tells which one you have.

## Where this comes from

Four sibling projects each carried their own copy of this: `ExMoQ.Test.Relay`
(ex_moq, TCP for tests), `MoqFuzz.Relay` (moq_fuzz, QUIC plus health
capture), `PingGroups.Relay` (a membrane_moq_plugin example) and
`MoqChaosRelay.Relay`. They drifted when the relay renamed its flags. This
package is the shared part; what each keeps is its own (ExUnit supervision,
panic and memory capture, PubSub status). None of them uses it yet.

## Tests

```
mix test                    # with stand-in scripts, no relay needed
mix test --include relay    # plus one run of the real binary ($MOQ_RELAY)
```
