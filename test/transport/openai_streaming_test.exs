defmodule Aquila.OpenAITransportStreamingTest do
  use ExUnit.Case, async: false

  alias Aquila.Transport.OpenAI

  setup_all do
    Application.ensure_all_started(:plug_cowboy)
    :ok
  end

  @done_event "data: [DONE]\n\n"

  defmodule SSEPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, _body, conn} = read_body(conn)

      case Keyword.fetch(opts, :events) do
        {:ok, events} ->
          stream(conn, events, Keyword.get(opts, :status, 200), Keyword.get(opts, :pause, 0))

        :error ->
          status = Keyword.get(opts, :status, 401)
          body = Keyword.get(opts, :body, ~s({"error":"unauthorized"}))

          conn
          |> put_resp_header("content-type", "application/json")
          |> send_resp(status, body)
      end
    end

    defp stream(conn, events, status, pause) do
      conn =
        conn
        |> put_resp_header("content-type", "text/event-stream")
        |> send_chunked(status)

      Enum.reduce(events, conn, fn chunk, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, chunk)
        if pause > 0, do: Process.sleep(pause)
        conn
      end)
    end
  end

  defp start_server(opts) do
    ref = Keyword.get(opts, :ref, unique_ref())
    plug_opts = Keyword.drop(opts, [:ref, :port])
    cowboy_opts = [ref: ref, port: Keyword.get(opts, :port, 0)]

    child_spec =
      Plug.Cowboy.child_spec(
        scheme: :http,
        plug: {SSEPlug, plug_opts},
        options: cowboy_opts
      )

    _pid = start_supervised!(child_spec)
    port = :ranch.get_port(ref)
    port
  end

  defp unique_ref do
    ("aquila_stream_test_" <> Integer.to_string(System.unique_integer([:positive])))
    |> String.to_atom()
  end

  defp collect_events(fun) do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent, :normal) end)

    callback = fn event -> Agent.update(agent, &[event | &1]) end
    assert {:ok, _ref} = fun.(callback)
    Agent.get(agent, &Enum.reverse/1)
  end

  defp run_stream(events, req_overrides \\ %{}) do
    port = start_server(events: events)
    req = request_for(port) |> Map.merge(req_overrides)
    collect_events(fn callback -> OpenAI.stream(req, callback) end)
  end

  defp sse_event(map), do: "data: #{Jason.encode!(map)}\n\n"

  defp request_for(port) do
    %{
      endpoint: :responses,
      url: "http://127.0.0.1:#{port}",
      headers: [],
      body: %{},
      opts: []
    }
  end

  test "stream normalizes response events" do
    events = [
      sse_event(%{"type" => "response.created", "response" => %{"id" => "resp_123"}}),
      sse_event(%{"type" => "response.output_text.delta", "delta" => "Hello"}),
      @done_event
    ]

    port = start_server(events: events)
    req = request_for(port)

    events = collect_events(fn callback -> OpenAI.stream(req, callback) end)

    assert [
             %{type: :response_ref, id: "resp_123"},
             %{type: :delta, content: "Hello"},
             %{type: :done, status: :completed}
           ] = events
  end

  test "stream emits done when upstream omits [DONE] marker" do
    events = [
      "data: {\"type\": \"response.output_text.delta\", \"delta\": \"Ping\"}\n\n"
    ]

    port = start_server(events: events)
    req = request_for(port)

    events = collect_events(fn callback -> OpenAI.stream(req, callback) end)

    assert [%{type: :delta, content: "Ping"}, %{type: :done, status: :completed}] = events
  end

  test "stream surfaces http errors" do
    body = ~s({"error":{"message":"bad token"}})
    port = start_server(status: 401, body: body)
    req = request_for(port)

    assert {:error, {:http_error, 401, ^body}} = OpenAI.stream(req, fn _ -> :ok end)
  end

  test "stream ignores blank sse events" do
    events = ["\n\n", @done_event]

    port = start_server(events: events)
    req = request_for(port)

    events = collect_events(fn callback -> OpenAI.stream(req, callback) end)

    assert [%{type: :done, status: :completed}] = events
  end

  test "stream ignores comment events" do
    events = [": keep-alive\n\n", @done_event]

    port = start_server(events: events)
    req = request_for(port)

    events = collect_events(fn callback -> OpenAI.stream(req, callback) end)

    assert [%{type: :done, status: :completed}] = events
  end

  test "stream emits tool call fragments" do
    events = [
      sse_event(%{
        "type" => "response.function_call_arguments.delta",
        "delta" => "{\"foo\":",
        "call_id" => "call_1",
        "function_call" => %{"name" => "fn_tool"}
      }),
      sse_event(%{
        "type" => "response.function_call_arguments.done",
        "arguments" => "{\"foo\":1}",
        "call_id" => "call_1",
        "function_call" => %{"name" => "fn_tool"}
      }),
      @done_event
    ]

    events = run_stream(events)

    assert [
             %{
               type: :tool_call,
               id: "call_1",
               name: "fn_tool",
               args_fragment: "{\"foo\":",
               call_id: "call_1"
             },
             %{
               type: :tool_call_end,
               id: "call_1",
               name: "fn_tool",
               args: %{"foo" => 1},
               call_id: "call_1"
             },
             %{type: :done, status: :completed}
           ] = events
  end

  test "stream emits builtin tool events" do
    events = [
      sse_event(%{
        "type" => "response.tool_call.output_json.delta",
        "call_id" => "builtin_1",
        "tool_call" => %{"id" => "builtin_1"},
        "delta" => %{"answer" => "42"}
      }),
      @done_event
    ]

    events = run_stream(events)

    assert [%{type: :event, payload: payload}, %{type: :done, status: :completed}] = events
    assert payload.source == :builtin_tool
    assert payload.stage == "delta"
    assert payload.call_id == "builtin_1"
    assert payload.delta == %{"answer" => "42"}
  end

  test "stream emits deep research events" do
    events = [
      sse_event(%{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => %{"id" => "rs_1", "type" => "reasoning", "summary" => []},
        "sequence_number" => 1
      }),
      @done_event
    ]

    events = run_stream(events)

    assert [
             %{type: :event, payload: payload},
             %{type: :done, status: :completed}
           ] = events

    assert payload.source == :deep_research
    assert payload.event == :output_item_added
    assert payload.data[:output_index] == 0
    item = payload.data[:item] || %{}
    assert (Map.get(item, :type) || Map.get(item, "type")) == "reasoning"
  end

  test "stream accumulates raw error body" do
    events = ["partial body\n\n"]

    port = start_server(events: events, status: 500)
    req = request_for(port)

    assert {:error, {:http_error, 500, "partial body"}} = OpenAI.stream(req, fn _ -> :ok end)
  end

  test "stream surfaces response.completed metadata" do
    events = [
      sse_event(%{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_meta",
          "status" => "completed",
          "usage" => %{"output_tokens" => 3},
          "metadata" => %{"foo" => "bar"},
          "output" => [
            %{
              "type" => "message",
              "content" => [
                %{"type" => "output_text", "text" => "Hi"},
                %{
                  "type" => "tool_call_delta",
                  "call_id" => "tool_a",
                  "tool_call" => %{
                    "function" => %{"name" => "calc", "arguments" => "{\"x\":1}"}
                  }
                },
                %{
                  "type" => "tool_call",
                  "call_id" => "tool_a",
                  "tool_call" => %{
                    "function" => %{"name" => "calc", "arguments" => "{\"x\":1}"}
                  }
                }
              ]
            }
          ]
        }
      })
    ]

    events = run_stream(events)

    assert [
             %{type: :delta, content: "Hi"},
             %{
               type: :tool_call,
               id: "tool_a",
               name: "calc",
               args_fragment: "{\"x\":1}",
               call_id: "tool_a"
             },
             %{
               type: :tool_call_end,
               id: "tool_a",
               name: "calc",
               args: %{"x" => 1},
               call_id: "tool_a"
             },
             %{type: :done, status: :completed, meta: meta}
           ] = events

    assert meta[:id] == "resp_meta"
    assert meta[:usage] == %{"output_tokens" => 3}
    assert meta[:metadata] == %{"foo" => "bar"}
    assert meta[:_fallback_text] == "Hi"
  end

  test "stream returns transport errors" do
    req = %{
      endpoint: :responses,
      url: "http://127.0.0.1:1",
      headers: [],
      body: %{},
      opts: []
    }

    assert {:error, %Req.TransportError{}} = OpenAI.stream(req, fn _ -> :ok end)
  end

  test "stream handles output_text done events" do
    events = [sse_event(%{"type" => "response.output_text.done"}), @done_event]

    assert [%{type: :done, status: :completed}] = run_stream(events)
  end

  test "stream ignores unknown response types" do
    events = [sse_event(%{"type" => "response.unknown"}), @done_event]

    assert [%{type: :done, status: :completed}] = run_stream(events)
  end

  test "stream returns requires_action status" do
    events = [
      sse_event(%{
        "type" => "response.requires_action",
        "response" => %{"type" => "submit_tool_outputs"}
      })
    ]

    events = run_stream(events)

    assert [
             %{
               type: :done,
               status: :requires_action,
               meta: %{"response" => %{"type" => "submit_tool_outputs"}}
             }
           ] = events
  end

  test "chat stream normalizes deltas and usage" do
    payload = %{
      "id" => "chat_1",
      "model" => "gpt-test",
      "usage" => %{"prompt_tokens" => 5},
      "choices" => [
        %{
          "delta" => %{"content" => "Hi"},
          "finish_reason" => "stop"
        }
      ]
    }

    events = run_stream([sse_event(payload)], %{endpoint: :chat})

    assert [
             %{type: :delta, content: "Hi"},
             %{type: :done, status: :completed, meta: meta},
             %{type: :usage, usage: %{"prompt_tokens" => 5}}
           ] = events

    assert meta[:id] == "chat_1"
    assert meta[:model] == "gpt-test"
  end

  test "chat stream emits tool call events" do
    payload = %{
      "id" => "chat_tool",
      "model" => "gpt-test",
      "choices" => [
        %{
          "delta" => %{
            "tool_calls" => [
              %{
                "id" => "call_1",
                "function" => %{"name" => "search", "arguments" => "{\"q\":\"hi\"}"}
              }
            ]
          },
          "finish_reason" => "tool_calls"
        }
      ]
    }

    events = run_stream([sse_event(payload)], %{endpoint: :chat})

    assert [
             %{
               type: :tool_call,
               id: "call_1",
               name: "search",
               args_fragment: "{\"q\":\"hi\"}",
               call_id: "call_1"
             },
             %{
               type: :tool_call_end,
               id: "call_1",
               name: "search",
               args: %{"q" => "hi"},
               call_id: "call_1"
             },
             %{
               type: :done,
               status: :requires_action,
               meta: %{reason: "tool_calls", id: "chat_tool", model: "gpt-test"}
             }
           ] = events
  end

  test "chat stream accumulates tool call fragments across events" do
    first_chunk = %{
      "id" => "chat_multi",
      "model" => "gpt-test",
      "choices" => [
        %{
          "delta" => %{
            "tool_calls" => [
              %{
                "id" => "call_frag",
                "index" => 0,
                "function" => %{"name" => "multi", "arguments" => "{\"foo\":\""}
              }
            ]
          },
          "finish_reason" => nil
        }
      ]
    }

    second_chunk = %{
      "id" => "chat_multi",
      "model" => "gpt-test",
      "choices" => [
        %{
          "delta" => %{
            "tool_calls" => [
              %{
                "index" => 0,
                "function" => %{"arguments" => "bar\"}"}
              }
            ]
          },
          "finish_reason" => "tool_calls"
        }
      ]
    }

    events =
      run_stream([sse_event(first_chunk), sse_event(second_chunk)], %{endpoint: :chat})

    assert [
             %{
               type: :tool_call,
               id: "call_frag",
               name: "multi",
               args_fragment: "{\"foo\":\"",
               call_id: "call_frag"
             },
             %{
               type: :tool_call,
               id: nil,
               name: nil,
               args_fragment: "bar\"}",
               call_id: "call_frag"
             },
             %{
               type: :tool_call_end,
               id: "call_frag",
               name: "multi",
               args: %{"foo" => "bar"},
               call_id: "call_frag"
             },
             %{
               type: :done,
               status: :requires_action,
               meta: %{id: "chat_multi", model: "gpt-test", reason: "tool_calls"}
             }
           ] = events
  end

  test "chat stream falls back to empty args when fragments decode fails" do
    payload = %{
      "id" => "chat_bad_json",
      "model" => "gpt-test",
      "choices" => [
        %{
          "delta" => %{
            "tool_calls" => [
              %{
                "id" => "call_bad",
                "index" => 0,
                "function" => %{"name" => "multi", "arguments" => "{invalid"}
              }
            ]
          },
          "finish_reason" => "tool_calls"
        }
      ]
    }

    events = run_stream([sse_event(payload)], %{endpoint: :chat})

    assert [
             %{
               type: :tool_call,
               id: "call_bad",
               name: "multi",
               args_fragment: "{invalid",
               call_id: "call_bad"
             },
             %{
               type: :tool_call_end,
               id: "call_bad",
               name: "multi",
               args: %{},
               call_id: "call_bad"
             },
             %{
               type: :done,
               status: :requires_action,
               meta: %{id: "chat_bad_json", model: "gpt-test", reason: "tool_calls"}
             }
           ] = events
  end

  test "stream emits usage delta events" do
    events = [
      sse_event(%{"type" => "response.usage.delta", "usage" => %{"prompt_tokens" => 2}}),
      @done_event
    ]

    events = run_stream(events)

    assert [%{type: :usage, usage: %{"prompt_tokens" => 2}}, %{type: :done, status: :completed}] =
             events
  end

  test "stream emits output_text chunk events" do
    events = [
      sse_event(%{"type" => "response.output_text.chunk", "text" => "chunk"}),
      @done_event
    ]

    events = run_stream(events)

    assert [%{type: :delta, content: "chunk"}, %{type: :done, status: :completed}] = events
  end

  test "stream surfaces response.error events" do
    events = [sse_event(%{"type" => "response.error", "error" => %{"message" => "nope"}})]

    events = run_stream(events)

    assert [%{type: :error, error: %{"message" => "nope"}}, %{type: :done, status: :completed}] =
             events
  end

  test "stream captures builtin tool message deltas" do
    events = [
      sse_event(%{
        "type" => "response.completed",
        "response" => %{
          "output" => [
            %{
              "type" => "message",
              "content" => [
                %{
                  "type" => "tool_call_delta",
                  "call_id" => "builtin",
                  "tool_call" => %{"type" => "builtin"}
                },
                %{
                  "type" => "tool_call",
                  "call_id" => "builtin",
                  "tool_call" => %{"type" => "builtin"}
                }
              ]
            }
          ]
        }
      })
    ]

    events = run_stream(events)

    assert [
             %{type: :event, payload: %{source: :builtin_tool, stage: "delta"}},
             %{type: :event, payload: %{stage: "complete"}},
             %{type: :done, status: :completed}
           ] = events
  end

  test "stream ignores unknown message content" do
    events = [
      sse_event(%{
        "type" => "response.completed",
        "response" => %{
          "output" => [%{"type" => "message", "content" => [%{"type" => "unknown"}]}]
        }
      })
    ]

    assert [%{type: :done, status: :completed}] = run_stream(events)
  end

  test "chat stream handles nil finish reason" do
    payload = %{
      "id" => "chat_nil",
      "model" => "gpt-test",
      "choices" => [%{"delta" => %{}, "finish_reason" => nil}]
    }

    assert [%{type: :done, status: :completed}] =
             run_stream([sse_event(payload)], %{endpoint: :chat})
  end

  test "chat stream emits event for other finish reasons" do
    payload = %{
      "id" => "chat_other",
      "model" => "gpt-test",
      "choices" => [%{"delta" => %{}, "finish_reason" => "length"}]
    }

    assert [
             %{type: :event, payload: %{finish_reason: "length"}},
             %{type: :done, status: :completed}
           ] = run_stream([sse_event(payload)], %{endpoint: :chat})
  end

  test "chat stream emits tool call without completion" do
    payload = %{
      "choices" => [
        %{
          "delta" => %{
            "tool_calls" => [
              %{
                "id" => "search",
                "index" => 0,
                "function" => %{"name" => "search", "arguments" => nil}
              }
            ]
          },
          "finish_reason" => "stop"
        }
      ]
    }

    assert [
             %{type: :tool_call, name: "search", args_fragment: nil, call_id: "search"},
             %{type: :done, status: :completed}
           ] = run_stream([sse_event(payload)], %{endpoint: :chat})
  end

  test "response function call done decodes nil arguments" do
    events = [
      sse_event(%{
        "type" => "response.function_call_arguments.done",
        "call_id" => "call_nil",
        "function_call" => %{"name" => "fn"},
        "arguments" => nil
      }),
      @done_event
    ]

    assert [
             %{type: :tool_call_end, id: "call_nil", args: nil, call_id: "call_nil"},
             %{type: :done, status: :completed}
           ] = run_stream(events)
  end

  test "response function call done captures invalid json" do
    events = [
      sse_event(%{
        "type" => "response.function_call_arguments.done",
        "call_id" => "call_bad",
        "function_call" => %{"name" => "fn"},
        "arguments" => "not json"
      }),
      @done_event
    ]

    assert [
             %{
               type: :tool_call_end,
               id: "call_bad",
               args: %{"raw" => "not json"},
               call_id: "call_bad"
             },
             %{type: :done, status: :completed}
           ] = run_stream(events)
  end

  test "stream surfaces decode errors" do
    events = ["data: {invalid}\n\n"]

    port = start_server(events: events)
    req = request_for(port)

    events = collect_events(fn callback -> OpenAI.stream(req, callback) end)

    assert [%{type: :error, error: %Jason.DecodeError{}}, %{type: :done, status: :completed}] =
             events
  end

  test "chat stream surfaces decode errors" do
    events = ["data: {invalid}\n\n"]

    port = start_server(events: events)
    req = request_for(port) |> Map.put(:endpoint, :chat)

    events = collect_events(fn callback -> OpenAI.stream(req, callback) end)

    assert [
             %{type: :error, error: %Jason.DecodeError{}},
             %{type: :done, status: :completed}
           ] = events
  end

  test "post returns ok tuple" do
    body = ~s({"result":"ok"})
    port = start_server(status: 200, body: body)

    req = %{
      url: "http://127.0.0.1:#{port}",
      headers: [],
      body: %{hello: "world"},
      opts: [],
      endpoint: :responses
    }

    assert {:ok, %{"result" => "ok"}} = OpenAI.post(req)
  end

  test "post returns http error" do
    body = ~s({"error":"nope"})
    port = start_server(status: 422, body: body)

    req = %{
      url: "http://127.0.0.1:#{port}",
      headers: [],
      body: %{foo: :bar},
      opts: [],
      endpoint: :responses
    }

    assert {:error, {:http_error, 422, %{"error" => "nope"}}} = OpenAI.post(req)
  end

  test "post applies default opts" do
    body = ~s({"ack":true})
    port = start_server(status: 200, body: body)

    req = %{
      endpoint: :responses,
      url: "http://127.0.0.1:#{port}",
      headers: [],
      body: nil,
      opts: nil
    }

    assert {:ok, %{"ack" => true}} = OpenAI.post(req)
  end

  test "post returns transport error" do
    req = %{
      url: "http://127.0.0.1:1",
      headers: [],
      body: %{},
      opts: [],
      endpoint: :responses
    }

    assert {:error, %Req.TransportError{}} = OpenAI.post(req)
  end
end
