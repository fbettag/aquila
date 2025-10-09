defmodule Aquila.DeepResearch do
  @moduledoc """
  Helpers for orchestrating OpenAI Deep Research requests while keeping Aquila's
  cassette-aware transport stack and streaming integrations intact.

  The module exposes convenience wrappers for common Deep Research workflows:

    * `create/2` – kick off a background Deep Research run (sets `background: true`)
    * `fetch/2` – retrieve the latest status/result for a response ID
    * `cancel/2` – cancel an in-flight Deep Research run
    * `stream/2` – start a streamed run using Aquila's normal streaming pipeline

  All helpers honour recorder cassettes, custom transports, and the standard
  Aquila option set (e.g. `:base_url`, `:api_key`, `:metadata`). They also ensure
  the required `web_search_preview` tool is configured unless explicitly provided.
  """

  alias Aquila.{Cassette, Message, Tool}

  @default_model "openai/o3-deep-research-2025-06-26"
  @default_base_url "https://api.openai.com/v1"
  @required_tool "web_search_preview"

  @type prompt :: Aquila.prompt()

  @doc """
  Creates a Deep Research run in background mode.

  The request is issued against the Responses API with `background: true`.
  Deep Research requires the builtin `web_search_preview` tool; Aquila injects
  it automatically while preserving any additional tools you pass via `:tools`.
  Customise the run with standard Responses options such as `:reasoning` (e.g.
  `%{effort: "low"}`) or `:metadata`.

  The returned map mirrors the provider payload (typically containing the new
  `response_id` and `status`).
  """
  @spec create(prompt(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(input, opts \\ []) do
    opts = apply_defaults(opts)

    transport = transport(opts)
    request = build_create_request(input, opts)

    transport.post(request)
  end

  @doc """
  Retrieves the current state of a Deep Research run.

  Delegates to `Aquila.retrieve_response/2`, returning `{:ok, %Aquila.Response{}}`
  when the provider responds successfully.
  """
  @spec fetch(String.t(), keyword()) :: {:ok, Aquila.Response.t()} | {:error, term()}
  def fetch(response_id, opts \\ [])

  def fetch(response_id, opts) when is_binary(response_id) do
    opts
    |> apply_defaults()
    |> Aquila.retrieve_response(response_id)
  end

  @doc """
  Cancels a Deep Research run.
  """
  @spec cancel(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def cancel(response_id, opts \\ [])

  def cancel(response_id, opts) when is_binary(response_id) do
    opts = apply_defaults(opts)

    transport = transport(opts)
    base_url = base_url(opts)
    api_key = api_key!(opts)

    request = %{
      endpoint: :responses,
      url: build_responses_url(base_url, response_id <> "/cancel"),
      headers: build_headers(api_key),
      body: %{},
      opts: http_opts(opts)
    }

    transport.post(request)
  end

  @doc """
  Starts a streamed Deep Research run using Aquila's streaming pipeline.

  This helper injects Deep Research defaults (Responses endpoint, model, and
  required tools) before delegating to `Aquila.stream/2`. Stream events include
  the usual chunk/tool notifications plus `{:aquila_event, %{source:
  :deep_research}}` tuples, which `Aquila.StreamSession` rebroadcasts as
  `{:aquila_stream_research_event, session_id, payload}` for LiveView UIs.

  Supports the same options as `Aquila.stream/2` (e.g. `:sink`, `:reasoning`,
  `:metadata`, `:cassette`).
  """
  @spec stream(prompt(), keyword()) :: {:ok, reference()} | {:error, term()}
  def stream(input, opts \\ []) do
    opts =
      opts
      |> apply_defaults()
      |> ensure_model()
      |> ensure_endpoint()
      |> ensure_required_tools()

    Aquila.stream(input, opts)
  end

  ## ------------------------------------------------------------------------
  ## Request construction helpers
  ## ------------------------------------------------------------------------

  defp build_create_request(input, opts) do
    base_url = base_url(opts)
    api_key = api_key!(opts)
    model = model(opts)

    messages = Message.normalize(input, opts)
    instructions = opts[:instructions] || opts[:instruction]
    previous_response_id = opts[:previous_response_id] || opts[:response_id]
    metadata = normalize_metadata(opts[:metadata])

    body =
      %{
        model: model,
        input: Enum.map(messages, &message_to_response/1),
        tools: tool_payloads(opts),
        stream: false,
        background: true
      }
      |> maybe_put(:instructions, instructions)
      |> maybe_put(:previous_response_id, previous_response_id)
      |> maybe_put(:metadata, metadata)
      |> maybe_put(:store, opts[:store])
      |> maybe_put(:temperature, opts[:temperature])
      |> maybe_put(:reasoning, normalize_reasoning(opts[:reasoning]))
      |> maybe_put(:response_format, opts[:response_format])
      |> maybe_put(:max_output_tokens, opts[:max_output_tokens])

    %{
      endpoint: :responses,
      url: build_responses_url(base_url),
      headers: build_headers(api_key),
      body: body,
      opts: http_opts(opts)
    }
  end

  defp tool_payloads(opts) do
    opts
    |> Keyword.get(:tools, [])
    |> List.wrap()
    |> ensure_required_tool_present()
    |> Enum.map(&Tool.to_openai/1)
  end

  defp ensure_required_tool_present(tools) do
    if Enum.any?(tools, &tool_matches?(&1, @required_tool)) do
      tools
    else
      tools ++ [%{type: @required_tool}]
    end
  end

  defp tool_matches?(%Tool{}, _required), do: false
  defp tool_matches?(%{type: type}, required), do: to_string(type) == required
  defp tool_matches?(%{"type" => type}, required), do: to_string(type) == required
  defp tool_matches?(_, _), do: false

  defp message_to_response(%Message{role: role, content: content})
       when is_binary(content) or is_list(content) do
    %{
      role: Atom.to_string(role),
      content: [response_text_part(role, content)]
    }
  end

  defp message_to_response(%Message{role: role, content: content}) when is_map(content) do
    %{
      role: Atom.to_string(role),
      content: [content]
    }
  end

  defp response_text_part(role, content) do
    type =
      case role do
        :assistant -> "output_text"
        :function -> "output_text"
        _ -> "input_text"
      end

    %{type: type, text: IO.iodata_to_binary(content)}
  end

  ## ------------------------------------------------------------------------
  ## Option helpers
  ## ------------------------------------------------------------------------

  defp apply_defaults(opts) do
    opts
    |> apply_cassette_defaults()
    |> ensure_model()
    |> ensure_endpoint()
    |> ensure_required_tools()
  end

  defp ensure_required_tools(opts) do
    case Keyword.get(opts, :tools) do
      nil ->
        Keyword.put(opts, :tools, [%{type: @required_tool}])

      tools ->
        normalized =
          tools
          |> List.wrap()
          |> ensure_required_tool_present()

        Keyword.put(opts, :tools, normalized)
    end
  end

  defp ensure_model(opts), do: Keyword.put_new(opts, :model, @default_model)

  defp ensure_endpoint(opts), do: Keyword.put_new(opts, :endpoint, :responses)

  defp transport(opts) do
    Keyword.get(opts, :transport) ||
      Application.get_env(:aquila, :transport, Aquila.Transport.OpenAI)
  end

  defp base_url(opts) do
    Keyword.get(opts, :base_url) ||
      config(:base_url) ||
      @default_base_url
  end

  defp model(opts) do
    opts
    |> Keyword.get(:model, @default_model)
    |> to_string()
  end

  defp api_key!(opts) do
    opts
    |> Keyword.get(:api_key)
    |> case do
      nil -> config(:api_key)
      key -> key
    end
    |> resolve_api_key()
    |> case do
      nil ->
        raise ArgumentError,
              "Deep Research requests require an API key. Configure :aquila, :openai :api_key or pass :api_key option."

      key ->
        key
    end
  end

  defp build_responses_url(base_url, suffix \\ nil) do
    trimmed = String.trim_trailing(base_url, "/")

    case suffix do
      nil -> trimmed <> "/responses"
      path -> trimmed <> "/responses/" <> path
    end
  end

  defp build_headers(api_key) do
    [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{api_key}"}
    ]
  end

  defp http_opts(opts) do
    timeout =
      Keyword.get(opts, :receive_timeout) ||
        Keyword.get(opts, :timeout) ||
        config(:request_timeout) ||
        30_000

    opts
    |> Keyword.take([:cassette, :cassette_index])
    |> Keyword.put(:receive_timeout, timeout)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_metadata(nil), do: %{}
  defp normalize_metadata(map) when is_map(map), do: map
  defp normalize_metadata(list) when is_list(list), do: Map.new(list)
  defp normalize_metadata(_), do: %{}

  defp normalize_reasoning(nil), do: nil
  defp normalize_reasoning(map) when is_map(map), do: map
  defp normalize_reasoning(value) when is_binary(value), do: %{effort: value}
  defp normalize_reasoning(_), do: nil

  defp apply_cassette_defaults(opts) do
    cond do
      Keyword.has_key?(opts, :cassette) ->
        opts

      cassette = Cassette.current() ->
        merge_cassette_opts(opts, cassette)

      true ->
        opts
    end
  end

  defp merge_cassette_opts(opts, {name, cassette_opts}) do
    opts
    |> Keyword.put(:cassette, name)
    |> Enum.reduce(cassette_opts, fn {key, value}, acc -> Keyword.put_new(acc, key, value) end)
  end

  defp config(key) do
    Application.get_env(:aquila, :openai, []) |> Keyword.get(key)
  end

  defp resolve_api_key({:system, var}) when is_binary(var), do: System.get_env(var)
  defp resolve_api_key(key) when is_binary(key), do: key
  defp resolve_api_key(_), do: nil
end
