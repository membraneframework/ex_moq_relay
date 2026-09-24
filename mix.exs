defmodule MoqRelayRunner.MixProject do
  use Mix.Project

  @version "0.1.0"
  @github_url "https://github.com/membraneframework/moq_relay_runner"

  def project do
    [
      app: :moq_relay_runner,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Runs a moq-relay binary as a supervised OS process, with readiness and output capture",
      package: package(),
      name: "MoqRelay",
      source_url: @github_url,
      docs: [main: "readme", extras: ["README.md"], source_ref: "v#{@version}"]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:muontrap, "~> 1.8"}
    ]
  end

  defp package do
    [
      maintainers: ["Membrane Team"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @github_url},
      files: ["lib", "mix.exs", "README*", "LICENSE*", ".formatter.exs"]
    ]
  end
end
