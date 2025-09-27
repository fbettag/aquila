defmodule Aquila.ResponsesRetrievalTest do
  use ExUnit.Case, async: false

  @cassette "responses/retrieve"

  test "stores, retrieves, and deletes a conversation" do
    response =
      Aquila.ask(
        [
          %{role: :user, content: "Say hello and include today's year."}
        ],
        store: true,
        cassette: @cassette,
        instructions: "Keep it short",
        api_key: System.get_env("OPENAI_API_KEY")
      )

    response_id = get_in(response.meta, [:response_id]) || get_in(response.meta, [:id])
    assert is_binary(response_id)
    assert response.text != ""

    {:ok, retrieved} =
      Aquila.retrieve_response(response_id,
        cassette: @cassette,
        api_key: System.get_env("OPENAI_API_KEY")
      )

    assert retrieved.meta[:response_id] == response_id
    assert retrieved.text != ""

    {:ok, deletion} =
      Aquila.delete_response(response_id,
        cassette: @cassette,
        api_key: System.get_env("OPENAI_API_KEY")
      )

    assert Map.get(deletion, "deleted") in [true, false]
    assert Map.get(deletion, "id") == response_id
  end
end
