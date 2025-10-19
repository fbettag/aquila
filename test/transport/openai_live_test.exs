defmodule Aquila.OpenAITransportLiveTest do
  use ExUnit.Case, async: false
  use Aquila.Cassette

  test "direct transport completes", _ do
    response =
      aquila_cassette "integration/direct-coverage" do
        Aquila.ask("Reply with the word coverage.",
          timeout: 60_000
        )
      end

    assert String.contains?(String.downcase(response.text), "coverage")
  end
end
