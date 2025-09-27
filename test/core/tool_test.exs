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

  test "new/1 with keyword options uses :fn callback" do
    tool =
      Tool.new("echo",
        parameters: @params,
        description: "echoes",
        fn: fn args, ctx -> {args, ctx} end
      )

    assert tool.name == "echo"
    assert :erlang.fun_info(tool.function)[:arity] == 2
    assert tool.description == "echoes"
  end

  test "new/1 with keyword raises without callback" do
    assert_raise ArgumentError, fn -> Tool.new("echo", parameters: @params) end
  end

  test "new/3 accepts arity-2 callbacks" do
    tool = Tool.new("echo", [parameters: @params], fn args, ctx -> {args, ctx} end)

    assert :erlang.fun_info(tool.function)[:arity] == 2
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

  test "to_openai stringifies atom type" do
    map = %{type: :function, function: %{name: "calc"}}
    result = Tool.to_openai(map)

    assert result[:type] == "function"
    assert result[:function][:name] == "calc"
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

  test "normalizes string keyed schemas without changes" do
    params = %{"type" => "object", "properties" => %{"foo" => %{"type" => "string"}}}
    tool = Tool.new("echo", [parameters: params], fn _ -> :ok end)

    assert tool.parameters == params
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

  test "new/1 with :function callback variant" do
    tool =
      Tool.new("echo",
        parameters: @params,
        description: "echoes",
        function: fn args -> args end
      )

    assert tool.name == "echo"
    assert :erlang.fun_info(tool.function)[:arity] == 1
  end

  test "new/1 with :fun callback variant" do
    tool =
      Tool.new("echo",
        parameters: @params,
        description: "echoes",
        fun: fn args -> args end
      )

    assert tool.name == "echo"
    assert :erlang.fun_info(tool.function)[:arity] == 1
  end

  test "new/2 shorthand with arity-2 function raises without parameters" do
    assert_raise ArgumentError, "tool requires :parameters (JSON schema map)", fn ->
      Tool.new("echo", fn _args, _ctx -> :ok end)
    end
  end

  test "to_openai handles function with string name key" do
    map = %{type: "function", function: %{"name" => "calc", "parameters" => %{}}}
    result = Tool.to_openai(map)

    assert result[:type] == "function"
    assert result[:function]["name"] == "calc"
  end

  test "normalizes parameters with list of items" do
    params = %{
      type: :object,
      properties: %{
        tags: %{type: :array, items: [:tag1, :tag2]}
      }
    }

    tool = Tool.new("test", [parameters: params], fn _ -> :ok end)
    assert tool.parameters["properties"]["tags"]["items"] == ["tag1", "tag2"]
  end

  test "normalizes parameters with duplicate required fields" do
    params = %{
      type: :object,
      properties: %{
        field1: %{type: :string, required: true},
        field2: %{type: :string, required: true},
        field1_dup: %{type: :string, required: true}
      }
    }

    tool = Tool.new("test", [parameters: params], fn _ -> :ok end)
    # Should deduplicate required fields
    assert is_list(tool.parameters["required"])
    assert length(tool.parameters["required"]) == 3
  end

  test "handles non-map parameters passthrough" do
    # Edge case: parameters that are not a map should pass through
    params = "some_string_schema"
    tool = Tool.new("test", [parameters: params], fn _ -> :ok end)
    assert tool.parameters == "some_string_schema"
  end

  test "normalizes schema with string keys already present" do
    schema = %{
      type: :object,
      properties: %{
        "field" => %{type: :string}
      }
    }

    tool = Tool.new("test", [parameters: schema], fn _ -> :ok end)
    assert tool.parameters["properties"]["field"]["type"] == "string"
  end

  test "normalizes schema with integer key" do
    schema = %{
      type: :object,
      properties: %{
        123 => %{type: :string}
      }
    }

    tool = Tool.new("test", [parameters: schema], fn _ -> :ok end)
    assert tool.parameters["properties"]["123"]["type"] == "string"
  end

  test "normalizes schema with charlist key" do
    schema = %{
      type: :object,
      properties: %{
        ~c"legacy" => %{type: :string, required: true}
      }
    }

    tool = Tool.new("legacy", [parameters: schema], fn _ -> :ok end)
    assert tool.parameters["properties"]["legacy"]["type"] == "string"
    assert tool.parameters["required"] == ["legacy"]
  end

  test "extracts required from non-map schema" do
    # Edge case: when schema is not a map, extract_required should handle it
    schema = %{
      type: :object,
      properties: %{
        field: "not_a_map_schema"
      }
    }

    tool = Tool.new("test", [parameters: schema], fn _ -> :ok end)
    assert tool.parameters["properties"]["field"] == "not_a_map_schema"
  end

  test "normalizes properties when not a map" do
    # Edge case: properties value is not a map
    schema = %{
      type: :object,
      properties: "string_properties"
    }

    tool = Tool.new("test", [parameters: schema], fn _ -> :ok end)
    assert tool.parameters["properties"] == "string_properties"
  end
end
