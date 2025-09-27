defmodule Aquila do
  @moduledoc """
  Developer-facing entry point for issuing model requests and receiving
  responses either synchronously or via streams.

  `Aquila` keeps a single, predictable mental model across the Responses API
  (preferred) and Chat Completions fallback. Regardless of endpoint, the
  orchestration layer:

  * Normalises prompts into `Aquila.Message` structs.
  * Streams chunks through sinks so UI layers can update incrementally.
  * Executes declared tools, feeding their output back to the model.
  * Enforces cassette prompt integrity, failing fast when prompts drift.

  Common options shared by the functions in this module:

  * `:instruction` / `:instructions` – system prompt used when the input is
    a bare prompt rather than a message list.
  * `:model` – string or atom supported by the configured transport.
  * `:tools` – list of `Aquila.Tool.t()` structs describing callable functions.
  * `:sink` – `Aquila.Sink.t()` implementation used for streaming callbacks.
  * `:previous_response_id` – continue a Responses API conversation with a
    new instruction set (switch personas mid-thread).
  * `:cassette` – instruct the recorder transport which cassette to use.
  * `:store` – persist Responses API output on OpenAI’s servers when `true`.

  See the guides shipped with the project—especially *Getting Started*,
  *Streaming and Sinks*, *LiveView Integration*, *Oban Integration*, and
  *Cassette Recording & Testing*—for walkthroughs that expand on these concepts
  and show how to integrate with UI processes or background job systems using
  their native APIs.
  """

  alias Aquila.Engine
  alias Aquila.Response

  @typedoc "Supported prompt shapes for `ask/2` and `stream/2`."
  @type prompt :: iodata() | [Aquila.Message.t()]
  @typedoc "Shared option keyword list for public API functions."
  @type options :: keyword()

  @doc """
  Executes the request and waits for a complete `%Aquila.Response{}`.

  The engine still performs a streaming call under the hood, ensuring that
  telemetry and cassette recording behave the same as in explicit streaming
  workflows.

  ## Options

  The most common options include:

  * `:instruction` / `:instructions` – prepend a system prompt when passing
    a plain string.
  * `:model` – overrides the configured default model.
  * `:tools` – enable tool/function calling.
  * `:previous_response_id` – reuse prior context while changing
    instructions for the Responses API.
  * `:metadata` – attach custom metadata that transports may log.
  * `:cassette` – name of the cassette used by the recorder transport.
  * `:store` – set to `true` to persist Responses output server-side.

  ## Examples

      iex> response =
      ...>   Aquila.ask("Explain supervision trees",
      ...>     instruction: "You are a concise tutor.",
      ...>     cassette: "tutorials/supervision"
      ...>   )
      iex> String.contains?(response.text, "Supervision")
      true
  """
  @spec ask(prompt(), options()) :: Response.t()
  def ask(input, opts \\ []) do
    Engine.run(input, Keyword.put_new(opts, :stream, false))
  end

  @doc """
  Initiates a streaming request and returns the monitor reference.

  Unless a custom sink is supplied, `Aquila.Sink.pid/2` targets the calling
  process and emits tuples such as `{:aquila_chunk, chunk, ref}`. See the
  "Streaming and Sinks" guide for message formats and integration patterns.

  ## Options

  Accepts the same options as `ask/2`, plus:

  * `:sink` – sink implementation (defaults to the caller).
  * `:ref` – override the monitor reference reported with events.

  ## Examples

      {:ok, ref} =
        Aquila.stream("Summarise the BEAM",
          instructions: "Keep it to two sentences.",
          previous_response_id: "resp_123",
          sink: Aquila.Sink.pid(self())
        )
      true = is_reference(ref)
  """
  @spec stream(prompt(), options()) :: {:ok, reference()} | {:error, term()}
  def stream(input, opts \\ []) do
    Engine.run(input, Keyword.put(opts, :stream, true))
  end

  @doc """
  Retrieves a stored Responses API conversation by `response_id`.

  Returns `{:ok, %Aquila.Response{}}` when the conversation exists and the
  calling transport succeeds. The function preserves the full JSON payload in
  the response struct so callers can inspect provider-specific fields beyond
  the aggregated text.

  ## Options

  Shares the configuration knobs used by `ask/2`, including:

  * `:api_key` – overrides the configured OpenAI API key.
  * `:base_url` – target a non-default OpenAI-compatible endpoint.
  * `:transport` – swap the HTTP transport (e.g. `Aquila.Transport.Record`).
  * `:cassette` / `:cassette_index` – enable recorder fixtures.
  * `:receive_timeout` / `:timeout` – customise request timeouts.

  ## Examples

      iex> {:ok, response} = Aquila.retrieve_response("resp_123", cassette: "tutorials/store")
      iex> response.meta[:response_id]
      "resp_123"
  """
  @spec retrieve_response(String.t(), options()) :: {:ok, Response.t()} | {:error, term()}
  def retrieve_response(response_id, opts \\ []) when is_binary(response_id) do
    with {:ok, body} <- dispatch_http(:get, response_id, opts) do
      {:ok, response_from_body(body)}
    end
  end

  @doc """
  Deletes a stored Responses API conversation.

  The OpenAI Responses endpoint returns a confirmation payload that includes
  the deleted identifier and a boolean flag. That map is relayed verbatim for
  callers that need to perform their own bookkeeping.

  ## Examples

      iex> {:ok, %{"deleted" => true}} = Aquila.delete_response("resp_123")
  """
  @spec delete_response(String.t(), options()) :: {:ok, map()} | {:error, term()}
  def delete_response(response_id, opts \\ []) when is_binary(response_id) do
    dispatch_http(:delete, response_id, opts)
  end

  defp dispatch_http(method, response_id, opts) do
    transport =
      Keyword.get(opts, :transport) ||
        Application.get_env(:aquila, :transport, Aquila.Transport.OpenAI)

    base_url = Keyword.get(opts, :base_url) || config(:base_url) || "https://api.openai.com/v1"
    api_key = resolve_api_key(Keyword.get(opts, :api_key) || config(:api_key))
    headers = build_headers(api_key)
    opts = Keyword.put_new(opts, :endpoint, :responses)
    req_opts = http_opts(opts)

    request = %{
      endpoint: :responses,
      url: build_responses_url(base_url, response_id),
      headers: headers,
      opts: req_opts
    }

    case method do
      :get -> transport.get(request)
      :delete -> transport.delete(request)
    end
  end

  defp response_from_body(body) when is_map(body) do
    text = collect_output_text(body)

    meta =
      %{}
      |> put_if(body, :id, :id)
      |> put_if(body, :id, :response_id)
      |> put_if(body, :status, :status)
      |> put_if(body, :model, :model)
      |> put_if(body, :created, :created)
      |> put_if(body, :metadata, :metadata)
      |> put_if(body, :usage, :usage)
      |> maybe_put_endpoint()

    Response.new(text, meta, body)
  end

  defp response_from_body(body), do: Response.new("", %{endpoint: :responses}, body)

  defp collect_output_text(body) when is_map(body) do
    body
    |> Map.get("output")
    |> case do
      nil -> Map.get(body, :output)
      value -> value
    end
    |> List.wrap()
    |> Enum.flat_map(&extract_output_parts/1)
    |> Enum.join("")
  end

  defp collect_output_text(_), do: ""

  defp extract_output_parts(%{"type" => "message", "content" => content}) do
    Enum.flat_map(content, &extract_output_parts/1)
  end

  defp extract_output_parts(%{type: "message", content: content}) do
    Enum.flat_map(content, &extract_output_parts/1)
  end

  defp extract_output_parts(%{"type" => "output_text", "text" => text}) when is_binary(text),
    do: [text]

  defp extract_output_parts(%{type: "output_text", text: text}) when is_binary(text), do: [text]
  defp extract_output_parts(_other), do: []

  defp maybe_put_endpoint(map), do: Map.put(map, :endpoint, :responses)

  defp put_if(meta, body, key, meta_key) do
    case Map.get(body, Atom.to_string(key)) || Map.get(body, key) do
      nil -> meta
      value -> Map.put(meta, meta_key, value)
    end
  end

  defp build_responses_url(base_url, response_id) do
    trimmed = String.trim_trailing(base_url, "/")
    trimmed <> "/responses/" <> URI.encode(response_id)
  end

  defp http_opts(opts) do
    timeout =
      Keyword.get(opts, :receive_timeout) || Keyword.get(opts, :timeout) ||
        config(:request_timeout) || 30_000

    opts
    |> Keyword.take([:cassette, :cassette_index])
    |> Keyword.put(:receive_timeout, timeout)
  end

  defp build_headers(nil), do: [{"content-type", "application/json"}]

  defp build_headers(api_key) do
    [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{api_key}"}
    ]
  end

  defp resolve_api_key({:system, var}) when is_binary(var), do: System.get_env(var)
  defp resolve_api_key(key) when is_binary(key), do: key
  defp resolve_api_key(_), do: nil

  defp config(key) do
    Application.get_env(:aquila, :openai, []) |> Keyword.get(key)
  end
end
