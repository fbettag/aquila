defmodule Aquila.ToolOpenAITest do
  use ExUnit.Case, async: true

  alias Aquila.Tool

  test "to_openai includes top-level name for Tool struct" do
    tool = Tool.new("calculator", fn _ -> "ok" end)
    openai = Tool.to_openai(tool)

    assert openai.name == "calculator"
    assert openai.type == "function"
    assert openai.function.name == "calculator"
  end

  test "to_openai includes top-level name for map inputs" do
    tool_map = %{
      type: :function,
      function: %{
        name: "lookup",
        parameters: %{"type" => "object", "properties" => %{}}
      }
    }

    openai = Tool.to_openai(tool_map)
    assert openai[:name] == "lookup"
    assert openai.type == "function"
  end
end
