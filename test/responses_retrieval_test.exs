defmodule Aquila.ResponsesRetrievalTest do
  use ExUnit.Case, async: false
  use Aquila.Cassette

  @cassette "responses/retrieve"

  test "stores, retrieves, and deletes a conversation" do
    response =
      aquila_cassette @cassette do
        Aquila.ask(
          [
            %{role: :user, content: "Say hello and include today's year."}
          ],
          store: true,
          instructions: "Keep it short"
        )
      end

    response_id = get_in(response.meta, [:response_id]) || get_in(response.meta, [:id])
    assert is_binary(response_id)
    assert response.text != ""

    {:ok, retrieved} =
      aquila_cassette @cassette do
        Aquila.retrieve_response(response_id)
      end

    assert retrieved.meta[:response_id] == response_id
    assert retrieved.text != ""

    {:ok, deletion} =
      aquila_cassette @cassette do
        Aquila.delete_response(response_id)
      end

    assert Map.get(deletion, "deleted") in [true, false]
    assert Map.get(deletion, "id") == response_id
  end
end
