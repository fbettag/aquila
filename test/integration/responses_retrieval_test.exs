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

      # Validate response structure (not just != "")
      assert response.text != ""
      assert String.length(response.text) > 10, "Expected substantive response content"
      assert is_binary(response.meta[:model]), "Expected model in metadata"
      assert response.meta[:status] in [:completed, "completed"], "Expected completed status"

      # Validate usage information is present
      usage = response.meta[:usage]
      assert is_map(usage), "Expected usage metadata"

      assert is_integer(usage["total_tokens"]) or is_integer(usage[:total_tokens]),
             "Expected token usage information"

      {:ok, retrieved} =
        Aquila.retrieve_response(response_id)

      # Verify retrieved response preserves all critical fields
      assert retrieved.meta[:response_id] == response_id

      assert retrieved.text == response.text,
             "Retrieved response text should match original"

      # Model may not be preserved in retrieval (API limitation)
      # The API may return versioned model names (e.g., "gpt-4o-mini-2024-07-18" instead of "gpt-4o-mini")
      # We verify they're compatible by checking if one starts with the other
      if not is_nil(retrieved.meta[:model]) and not is_nil(response.meta[:model]) do
        retrieved_model = to_string(retrieved.meta[:model])
        original_model = to_string(response.meta[:model])

        models_compatible =
          String.starts_with?(retrieved_model, original_model) or
            String.starts_with?(original_model, retrieved_model)

        assert models_compatible,
               "Retrieved model (#{retrieved_model}) should be compatible with original (#{original_model})"
      end

      assert retrieved.meta[:status] in [:completed, "completed"],
             "Retrieved status should be completed"

      {:ok, deletion} =
        Aquila.delete_response(response_id)

      # Validate deletion response structure
      assert is_map(deletion), "Expected deletion to return a map"

      assert Map.has_key?(deletion, "deleted") or Map.has_key?(deletion, :deleted),
             "Expected deletion response to have 'deleted' key"

      assert Map.get(deletion, "deleted") == true or Map.get(deletion, :deleted) == true,
             "Expected successful deletion"
    end
  end
end
