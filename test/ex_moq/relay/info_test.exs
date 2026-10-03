defmodule ExMoQ.Relay.InfoTest do
  use ExUnit.Case, async: true

  alias ExMoQ.Relay
  alias ExMoQ.Relay.Info

  test "a listener on an unspecified address is reached on the loopback one; one that is off is nil" do
    options = %Relay{ip: {0, 0, 0, 0}, quic: {4443, tls_generate: "localhost"}, internal: 9101}

    assert Info.new(options) == %Info{
             quic_url: "https://127.0.0.1:4443",
             tcp_url: nil,
             web_url: nil,
             internal_url: "http://127.0.0.1:9101",
             tls: :generated
           }

    options = %Relay{ip: {0, 0, 0, 0, 0, 0, 0, 0}, quic: nil, tcp: 1}
    assert %Info{tcp_url: "tcp://[::1]:1"} = Info.new(options)
  end

  test "a listener with an :ip of its own is reached on it" do
    options = %Relay{
      ip: {0, 0, 0, 0},
      quic: {4443, tls_generate: "localhost", ip: {192, 0, 2, 1}},
      web: {4443, ip: {0, 0, 0, 0, 0, 0, 0, 1}},
      internal: {9101, ip: {0, 0, 0, 0}}
    }

    assert %Info{
             quic_url: "https://192.0.2.1:4443",
             web_url: "http://[::1]:4443",
             internal_url: "http://127.0.0.1:9101",
             tls: :generated
           } = Info.new(options)
  end

  test "tls tells a generated certificate from a provided one, and is nil without QUIC" do
    assert %Info{tls: :generated} = Info.new(%Relay{quic: {1, tls_generate: "example.com"}})
    assert %Info{tls: :provided} = Info.new(%Relay{quic: {1, tls_generate: nil}})
    assert %Info{tls: nil} = Info.new(%Relay{quic: nil, tcp: 1})
  end
end
