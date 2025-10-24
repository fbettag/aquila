defmodule Aquila.ChatEngineTest do
  use ExUnit.Case, async: true

  alias Aquila.Engine.Chat
  alias Aquila.Message

  describe "rebuild_tool_messages_for_retry/2" do
    test "switches to function role when tool role is unsupported" do
      tool_message =
        Message.tool_output_message("calc", "{\"result\":2}",
          tool_call_id: "call-1",
          format: :text
        )

      state = %{
        messages: [Message.new(:user, "input"), tool_message],
        last_tool_outputs: [%{call_id: "call-1", name: "calc", output: "{\"result\":2}"}],
        supports_tool_role: nil,
        role_retry_count: 0,
        tool_message_format: :text,
        error: %RuntimeError{message: "role mismatch"}
      }

      new_state = Chat.rebuild_tool_messages_for_retry(state, {:role, false})

      assert new_state.supports_tool_role == false
      assert new_state.role_retry_count == 1
      assert new_state.error == nil

      assert Enum.map(new_state.messages, & &1.role) == [:user, :function]

      [_, function_message] = new_state.messages
      assert function_message.role == :function
      assert function_message.name == "calc"
    end

    test "rebuilds tool messages with tool_result format" do
      tool_message =
        Message.tool_output_message("calc", "2",
          tool_call_id: "call-1",
          format: :text
        )

      state = %{
        messages: [Message.new(:user, "input"), tool_message],
        last_tool_outputs: [%{call_id: "call-1", name: "calc", output: "2"}],
        supports_tool_role: true,
        role_retry_count: 0,
        tool_message_format: :text,
        error: %RuntimeError{message: "format mismatch"}
      }

      new_state = Chat.rebuild_tool_messages_for_retry(state, {:format, :tool_result})

      assert new_state.tool_message_format == :tool_result
      assert new_state.error == nil

      [_, rebuilt_message] = new_state.messages
      assert rebuilt_message.role == :tool
      assert [%{"type" => "tool_result"} | _] = rebuilt_message.content
    end
  end

  describe "build_body/2" do
    test "encodes atom tool choice into function map" do
      state = %{
        model: "gpt-test",
        instructions: nil,
        messages: [Message.new(:user, "ping")],
        tool_defs: [
          %{
            "type" => "function",
            "function" => %{"name" => "calc"}
          }
        ],
        tool_choice: {:function, :calc},
        tool_message_format: :text,
        supports_tool_role: nil,
        metadata: nil,
        store: true
      }

      body = Chat.build_body(state, true)

      assert body.model == "gpt-test"
      assert body.stream == true

      assert [%{role: "user", content: "ping"}] = body.messages
      assert state.tool_defs == body.tools

      assert %{"type" => "function", "function" => %{"name" => "calc"}} = body.tool_choice
    end

    test "omits metadata when store disabled" do
      state = %{
        model: "gpt-test",
        instructions: nil,
        messages: [Message.new(:user, "ping")],
        tool_defs: [],
        tool_choice: :auto,
        tool_message_format: :text,
        supports_tool_role: nil,
        metadata: %{foo: "bar"},
        store: false
      }

      body = Chat.build_body(state, false)

      refute Map.has_key?(body, :metadata)
      refute Map.has_key?(body, "metadata")
    end
  end
end
