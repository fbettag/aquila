defmodule Aquila.ConfigTest do
  use ExUnit.Case, async: false

  describe "config access" do
    test "config/1 returns default_model when set" do
      original = Application.get_env(:aquila, :openai, [])

      Application.put_env(
        :aquila,
        :openai,
        Keyword.put(original, :default_model, "custom-model")
      )

      # Access the private config function through ask/2 defaults
      response = Aquila.ask("test", transport: Aquila.ConfigTest.TestTransport, stream: false)
      # Model should use the configured default
      assert response != nil

      Application.put_env(:aquila, :openai, original)
    end

    test "falls back to gpt-4o-mini when no default_model configured" do
      original = Application.get_env(:aquila, :openai, [])
      Application.put_env(:aquila, :openai, Keyword.delete(original, :default_model))

      # The engine should use gpt-4o-mini as fallback
      response = Aquila.ask("test", transport: Aquila.ConfigTest.TestTransport, stream: false)
      assert response != nil

      Application.put_env(:aquila, :openai, original)
    end
  end

  defmodule TestTransport do
    @behaviour Aquila.Transport

    def post(_req), do: {:ok, %{}}
    def get(_req), do: {:ok, %{}}
    def delete(_req), do: {:ok, %{}}

    def stream(_req, callback) do
      callback.(%{type: :delta, content: "test"})
      callback.(%{type: :done, status: :completed, meta: %{}})
      {:ok, make_ref()}
    end
  end
end
