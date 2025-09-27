defmodule Aquila.MessageTest do
  use ExUnit.Case, async: true

  alias Aquila.Message

  describe "coerce/1" do
    test "accepts tuples" do
      assert %Message{role: :user, content: "hi"} = Message.coerce({:user, "hi"})
    end

    test "accepts maps with atom keys" do
      assert %Message{role: :assistant, content: "ok", name: "bot"} =
               Message.coerce(%{role: :assistant, content: "ok", name: "bot"})
    end

    test "accepts maps with string keys" do
      assert %Message{role: :function, content: %{"value" => 1}, name: "adder"} =
               Message.coerce(%{
                 "role" => "function",
                 "content" => %{"value" => 1},
                 "name" => "adder"
               })
    end

    test "raises on unknown string role" do
      assert_raise ArgumentError, fn ->
        Message.coerce(%{"role" => "unknown", "content" => "x"})
      end
    end

    test "raises on invalid shape" do
      assert_raise ArgumentError, fn -> Message.coerce(%{foo: :bar}) end
    end

    test "accepts string roles for system/user/assistant" do
      assert %Message{role: :system} = Message.coerce(%{"role" => "system", "content" => "s"})
      assert %Message{role: :user} = Message.coerce(%{"role" => "user", "content" => "u"})

      assert %Message{role: :assistant} =
               Message.coerce(%{"role" => "assistant", "content" => "a"})
    end
  end

  describe "normalize/2" do
    test "normalizes strings with optional instruction" do
      messages = Message.normalize("hi", instruction: "system")

      assert [%Message{role: :system, content: "system"}, %Message{role: :user, content: "hi"}] =
               messages
    end

    test "normalizes strings with instructions alias" do
      messages = Message.normalize("hi", instructions: "system")

      assert [%Message{role: :system, content: "system"}, %Message{role: :user, content: "hi"}] =
               messages
    end

    test "passes through message lists" do
      list = [%Message{role: :assistant, content: "done"}]
      assert Message.normalize(list, []) == list
    end

    test "wraps single message" do
      message = %Message{role: :user, content: "hi"}
      assert [^message] = Message.normalize(message, [])
    end
  end

  test "to_chat_map/1 converts to map" do
    message = %Message{role: :assistant, content: "hello", name: "bot"}
    assert %{role: "assistant", content: "hello", name: "bot"} = Message.to_chat_map(message)
  end

  test "function_message/2 builds function response" do
    message = Message.function_message("calc", ["1", "2"])
    assert %Message{role: :function, content: "12", name: "calc"} = message
  end
end
