defmodule Aquila.OpenAIIntegrationTest do
  use ExUnit.Case, async: false
  use Aquila.Cassette

  test "ask returns text" do
    response =
      aquila_cassette "integration/pong" do
        Aquila.ask("Reply with the word 'pong'.",
          timeout: 60_000
        )
      end

    assert %Aquila.Response{} = response
    assert get_in(response.meta, [:status]) in [:completed, :succeeded, :done]
    assert String.match?(String.downcase(response.text), ~r/pong/)
  end
end
