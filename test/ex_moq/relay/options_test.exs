defmodule ExMoQ.Relay.OptionsTest do
  use ExUnit.Case, async: true

  alias ExMoQ.Relay

  @spec relay!(Relay.options()) :: Relay.options()
  defp relay!(opts), do: Keyword.merge([binary: "/bin/sh"], opts)

  test "options that fail validation are rejected before the relay is started" do
    assert {:error, {:binary_not_found, "/nonexistent/moq-relay"}} =
             Relay.start(relay!(binary: "/nonexistent/moq-relay"))

    assert {:error, {:validation_failed, message}} = Relay.start(relay!(quic: nil, web: 8080))
    assert message =~ ~r/needs a :quic or a :tcp listener/

    assert {:error, {:validation_failed, message}} = Relay.start(relay!(tcp: :auto))
    assert message =~ ~r/:tcp must be a port or \{port, opts\}, got: :auto/

    assert {:error, {:validation_failed, message}} = Relay.start_link(relay!(log: "WARN"))
    assert message =~ ~r/:log must be a Logger level/

    assert {:error, {:validation_failed, message}} = Relay.start(relay!(log: nil))
    assert message =~ ~r/or :none, got: nil/

    assert {:error, {:validation_failed, message}} = Relay.start(relay!(auth: [subscibe: "**"]))
    assert message =~ ~r/unknown keys \[:subscibe\]/

    assert {:error, {:validation_failed, message}} = Relay.start(relay!(auth: {:url, ""}))
    assert message =~ ~r/:auth \{:url, url\} needs a non-empty string/

    assert {:error, {:validation_failed, message}} =
             Relay.start(relay!(web: {4443, host: "localhost"}))

    assert message =~ ~r/unknown keys \[:host\]/

    assert {:error, {:validation_failed, message}} = Relay.start(relay!(qiuc: 4443))
    assert message =~ ~r/unknown keys \[:qiuc\]/

    assert {:error, {:validation_failed, message}} = Relay.start(relay!(binary: 123))
    assert message =~ ~r/:binary must be a path, got: 123/
  end

  describe "args/1" do
    test "renders the listeners that are asked for, with or without the binary" do
      relay = relay!(quic: 4443, tcp: 4444, internal: 9101)

      assert Relay.args(Keyword.put(relay, :binary, "/nonexistent/moq-relay")) ==
               Relay.args(relay)

      assert Relay.args(relay) == [
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
                 log: {:info, &IO.puts/1},
                 auth: ["anon/**", "demo/**"],
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

    test "a relay whose log is discarded prints as little as it can" do
      assert Relay.args(relay!(quic: nil, tcp: 1, log: :none)) ==
               ["--log-level", "error", "--listen-tcp-bind", "127.0.0.1:1", "--auth-public", "**"]
    end

    test "the web listener may share the QUIC port" do
      assert Relay.args(relay!(quic: {4443, ip: {0, 0, 0, 0}}, web: {4443, ip: {0, 0, 0, 0}})) ==
               [
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
    end

    test "a listener binds to its :ip, or to 127.0.0.1 without one" do
      options =
        relay!(
          quic: {4443, ip: {192, 0, 2, 1}},
          tcp: {4444, ip: {0, 0, 0, 0, 0, 0, 0, 1}},
          web: {4443, ip: {127, 0, 0, 1}},
          internal: 9101
        )

      assert Relay.args(options) == [
               "--log-level",
               "warn",
               "--listen",
               "192.0.2.1:4443",
               "--listen-tcp-bind",
               "[::1]:4444",
               "--web-http-listen",
               "127.0.0.1:4443",
               "--internal-listen",
               "127.0.0.1:9101",
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
                 auth: [subscribe: ["demo/**", "live/**"], publish: "uploads/**"]
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

      assert Relay.args(relay!(quic: nil, tcp: 1, auth: [subscribe: "**"])) ==
               ["--log-level", "warn", "--listen-tcp-bind", "127.0.0.1:1"] ++
                 ["--auth-public-subscribe", "**"]
    end

    test "auth: nil grants nothing; {:url, url} admits through a server" do
      assert Relay.args(relay!(quic: nil, tcp: 1, auth: nil)) == [
               "--log-level",
               "warn",
               "--listen-tcp-bind",
               "127.0.0.1:1"
             ]

      assert Relay.args(relay!(quic: nil, tcp: 1, auth: {:url, "unix:///tmp/auth.sock"})) == [
               "--log-level",
               "warn",
               "--listen-tcp-bind",
               "127.0.0.1:1",
               "--auth-url",
               "unix:///tmp/auth.sock"
             ]
    end

    @tag :tmp_dir
    test "the QUIC listener carries the hosts of its generated certificate, or its files", %{
      tmp_dir: dir
    } do
      assert Relay.args(relay!(quic: {4443, tls: {:generate, ["localhost", "relay.test"]}})) ==
               [
                 "--log-level",
                 "warn",
                 "--listen",
                 "127.0.0.1:4443",
                 "--listen-tls-generate",
                 "localhost,relay.test",
                 "--auth-public",
                 "**"
               ]

      [cert, key] = Enum.map(["cert.pem", "key.pem"], &Path.join(dir, &1))
      Enum.each([cert, key], &File.touch!/1)

      assert Relay.args(relay!(quic: {4443, tls: {:files, cert, key}})) ==
               [
                 "--log-level",
                 "warn",
                 "--listen",
                 "127.0.0.1:4443",
                 "--listen-tls-cert",
                 cert,
                 "--listen-tls-key",
                 key,
                 "--auth-public",
                 "**"
               ]
    end
  end
end
