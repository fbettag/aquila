defmodule Aquila.ToolTest do
  use ExUnit.Case, async: true

  alias Aquila.Tool

  @params %{
    "type" => "object",
    "properties" => %{"foo" => %{"type" => "string"}},
    "required" => ["foo"]
  }

  @atom_params %{
    type: :object,
    properties: %{
      foo: %{type: :string, required: true, description: "Foo"},
      bar: %{type: :integer}
    }
  }

  test "new/3 builds struct" do
    tool = Tool.new("echo", [description: "echoes", parameters: @params], fn _ -> :ok end)

    assert tool.name == "echo"
    assert tool.description == "echoes"
    assert tool.parameters == @params
  end

  test "new/3 accepts arity-2 callbacks" do
    tool = Tool.new("echo", [parameters: @params], fn args, ctx -> {args, ctx} end)

    assert :erlang.fun_info(tool.fun)[:arity] == 2
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

  test "normalizes atom-key parameters and builds required list" do
    tool = Tool.new("echo", [parameters: @atom_params], fn _ -> :ok end)

    assert tool.parameters["type"] == "object"
    assert %{"foo" => foo_schema, "bar" => bar_schema} = tool.parameters["properties"]
    assert foo_schema["type"] == "string"
    assert foo_schema["description"] == "Foo"
    assert bar_schema["type"] == "integer"
    assert tool.parameters["required"] == ["foo"]
  end

  test "normalizes nested array schemas" do
    schema = %{
      type: :object,
      properties: %{
        messages: %{
          type: :array,
          required: true,
          items: %{
            type: :object,
            properties: %{
              role: %{type: :string, required: true},
              content: %{type: :string}
            }
          }
        }
      }
    }

    tool = Tool.new("array", [parameters: schema], fn _ -> :ok end)

    params = tool.parameters
    assert params["required"] == ["messages"]

    messages_schema = params["properties"]["messages"]
    assert messages_schema["type"] == "array"

    items_schema = messages_schema["items"]
    assert items_schema["type"] == "object"
    assert items_schema["required"] == ["role"]
    assert items_schema["properties"]["role"]["type"] == "string"
  end
end
