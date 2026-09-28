defmodule ExMoQ.Relay.ConfigTest do
  use ExUnit.Case, async: true

  alias ExMoQ.Relay.Config

  test "every :auto listener gets a port, and the rest are kept" do
    config = Config.new!(web: 4443)

    assert %Config{quic: {quic, tls_generate: "localhost"}, web: 4443, tcp: nil} = config
    assert is_integer(quic) and is_integer(config.internal)
  end

  test "the certificate host belongs to the QUIC listener" do
    assert %Config{quic: {4443, tls_generate: "relay.test"}} =
             Config.new!(quic: {4443, tls_generate: "relay.test"})

    assert %Config{quic: {4443, tls_generate: nil}} = Config.new!(quic: {4443, tls_generate: nil})

    assert_raise ArgumentError, ~r/unknown keys \[:tls_genrate\]/, fn ->
      Config.new!(quic: {4443, tls_genrate: "relay.test"})
    end

    assert_raise ArgumentError, ~r/needs a port or :auto/, fn ->
      Config.new!(quic: {nil, tls_generate: "relay.test"})
    end
  end

  test "an unknown option is rejected" do
    assert_raise KeyError, ~r/:interal/, fn -> Config.new!(interal: :auto) end
  end

  test "a relay has a QUIC or a TCP listener" do
    assert %Config{quic: nil, tcp: tcp} = Config.new!(quic: nil, tcp: :auto)
    assert is_integer(tcp)

    assert_raise ArgumentError, ~r/needs a :quic or a :tcp listener/, fn ->
      Config.new!(quic: nil, web: :auto)
    end
  end

  test "listeners take :auto, a port or nil" do
    for bad <- [0, 65_536, "4443", :any] do
      assert_raise ArgumentError, ~r/:web must be :auto, a port or nil/, fn ->
        Config.new!(web: bad)
      end
    end
  end

  test ":ready is the first listener that is on, or the one named if it is on" do
    assert %Config{ready: :internal} = Config.new!(web: :auto)
    assert %Config{ready: :web} = Config.new!(web: :auto, internal: nil)
    assert %Config{ready: :none} = Config.new!(internal: nil)
    assert %Config{ready: :web} = Config.new!(web: :auto, ready: :web)
    assert %Config{ready: :none} = Config.new!(ready: :none)

    assert_raise ArgumentError, ~r/ready: :web probes a listener that is off/, fn ->
      Config.new!(ready: :web)
    end

    assert_raise ArgumentError, ~r/:ready must be/, fn ->
      Config.new!(ready: :quic)
    end
  end
end
