defmodule Aquila.ResponsesRetrievalTest do
  use ExUnit.Case, async: false
  use Aquila.Cassette

  test "stores, retrieves, and deletes a conversation" do
    aquila_cassette "responses/store-retrieve-delete" do
      response =
        Aquila.ask(
          [
            %{role: :user, content: "Say hello and include today's year."}
          ],
          endpoint: :responses,
          store: true,
          instructions: "Keep it short"
        )

      response_id = get_in(response.meta, [:response_id]) || get_in(response.meta, [:id])
      assert is_binary(response_id)
      assert response.text != ""

      {:ok, retrieved} =
        Aquila.retrieve_response(response_id)

      assert retrieved.meta[:response_id] == response_id
      assert retrieved.text != ""

      {:ok, deletion} =
        Aquila.delete_response(response_id)

      assert Map.get(deletion, "deleted") in [true, false]
      assert Map.get(deletion, "deleted") == true
    end
  end
end
