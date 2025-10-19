defmodule Aquila.MessageFormattingTest do
  use ExUnit.Case, async: true

  alias Aquila.Message

  test "tool_output_message emits tool_result structure when requested" do
    message =
      Message.tool_output_message("calculator", "42",
        tool_call_id: "call-123",
        format: :tool_result
      )

    assert message.role == :tool
    assert message.tool_call_id == "call-123"

    [%{"type" => "tool_result", "tool_use_id" => "call-123", "content" => [block]}] =
      message.content

    assert block["type"] == "output_text"
    assert block["text"] == "42"

    chat_map = Message.to_chat_map(message)
    assert chat_map.role == "tool"
    assert chat_map.tool_call_id == "call-123"
    assert chat_map.content == message.content
  end
end
