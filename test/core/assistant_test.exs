defmodule Aquila.AssistantTest do
  use ExUnit.Case, async: true

  alias Aquila.Assistant

  describe "new/1" do
    test "creates assistant with all options" do
      tools = [%{name: "test"}]
      messages = [%{role: :user, content: "hi"}]

      assistant =
        Assistant.new(
          instructions: "You are helpful",
          tools: tools,
          model: "gpt-4o",
          temperature: 0.7,
          context: %{foo: "bar"},
          messages: messages
        )

      assert assistant.instructions == "You are helpful"
      assert assistant.tools == tools
      assert assistant.model == "gpt-4o"
      assert assistant.temperature == 0.7
      assert assistant.context == %{foo: "bar"}
      assert assistant.messages == messages
    end

    test "creates assistant with empty options" do
      assistant = Assistant.new()

      assert assistant.instructions == nil
      assert assistant.tools == nil
      assert assistant.model == nil
      assert assistant.temperature == nil
      assert assistant.context == nil
      assert assistant.messages == nil
    end

    test "accepts :system as alias for :instructions" do
      assistant = Assistant.new(system: "You are helpful")
      assert assistant.instructions == "You are helpful"
    end

    test ":instructions takes precedence over :system" do
      assistant = Assistant.new(instructions: "From instructions", system: "From system")
      assert assistant.instructions == "From instructions"
    end
  end

  describe "with_system/2" do
    test "sets instructions" do
      assistant =
        Assistant.new()
        |> Assistant.with_system("You are helpful")

      assert assistant.instructions == "You are helpful"
    end

    test "updates existing instructions" do
      assistant =
        Assistant.new(instructions: "Old")
        |> Assistant.with_system("New")

      assert assistant.instructions == "New"
    end
  end

  describe "with_tools/2" do
    test "sets tools" do
      tools = [%{name: "calculator"}]

      assistant =
        Assistant.new()
        |> Assistant.with_tools(tools)

      assert assistant.tools == tools
    end
  end

  describe "with_model/2" do
    test "sets model" do
      assistant =
        Assistant.new()
        |> Assistant.with_model("gpt-4o")

      assert assistant.model == "gpt-4o"
    end
  end

  describe "with_temperature/2" do
    test "sets temperature" do
      assistant =
        Assistant.new()
        |> Assistant.with_temperature(0.9)

      assert assistant.temperature == 0.9
    end
  end

  describe "with_context/2" do
    test "sets context" do
      context = %{session: "123"}

      assistant =
        Assistant.new()
        |> Assistant.with_context(context)

      assert assistant.context == context
    end
  end

  describe "with_messages/2" do
    test "sets messages" do
      messages = [%{role: :user, content: "hello"}]

      assistant =
        Assistant.new()
        |> Assistant.with_messages(messages)

      assert assistant.messages == messages
    end
  end

  describe "chaining" do
    test "multiple with_* functions can be chained" do
      tools = [%{name: "tool"}]
      messages = [%{role: :user, content: "hi"}]

      assistant =
        Assistant.new()
        |> Assistant.with_system("You are helpful")
        |> Assistant.with_model("gpt-4o-mini")
        |> Assistant.with_temperature(0.5)
        |> Assistant.with_tools(tools)
        |> Assistant.with_context(%{session: "abc"})
        |> Assistant.with_messages(messages)

      assert assistant.instructions == "You are helpful"
      assert assistant.model == "gpt-4o-mini"
      assert assistant.temperature == 0.5
      assert assistant.tools == tools
      assert assistant.context == %{session: "abc"}
      assert assistant.messages == messages
    end
  end
end
