defmodule Aquila.StreamingTest do
  use ExUnit.Case, async: false
  use Aquila.Cassette

  @moduledoc """
  Tests streaming behavior with different sink types.
  Tests both Chat Completions and Responses API endpoints.
  """

  for endpoint <- [:chat, :responses] do
    test "streams with collector sink (#{endpoint})" do
      endpoint = unquote(endpoint)

      aquila_cassette "streaming/#{endpoint}/collector" do
        sink = Aquila.Sink.collector(self())

        {:ok, ref} =
          Aquila.stream(
            "Say hello in exactly 3 words.",
            sink: sink,
            endpoint: endpoint,
            timeout: 60_000
          )

        # Collect chunks
        chunks = collect_chunks(ref, [])

        assert length(chunks) > 0, "Expected to receive at least one chunk"

        # Verify we got text chunks
        assert Enum.any?(chunks, fn
                 {:chunk, text} when is_binary(text) -> true
                 _ -> false
               end)

        # Verify we got a done message
        assert Enum.any?(chunks, fn
                 {:done, text, meta} when is_binary(text) and is_map(meta) -> true
                 _ -> false
               end)
      end
    end

    test "streams with pid sink (#{endpoint})" do
      endpoint = unquote(endpoint)

      aquila_cassette "streaming/#{endpoint}/pid" do
        sink = Aquila.Sink.pid(self())

        {:ok, ref} =
          Aquila.stream(
            "Count from 1 to 3.",
            sink: sink,
            endpoint: endpoint,
            timeout: 60_000
          )

        # Should receive aquila_chunk messages
        assert_receive {:aquila_chunk, chunk, ^ref}, 5_000
        assert is_binary(chunk)

        # Eventually receive done
        assert_receive {:aquila_done, text, meta, ^ref}, 10_000
        assert is_binary(text)
        assert is_map(meta)
        assert meta[:status] in [:completed, :succeeded, :done]

        # Drain remaining messages
        drain_messages(ref)
      end
    end

    test "streams with function sink (#{endpoint})" do
      endpoint = unquote(endpoint)

      aquila_cassette "streaming/#{endpoint}/fun" do
        test_pid = self()

        sink =
          Aquila.Sink.fun(fn event, ref ->
            send(test_pid, {:sink_event, event, ref})
          end)

        {:ok, ref} =
          Aquila.stream(
            "Reply with 'pong'.",
            sink: sink,
            endpoint: endpoint,
            timeout: 60_000
          )

        # Function sink should trigger our callback
        assert_receive {:sink_event, {:chunk, chunk}, ^ref}, 5_000
        assert is_binary(chunk)

        # Collect remaining events
        sink_events = collect_sink_events(ref, [])
        assert length(sink_events) > 0

        # Should have a done event
        assert Enum.any?(sink_events, fn
                 {:done, _, _} -> true
                 _ -> false
               end)
      end
    end

    test "await_stream waits for completion (#{endpoint})" do
      endpoint = unquote(endpoint)

      aquila_cassette "streaming/#{endpoint}/await" do
        sink = Aquila.Sink.collector(self())

        {:ok, ref} =
          Aquila.stream(
            "Say 'test complete'.",
            sink: sink,
            endpoint: endpoint,
            timeout: 60_000
          )

        # Use await_stream to wait for completion
        {:ok, response} = Aquila.await_stream(ref, 60_000)

        assert %Aquila.Response{} = response
        assert is_binary(response.text)
        assert response.text != ""
        assert response.meta[:status] in [:completed, :succeeded, :done]

        # Drain any remaining messages
        drain_messages(ref)
      end
    end
  end

  # Helper to collect chunks from collector sink
  defp collect_chunks(ref, acc) do
    receive do
      {:aquila_chunk, chunk, ^ref} ->
        collect_chunks(ref, [{:chunk, chunk} | acc])

      {:aquila_done, text, meta, ^ref} ->
        Enum.reverse([{:done, text, meta} | acc])

      {:aquila_error, error, ^ref} ->
        Enum.reverse([{:error, error} | acc])
    after
      5_000 -> Enum.reverse(acc)
    end
  end

  # Helper to collect events from function sink
  defp collect_sink_events(ref, acc) do
    receive do
      {:sink_event, event, ^ref} ->
        collect_sink_events(ref, [event | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  # Helper to drain remaining messages
  defp drain_messages(ref) do
    receive do
      {:aquila_chunk, _, ^ref} -> drain_messages(ref)
      {:aquila_done, _, _, ^ref} -> :ok
      {:aquila_error, _, ^ref} -> :ok
      {:aquila_event, _, ^ref} -> drain_messages(ref)
    after
      50 -> :ok
    end
  end
end
