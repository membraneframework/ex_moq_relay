defmodule ExMoQ.Relay.ConfigTest do
  use ExUnit.Case, async: true

  alias ExMoQ.Relay.Config

  defp config!(opts), do: Config.new!([binary: "/bin/sh"] ++ opts)

  test "every :auto listener gets a port, and the rest are kept" do
    config = config!(web: 4443)

    assert %Config{quic: {quic, tls_generate: "localhost"}, web: 4443, tcp: nil} = config
    assert is_integer(quic) and is_integer(config.internal)
  end

  test ":ready is the first listener that is on, or the one named if it is on" do
    assert %Config{ready: :internal} = config!(web: :auto)
    assert %Config{ready: :web} = config!(web: :auto, internal: nil)
    assert %Config{ready: :none} = config!(internal: nil)
    assert %Config{ready: :web} = config!(web: :auto, ready: :web)
    assert %Config{ready: :none} = config!(ready: :none)
  end

  test "a config the relay cannot run with is rejected" do
    assert_raise ArgumentError, ~r/no moq-relay binary/, fn ->
      config!(binary: "/nonexistent/moq-relay")
    end

    assert_raise ArgumentError, ~r/needs a :quic or a :tcp listener/, fn ->
      config!(quic: nil, web: :auto)
    end

    assert_raise ArgumentError, ~r/ready: :web probes a listener that is off/, fn ->
      config!(ready: :web)
    end
  end
end
