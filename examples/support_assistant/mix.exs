defmodule SupportAssistant.MixProject do
  use Mix.Project

  def project do
    [
      app: :support_assistant,
      version: "0.1.0",
      elixir: "~> 1.19",
      deps: [{:aquila, path: "../.."}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
