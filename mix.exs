defmodule Aquila.MixProject do
  use Mix.Project

  def project do
    [
      app: :aquila,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      docs: docs(),
      package: package(),
      test_coverage: [tool: ExCoveralls],
      preferred_envs: [
        quality: :test,
        coveralls: :test,
        "coveralls.html": :test,
        "coveralls.json": :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.github": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :telemetry]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.5"},
      {:stable_jason, "~> 2.0"},
      {:telemetry, "~> 1.2"},
      {:phoenix_pubsub, "~> 2.0", optional: true},
      {:phoenix_live_view, "~> 1.0.0", optional: true},

      # testing
      {:plug, "~> 1.15"},
      {:plug_cowboy, "~> 2.7", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.1", only: :test},
      {:git_hooks, "~> 0.8.0", only: [:dev], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      "test.watch": ["test --stale"],
      quality: ["format --check-formatted", "coveralls", "credo"]
    ]
  end

  defp docs do
    [
      main: "Aquila",
      extras: [
        "guides/overview.md",
        "guides/getting-started.md",
        "guides/streaming-and-sinks.md",
        "guides/cassettes-and-testing.md",
        "guides/liveview-integration.md",
        "guides/oban-integration.md",
        "guides/code-quality.md"
      ],
      groups_for_extras: [
        Guides: [
          "guides/overview.md",
          "guides/getting-started.md",
          "guides/streaming-and-sinks.md",
          "guides/cassettes-and-testing.md",
          "guides/liveview-integration.md",
          "guides/oban-integration.md",
          "guides/code-quality.md"
        ]
      ]
    ]
  end

  defp package do
    [
      description:
        "Batteries-included Elixir library for OpenAI-compatible Responses and Chat Completions APIs",
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/fbettag/aquila"
      }
    ]
  end
end
