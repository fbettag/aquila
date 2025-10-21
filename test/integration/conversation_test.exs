defmodule Aquila.ConversationTest do
  use ExUnit.Case, async: false
  use Aquila.Cassette

  @moduledoc """
  Tests multi-turn conversations to ensure context is maintained across exchanges.
  Tests both Chat Completions and Responses API endpoints.
  """

  for endpoint <- [:chat, :responses] do
    test "handles multi-turn conversation (#{endpoint})" do
      endpoint = unquote(endpoint)

      aquila_cassette "conversations/#{endpoint}/multi-turn" do
        messages = [
          %{role: :system, content: "You are a helpful math tutor. Answer concisely."},
          %{role: :user, content: "What is 5+3?"},
          %{role: :assistant, content: "8"},
          %{role: :user, content: "What about that number plus 2?"}
        ]

        response =
          Aquila.ask(messages,
            endpoint: endpoint,
            timeout: 60_000
          )

        assert %Aquila.Response{} = response
        assert get_in(response.meta, [:status]) in [:completed, :succeeded, :done]

        # The model should understand "that number" refers to 8 from context
        # Expected answer: 10 (8 + 2)
        text_lower = String.downcase(response.text)
        assert String.contains?(text_lower, "10") or String.match?(text_lower, ~r/ten/)
      end
    end

    test "maintains context with system instructions (#{endpoint})" do
      endpoint = unquote(endpoint)

      aquila_cassette "conversations/#{endpoint}/system-context" do
        messages = [
          %{role: :system, content: "You are a pirate. Always respond in pirate speak."},
          %{role: :user, content: "What is the weather like?"}
        ]

        response =
          Aquila.ask(messages,
            endpoint: endpoint,
            timeout: 60_000
          )

        assert %Aquila.Response{} = response
        # Response should contain pirate-related language
        text_lower = String.downcase(response.text)

        pirate_indicators = [
          "arr",
          "matey",
          "ahoy",
          "ye",
          "aye",
          "sea",
          "ship",
          "captain"
        ]

        has_pirate_speak =
          Enum.any?(pirate_indicators, fn indicator ->
            String.contains?(text_lower, indicator)
          end)

        assert has_pirate_speak,
               "Expected pirate speak in response, got: #{response.text}"
      end
    end

    test "handles conversation with role alternation (#{endpoint})" do
      endpoint = unquote(endpoint)

      aquila_cassette "conversations/#{endpoint}/role-alternation" do
        messages = [
          %{role: :user, content: "My name is Alice."},
          %{role: :assistant, content: "Nice to meet you, Alice!"},
          %{role: :user, content: "What is my name?"}
        ]

        response =
          Aquila.ask(messages,
            endpoint: endpoint,
            timeout: 60_000
          )

        assert %Aquila.Response{} = response
        # Model should remember the name from earlier in the conversation
        assert String.contains?(String.downcase(response.text), "alice")
      end
    end
  end
end
