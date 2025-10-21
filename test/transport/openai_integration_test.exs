defmodule Aquila.OpenAIIntegrationTest do
  use ExUnit.Case, async: false
  use Aquila.Cassette

  for endpoint <- [:chat, :responses] do
    test "ask returns text (#{endpoint})" do
      endpoint = unquote(endpoint)

      response =
        aquila_cassette "integration/#{endpoint}/pong" do
          Aquila.ask("Reply with the word 'pong'.",
            timeout: 60_000,
            endpoint: endpoint
          )
        end

      assert %Aquila.Response{} = response
      assert get_in(response.meta, [:status]) in [:completed, :succeeded, :done]
      assert String.match?(String.downcase(response.text), ~r/pong/)
    end
  end
end
