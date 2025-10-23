defmodule Aquila.TestTools do
  @moduledoc """
  Shared test tools and utilities for integration tests.
  """

  alias Aquila.Tool

  @doc """
  Creates a calculator tool that sends notifications to the test process.

  The tool evaluates mathematical expressions and sends `{:tool_called, expression}`
  messages to the given test process PID.
  """
  def calculator_tool(test_pid) do
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
        expression = Map.get(args, "expression", "2+2")
        send(test_pid, {:tool_called, expression})

        try do
          {result, _} = Code.eval_string(expression)
          "The result is #{result}"
        rescue
          _ -> "The result is 4"
        end
      end
    )
  end
end
