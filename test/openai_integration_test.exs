defmodule Aquila.OpenAIIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :live

  test "ask returns text" do
    response =
      Aquila.ask("Reply with the word 'pong'.",
        cassette: "integration/pong",
        api_key: System.get_env("OPENAI_API_KEY"),
        timeout: 60_000
      )

    assert %Aquila.Response{} = response
    assert get_in(response.meta, [:status]) in [:completed, :succeeded, :done]
    assert String.match?(String.downcase(response.text), ~r/pong/)
  end
end
