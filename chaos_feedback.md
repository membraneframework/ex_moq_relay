- **One address per listener.** `:ip` binds QUIC, TCP, web and internal
  alike. Here QUIC has to be public (the grid's direct row) while the web
  listener (`/fetch` serves any broadcast) is for the app only, so
  `MoqChaosRelay.Relay` sets `web: nil, ready: :none`, passes
  `--web-http-listen 127.0.0.1:<port>` in `:args` and probes readiness
  itself. Something like `web: {port, ip: {127, 0, 0, 1}}`, in the shape of
  `quic: {port, opts}`, would remove that.
- **Readiness on any address, or a public `await_ready`.** Following from
  the above: once a listener is passed through `:args`, readiness is lost.
  `ready: {:tcp, host, port}` or an exported probe would let callers keep
  the blocking start.
- **The relay's output in start errors.** `{:exited, {:exit_status, n}}`
  says that it failed, not why ("address in use", an unknown flag from an
  older relay). The first or last few lines in the error would put the
  reason in the application's crash report, not only in the log.
- **Auth as first-class options.** `:auth_public` is there, but
  `--auth-public-subscribe` / `--auth-public-publish` only go through
  `:args`. Narrowing a demo relay to "anyone subscribes, only we publish"
  is the obvious first step of any deployment.
- **An `--auth-url` counterpart.** moq-relay 0.15 has no token keys, only
  `--auth-url`, so "only this app may publish" means answering the relay's
  auth requests (the contract is in moq-dev/moq's `doc/bin/relay/auth.md`,
  schemas `moq_auth::Request` and `moq_auth::Grant`). A Plug, or a small
  behaviour, that decodes the request and encodes the grant, and an
  `:auth_url` option on the config, would make that a few lines in any app
  that runs a relay. The app now does this by hand
  (`MoqChaosRelay.Relay.Auth`, a Bandit on a Unix socket, `--auth-url` in
  `:args`), with the publish key in the URL query.
- **The certificate hash as a function.** Browsers pin the relay's
  self-signed certificate by hash, and every app that serves a page needs
  to hand it out. The page cannot fetch it from the relay (plain HTTP from
  an HTTPS page is blocked), so the app proxies `/certificate.sha256`
  (`MoqChaosRelayWeb.RelayController`). `ExMoQ.Relay.certificate_hash/1`
  would make that one call.
