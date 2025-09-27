defmodule Aquila.ToolTest do
  use ExUnit.Case, async: true

  alias Aquila.Tool

  @params %{
    "type" => "object",
    "properties" => %{"foo" => %{"type" => "string"}},
    "required" => ["foo"]
  }

  test "new/3 builds struct" do
    tool = Tool.new("echo", [description: "echoes", parameters: @params], fn _ -> :ok end)

    assert tool.name == "echo"
    assert tool.description == "echoes"
    assert tool.parameters == @params
  end

  test "to_openai/1 converts struct" do
    tool = Tool.new("echo", [description: "echoes", parameters: @params], fn _ -> :ok end)

    assert %{
             type: "function",
             function: %{name: "echo", description: "echoes", parameters: @params}
           } = Tool.to_openai(tool)
  end

  test "to_openai/1 passes through custom map" do
    map = %{type: :code_interpreter}
    assert %{type: "code_interpreter"} = Tool.to_openai(map)

    string_map = %{type: "file_search"}
    assert %{type: "file_search"} = Tool.to_openai(string_map)
  end

  test "to_openai handles string-key types" do
    map = %{"type" => :function, "function" => %{"name" => "calc"}}
    assert %{"type" => "function"} = Tool.to_openai(map)
  end

  test "new/2 requires parameters" do
    assert_raise ArgumentError, fn -> Tool.new("echo", fn _ -> :ok end) end
  end

  test "to_openai normalises function names" do
    map = %{type: "function", function: %{name: :calc}}
    assert %{function: %{name: :calc}} = Tool.to_openai(map)
  end
end
