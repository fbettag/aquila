defmodule Aquila.OpenAITransportLiveTest do
  use ExUnit.Case, async: false
  use Aquila.Cassette

  for endpoint <- [:chat, :responses] do
    test "direct transport completes (#{endpoint})" do
      endpoint = unquote(endpoint)

      response =
        aquila_cassette "integration/#{endpoint}/direct-coverage" do
          Aquila.ask("Reply with the word coverage.",
            timeout: 60_000,
            endpoint: endpoint
          )
        end

      assert String.contains?(String.downcase(response.text), "coverage")
    end
  end
end
