defmodule Aquila.ToolCompatibilityTest do
  use ExUnit.Case, async: false
  use Aquila.Cassette

  alias Aquila.Tool

  @moduledoc """
  Comprehensive tool compatibility testing across different model providers.
  Tests ensure custom function tools are properly serialized for each provider.
  Uses live API calls with cassette recording.

  Note: Built-in tools (code_interpreter, file_search, etc.) are OpenAI-specific
  and not supported by most providers via litellm. Users can pass raw tool maps
  for provider-specific features if needed.
  """

  @models [
    "openai/gpt-3.5-turbo",
    "openai/gpt-4o-mini",
    "openai/gpt-4.1-mini",
    "openai/gpt-5-mini",
    "anthropic/claude-3-5-sonnet-latest",
    "anthropic/claude-3-opus-latest",
    "anthropic/claude-sonnet-4-5",
    "anthropic/claude-haiku-4-5",
    "mistral/mistral-small",
    "moonshot/kimi-latest",
    "deepseek/deepseek-chat",
    "xai/grok-3-mini-latest",
    "xai/grok-4-fast-non-reasoning"
  ]

  # Helper to create custom function tool that calculates
  defp calculator_tool(test_pid) do
    Tool.new(
      "calculator",
      [
        description:
          "Performs basic arithmetic calculations. Use this to calculate math expressions.",
        parameters: %{
          type: :object,
          properties: %{
            expression: %{
              type: :string,
              required: true,
              description: "Math expression to evaluate (e.g., '2+2', '10*5')"
            }
          }
        }
      ],
      fn args ->
        # Notify test that tool was called
        expression = Map.get(args, "expression", "unknown")
        send(test_pid, {:tool_called, expression})
        "The result is 42"
      end
    )
  end

  describe "custom function tool compatibility" do
    for model <- @models do
      test "#{model} accepts and calls custom function tool" do
        model = unquote(model)

        aquila_cassette "tool_compat/#{sanitize_model(model)}/custom_function" do
          response =
            Aquila.ask(
              "Please calculate 2+2 using the calculator tool. You must use the calculator tool to answer this.",
              model: model,
              tools: [calculator_tool(self())],
              timeout: 30_000
            )

          # Verify the model provided a response
          assert response.text != ""

          # Verify the tool was actually called
          assert_receive {:tool_called, expression},
                         5000,
                         "Expected calculator tool to be called by #{model}, but it was not invoked"

          # The expression should be related to the calculation
          assert is_binary(expression), "Expected expression to be a string"
        end
      end
    end
  end

  # Helper to sanitize model name for file paths
  defp sanitize_model(model) do
    model
    |> String.replace("/", "_")
    |> String.replace(".", "_")
    |> String.replace("-", "_")
  end
end
