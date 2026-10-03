defmodule ExMoQ.Relay.OptionsTest do
  use ExUnit.Case, async: true

  alias ExMoQ.Relay

  defp relay!(fields), do: struct!(Relay, [binary: "/bin/sh"] ++ fields)

  test "options the relay cannot run with are rejected before it is started" do
    assert_raise ArgumentError, ~r/no moq-relay binary/, fn ->
      Relay.start(relay!(binary: "/nonexistent/moq-relay"))
    end

    assert_raise ArgumentError, ~r/needs a :quic or a :tcp listener/, fn ->
      Relay.start(relay!(quic: nil, web: :auto))
    end

    assert_raise ArgumentError, ~r/:internal must be a port or nil/, fn ->
      Relay.child_spec(relay!(internal: :auto))
    end

    assert_raise ArgumentError, ~r/:log_level must be one of/, fn ->
      Relay.start_link(relay!(log_level: "WARN"))
    end

    assert_raise ArgumentError, ~r/:internal must be a port or nil/, fn ->
      Relay.start(relay!(internal: {:auto, ip: {0, 0, 0, 0}}))
    end

    assert_raise ArgumentError, ~r/unknown keys \[:subscibe\]/, fn ->
      Relay.start(relay!(auth_public: [subscibe: "**"]))
    end

    assert_raise ArgumentError, ~r/unknown keys \[:host\]/, fn ->
      Relay.start(relay!(web: {4443, host: "localhost"}))
    end
  end

  describe "args/1" do
    test "renders the listeners that are asked for" do
      assert Relay.args(relay!(quic: 4443, tcp: 4444, internal: 9101)) == [
               "--log-level",
               "warn",
               "--listen",
               "127.0.0.1:4443",
               "--listen-tcp-bind",
               "127.0.0.1:4444",
               "--internal-listen",
               "127.0.0.1:9101",
               "--listen-tls-generate",
               "localhost",
               "--auth-public",
               "**"
             ]
    end

    test "a TCP-only relay needs no certificate; patterns and extra args pass through" do
      assert Relay.args(
               relay!(
                 quic: nil,
                 tcp: 1,
                 internal: nil,
                 log_level: "info",
                 auth_public: ["anon/**", "demo/**"],
                 args: ["--stats-enabled"]
               )
             ) == [
               "--log-level",
               "info",
               "--listen-tcp-bind",
               "127.0.0.1:1",
               "--auth-public",
               "anon/**,demo/**",
               "--stats-enabled"
             ]
    end

    test "every listener binds to :ip, and the web one may share the QUIC port" do
      assert Relay.args(relay!(ip: {0, 0, 0, 0}, quic: 4443, web: 4443, internal: nil)) == [
               "--log-level",
               "warn",
               "--listen",
               "0.0.0.0:4443",
               "--web-http-listen",
               "0.0.0.0:4443",
               "--listen-tls-generate",
               "localhost",
               "--auth-public",
               "**"
             ]

      assert Relay.args(relay!(ip: {0, 0, 0, 0, 0, 0, 0, 1}, quic: nil, tcp: 1, internal: nil)) ==
               ["--log-level", "warn", "--listen-tcp-bind", "[::1]:1", "--auth-public", "**"]
    end

    test "a listener with an :ip of its own binds to it" do
      options =
        relay!(
          ip: {0, 0, 0, 0},
          quic: {4443, ip: {192, 0, 2, 1}},
          tcp: {:auto, ip: {0, 0, 0, 0, 0, 0, 0, 1}},
          web: {4443, ip: {127, 0, 0, 1}},
          internal: 9101
        )

      assert Relay.args(options) == [
               "--log-level",
               "warn",
               "--listen",
               "192.0.2.1:4443",
               "--listen-tcp-bind",
               "[::1]:0",
               "--web-http-listen",
               "127.0.0.1:4443",
               "--internal-listen",
               "0.0.0.0:9101",
               "--listen-tls-generate",
               "localhost",
               "--auth-public",
               "**"
             ]
    end

    test "anonymous sessions are granted subscribing and publishing apart" do
      assert Relay.args(
               relay!(
                 quic: nil,
                 tcp: 1,
                 auth_public: [subscribe: ["demo/**", "live/**"], publish: "uploads/**"]
               )
             ) == [
               "--log-level",
               "warn",
               "--listen-tcp-bind",
               "127.0.0.1:1",
               "--auth-public-subscribe",
               "demo/**,live/**",
               "--auth-public-publish",
               "uploads/**"
             ]

      assert Relay.args(relay!(quic: nil, tcp: 1, auth_public: [subscribe: "**"])) ==
               ["--log-level", "warn", "--listen-tcp-bind", "127.0.0.1:1"] ++
                 ["--auth-public-subscribe", "**"]
    end

    test "auth_public: nil grants nothing, leaving auth to extra args" do
      assert Relay.args(
               relay!(
                 quic: nil,
                 tcp: 1,
                 internal: nil,
                 auth_public: nil,
                 args: ["--auth-url", "http://127.0.0.1:4440/"]
               )
             ) == [
               "--log-level",
               "warn",
               "--listen-tcp-bind",
               "127.0.0.1:1",
               "--auth-url",
               "http://127.0.0.1:4440/"
             ]
    end

    test "the QUIC listener carries the host of its generated certificate, or none" do
      assert Relay.args(relay!(quic: {4443, tls_generate: "relay.test"}, internal: nil)) ==
               [
                 "--log-level",
                 "warn",
                 "--listen",
                 "127.0.0.1:4443",
                 "--listen-tls-generate",
                 "relay.test",
                 "--auth-public",
                 "**"
               ]

      assert Relay.args(relay!(quic: {4443, tls_generate: nil}, internal: nil)) ==
               ["--log-level", "warn", "--listen", "127.0.0.1:4443", "--auth-public", "**"]
    end

    test ":auto listeners bind port 0" do
      assert Relay.args(relay!(quic: {:auto, tls_generate: nil}, tcp: :auto)) == [
               "--log-level",
               "warn",
               "--listen",
               "127.0.0.1:0",
               "--listen-tcp-bind",
               "127.0.0.1:0",
               "--auth-public",
               "**"
             ]
    end
  end
end
