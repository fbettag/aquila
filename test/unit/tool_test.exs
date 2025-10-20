defmodule Aquila.ToolOpenAITest do
  use ExUnit.Case, async: true

  alias Aquila.Tool

  test "to_openai does not include top-level name for Tool struct (Mistral compatibility)" do
    tool = Tool.new("calculator", fn _ -> "ok" end)
    openai = Tool.to_openai(tool)

    # Top-level name field should NOT be present for provider compatibility (e.g., Mistral)
    refute Map.has_key?(openai, :name)
    refute Map.has_key?(openai, "name")

    assert openai.type == "function"
    assert openai.function.name == "calculator"
  end

  test "to_openai does not add top-level name for map inputs (preserves existing if present)" do
    tool_map = %{
      type: :function,
      function: %{
        name: "lookup",
        parameters: %{"type" => "object", "properties" => %{}}
      }
    }

    openai = Tool.to_openai(tool_map)
    # Should not add top-level name field for provider compatibility
    refute Map.has_key?(openai, :name)
    refute Map.has_key?(openai, "name")
    assert openai.type == "function"
    assert openai.function.name == "lookup"
  end
end
