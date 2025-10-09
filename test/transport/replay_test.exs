defmodule Aquila.TransportReplayTest do
  use ExUnit.Case, async: false

  alias Aquila.Transport.{Cassette, Replay}

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "aquila-replay-test-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(tmp)

    original = Application.get_env(:aquila, :recorder, [])
    Application.put_env(:aquila, :recorder, Keyword.put(original, :path, tmp))

    Cassette.reset_index(:all)

    on_exit(fn ->
      Application.put_env(:aquila, :recorder, original)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  defp new_cassette do
    "replay-" <> Integer.to_string(System.unique_integer([:positive]))
  end

  test "stream replays tool calls, deduplicates done events, and emits normalized events" do
    cassette = new_cassette()
    request_id = 1

    Cassette.write_meta(cassette, request_id, %{
      "body_hash" => Cassette.canonical_hash(:no_body),
      "method" => "post"
    })

    sse_lines =
      [
        Jason.encode!(%{"request_id" => 999, "type" => "delta", "content" => "skip"}),
        Jason.encode!(%{
          "request_id" => request_id,
          "type" => "tool_call",
          "id" => "call-1",
          "name" => "weather"
        }),
        Jason.encode!(%{
          "request_id" => request_id,
          "type" => "tool_call",
          "tool_call_id" => "call-1",
          "call_id" => "call-1",
          "args_fragment" => "{\"location\":\"NY\""
        }),
        Jason.encode!(%{
          "request_id" => request_id,
          "type" => "tool_call",
          "tool_call_id" => "call-1",
          "call_id" => "call-1",
          "args_fragment" => "}"
        }),
        Jason.encode!(%{
          "request_id" => request_id,
          "type" => "done",
          "status" => "requires_action"
        }),
        Jason.encode!(%{
          "request_id" => request_id,
          "type" => "delta",
          "content" => "partial response"
        }),
        Jason.encode!(%{
          "request_id" => request_id,
          "type" => "message",
          "content" => "final message"
        }),
        Jason.encode!(%{"request_id" => request_id, "type" => "done", "status" => "completed"}),
        Jason.encode!(%{"request_id" => request_id, "type" => "done", "status" => "completed"}),
        Jason.encode!(%{"request_id" => request_id, "type" => "done"}),
        Jason.encode!(%{"request_id" => request_id, "type" => "done", "status" => "done"}),
        Jason.encode!(%{
          "request_id" => request_id,
          "type" => "done",
          "status" => "custom_status"
        }),
        Jason.encode!(%{
          "request_id" => request_id,
          "type" => "usage",
          "usage" => %{"total_tokens" => 42}
        }),
        Jason.encode!(%{"request_id" => request_id, "type" => "response_ref", "id" => "resp_123"}),
        Jason.encode!(%{
          "request_id" => request_id,
          "type" => "event",
          "payload" => %{"custom" => "value"}
        }),
        Jason.encode!(%{
          "request_id" => request_id,
          "type" => "error",
          "error" => %{"message" => "boom"}
        }),
        Jason.encode!(%{
          "request_id" => request_id,
          "type" => "tool_call_end",
          "id" => "external",
          "name" => "external_tool",
          "args" => %{"foo" => "bar"}
        }),
        Jason.encode!(%{
          "request_id" => request_id,
          "type" => "tool_call",
          "id" => "call-2",
          "name" => "followup"
        }),
        Jason.encode!(%{
          "request_id" => request_id,
          "type" => "tool_call",
          "tool_call_id" => "call-2",
          "call_id" => "call-2",
          "args_fragment" => "{\"result\":\"ok\"}"
        }),
        Jason.encode!(%{
          "request_id" => request_id,
          "type" => "done",
          "status" => "requires_action"
        })
      ]

    Cassette.sse_path(cassette)
    |> File.write!(Enum.join(sse_lines, "\n") <> "\n")

    {:ok, agent} = Agent.start_link(fn -> [] end)

    on_exit(fn ->
      if Process.alive?(agent) do
        Agent.stop(agent)
      end
    end)

    req = %{body: nil, opts: [cassette: cassette, cassette_index: request_id]}

    assert {:ok, ref} =
             Replay.stream(req, fn event ->
               Agent.update(agent, &(&1 ++ [event]))
             end)

    assert is_reference(ref)

    events = Agent.get(agent, & &1)

    assert events == [
             %{type: :tool_call, id: "call-1", name: "weather", args_fragment: nil, call_id: nil},
             %{
               type: :tool_call,
               id: "call-1",
               name: nil,
               args_fragment: "{\"location\":\"NY\"",
               call_id: "call-1"
             },
             %{type: :tool_call, id: "call-1", name: nil, args_fragment: "}", call_id: "call-1"},
             %{
               type: :tool_call_end,
               id: "call-1",
               name: "weather",
               args: %{"location" => "NY"},
               call_id: "call-1"
             },
             %{type: :done, status: :requires_action, meta: %{}},
             %{type: :delta, content: "partial response"},
             %{type: :message, content: "final message"},
             %{type: :done, status: :completed, meta: %{}},
             %{type: :done, status: :completed, meta: %{}},
             %{type: :done, status: :done, meta: %{}},
             %{type: :done, status: :custom_status, meta: %{}},
             %{type: :usage, usage: %{"total_tokens" => 42}},
             %{type: :response_ref, id: "resp_123"},
             %{type: :event, payload: %{"payload" => %{"custom" => "value"}, "request_id" => 1}},
             %{type: :error, error: %{"message" => "boom"}},
             %{
               type: :tool_call_end,
               id: "external",
               name: "external_tool",
               args: %{"foo" => "bar"},
               call_id: nil
             },
             %{
               type: :tool_call,
               id: "call-2",
               name: "followup",
               args_fragment: nil,
               call_id: nil
             },
             %{
               type: :tool_call,
               id: "call-2",
               name: nil,
               args_fragment: "{\"result\":\"ok\"}",
               call_id: "call-2"
             },
             %{
               type: :tool_call_end,
               id: "call-2",
               name: "followup",
               args: %{"result" => "ok"},
               call_id: "call-2"
             },
             %{type: :done, status: :requires_action, meta: %{}}
           ]
  end

  test "stream returns missing cassette error when none configured" do
    assert {:error, :missing_cassette} = Replay.stream(%{body: nil, opts: []}, fn _ -> :ok end)
  end

  test "post returns decoded response when metadata matches" do
    cassette = new_cassette()
    request_id = 2
    body = Jason.encode!(%{"messages" => [%{"role" => "user", "content" => "ping"}]})

    Cassette.write_meta(cassette, request_id, %{
      "body_hash" => Cassette.canonical_hash(body),
      "method" => "post"
    })

    Cassette.post_path(cassette, request_id)
    |> File.write!(Jason.encode!(%{"ok" => true}))

    req = %{body: body, opts: [cassette: cassette, cassette_index: request_id]}

    assert {:ok, %{"ok" => true}} = Replay.post(req)
  end

  test "post raises when request body hash differs from cassette metadata" do
    cassette = new_cassette()
    request_id = 3

    Cassette.write_meta(cassette, request_id, %{
      "body_hash" => Cassette.canonical_hash("different"),
      "method" => "post"
    })

    Cassette.post_path(cassette, request_id)
    |> File.write!(Jason.encode!(%{"ok" => false}))

    req = %{
      body: Jason.encode!(%{"messages" => []}),
      opts: [cassette: cassette, cassette_index: request_id]
    }

    assert_raise RuntimeError, ~r/Cassette prompt mismatch/, fn ->
      Replay.post(req)
    end
  end

  test "get raises when cassette stored a different HTTP method" do
    cassette = new_cassette()
    request_id = 4

    Cassette.write_meta(cassette, request_id, %{
      "body_hash" => Cassette.canonical_hash(:no_body),
      "method" => "post"
    })

    Cassette.post_path(cassette, request_id)
    |> File.write!(Jason.encode!(%{"ok" => true}))

    req = %{body: nil, opts: [cassette: cassette, cassette_index: request_id]}

    assert_raise RuntimeError, ~r/Cassette method mismatch/, fn ->
      Replay.get(req)
    end
  end

  test "delete raises when cassette metadata lacks non-post support" do
    cassette = new_cassette()
    request_id = 5

    Cassette.write_meta(cassette, request_id, %{
      "body_hash" => Cassette.canonical_hash(:no_body),
      "method" => nil
    })

    Cassette.post_path(cassette, request_id)
    |> File.write!(Jason.encode!(%{"ok" => true}))

    req = %{body: nil, opts: [cassette: cassette, cassette_index: request_id]}

    assert_raise RuntimeError, ~r/Cassette method mismatch/, fn ->
      Replay.delete(req)
    end
  end

  test "post returns missing cassette error when cassette option is absent" do
    assert {:error, :missing_cassette} = Replay.post(%{body: nil, opts: []})
  end

  test "post raises when metadata file is missing" do
    cassette = new_cassette()
    request_id = 6

    Cassette.post_path(cassette, request_id)
    |> File.write!(Jason.encode!(%{"ok" => true}))

    req = %{
      body: Jason.encode!(%{"messages" => []}),
      opts: [cassette: cassette, cassette_index: request_id]
    }

    assert_raise RuntimeError, ~r/Cassette metadata missing/, fn ->
      Replay.post(req)
    end
  end

  test "post tolerates hash drift when bodies match" do
    cassette = new_cassette()
    request_id = 7

    recorded_body = %{
      "messages" => [%{"role" => "user", "content" => "ping"}],
      "model" => "gpt-4o-mini"
    }

    Cassette.write_meta(cassette, request_id, %{
      "body" => recorded_body,
      "body_hash" => "not-the-real-hash",
      "method" => "post"
    })

    Cassette.post_path(cassette, request_id)
    |> File.write!(Jason.encode!(%{"ok" => true}))

    req = %{
      body: %{messages: [%{role: "user", content: "ping"}], model: "gpt-4o-mini"},
      opts: [cassette: cassette, cassette_index: request_id]
    }

    assert {:ok, %{"ok" => true}} = Replay.post(req)
  end
end
