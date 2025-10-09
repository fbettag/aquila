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

  alias Aquila.{Cassette, DeepResearch, Engine, Response}
  require Logger

  @typedoc "Supported prompt shapes for `ask/2` and `stream/2`."
  @type prompt :: iodata() | [Aquila.Message.t()]
  @typedoc "Shared option keyword list for public API functions."
  @type options :: keyword()
  @typedoc "Returned transcription payload when using `transcribe_audio/2`."
  @type transcription_result :: String.t() | map() | list()

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
    opts =
      opts
      |> apply_cassette_defaults()
      |> Keyword.put_new(:stream, false)

    response = Engine.run(input, opts)

    Logger.info("Aquila.ask completed",
      endpoint: response.meta[:endpoint],
      response_id: response.meta[:response_id] || response.meta[:id]
    )

    response
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
    opts =
      opts
      |> apply_cassette_defaults()
      |> Keyword.put(:stream, true)

    case Engine.run(input, opts) do
      {:ok, ref} = ok ->
        Logger.info("Aquila.stream started", ref: ref)
        ok

      other ->
        other
    end
  end

  @doc """
  Waits for a stream to complete (useful for testing/cassette recording).

  This function blocks until the background streaming task finishes.
  In production, you typically don't need this - just handle events as they arrive.
  In tests with cassettes, this ensures the full stream is recorded before proceeding.

  Returns `{:ok, response}` when complete or `{:error, reason}` on failure.

  ## Example

      {:ok, ref} = Aquila.stream("Hello", model: "gpt-4o-mini")
      {:ok, response} = Aquila.await_stream(ref)
  """
  @spec await_stream(reference(), timeout()) :: {:ok, Response.t()} | {:error, term()}
  def await_stream(ref, timeout \\ :infinity) do
    case Process.get({:aquila_stream_task, ref}) do
      nil ->
        {:error, :no_stream_task}

      task ->
        try do
          Task.await(task, timeout)
        catch
          :exit, reason -> {:error, reason}
        end
    end
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
    opts = apply_cassette_defaults(opts)

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
    opts = apply_cassette_defaults(opts)
    dispatch_http(:delete, response_id, opts)
  end

  @doc """
  Starts a Deep Research run in background mode.

  This helper ensures the Deep Research model and required tools are configured,
  then issues a `background: true` request against the Responses API.
  """
  @spec deep_research_create(prompt(), options()) :: {:ok, map()} | {:error, term()}
  def deep_research_create(input, opts \\ []) do
    DeepResearch.create(input, opts)
  end

  @doc """
  Retrieves the current state of a Deep Research run.
  """
  @spec deep_research_fetch(String.t(), options()) :: {:ok, Response.t()} | {:error, term()}
  def deep_research_fetch(response_id, opts \\ []) when is_binary(response_id) do
    DeepResearch.fetch(response_id, opts)
  end

  @doc """
  Cancels a Deep Research run.
  """
  @spec deep_research_cancel(String.t(), options()) :: {:ok, map()} | {:error, term()}
  def deep_research_cancel(response_id, opts \\ []) when is_binary(response_id) do
    DeepResearch.cancel(response_id, opts)
  end

  @doc """
  Streams Deep Research progress using Aquila's streaming pipeline.
  """
  @spec deep_research_stream(prompt(), options()) :: {:ok, reference()} | {:error, term()}
  def deep_research_stream(input, opts \\ []) do
    DeepResearch.stream(input, opts)
  end

  @doc """
  Transcribes an audio file using the configured OpenAI audio endpoint.

  The helper reads the file from disk, builds a multipart request, and sends
  it to `/audio/transcriptions` using the configured base URL and API key.
  Successful calls return the decoded transcription text by default. Use the
  `:raw` option when you need the original response body (for example when
  requesting `json` or `verbose_json` formats).

  ## Options

  * `:model` – override the configured transcription model.
  * `:response_format` – format accepted by the API (defaults to `"text"`).
  * `:headers` – additional headers appended to the request.
  * `:form_fields` – keyword list of extra multipart fields (e.g. `[{temperature, 0}]`).
  * `:filename` – override the filename metadata sent with the upload.
  * `:content_type` – override the MIME type (defaults to `MIME.from_path/1`).
  * `:base_url` – target a different endpoint (defaults to configured base URL).
  * `:api_key` – provide an API key explicitly.
  * `:req_options` – keyword list merged into the `Req.post/2` call.
  * `:http_client` – two-argument function invoked instead of `&Req.post/2`.
  * `:raw` – when `true`, return the provider response without formatting.

  ## Examples

      iex> Aquila.transcribe_audio("/tmp/sample.webm", model: "gpt-4o-mini-transcribe")
      {:ok, "Hello from Aquila"}
  """
  @spec transcribe_audio(Path.t(), keyword()) :: {:ok, transcription_result()} | {:error, term()}
  def transcribe_audio(file_path, opts \\ []) when is_binary(file_path) do
    with {:ok, payload} <- File.read(file_path),
         {:ok, api_key} <- fetch_api_key(opts),
         {:ok, body} <-
           request_transcription(
             payload,
             file_path,
             Keyword.put(opts, :api_key, api_key)
           ) do
      format_transcription_body(body, opts)
    end
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

  defp fetch_api_key(opts) do
    opts
    |> Keyword.get(:api_key)
    |> case do
      nil -> config(:api_key)
      key -> key
    end
    |> resolve_api_key()
    |> case do
      nil ->
        Logger.warning(
          "Aquila API key missing; set :aquila, :openai configuration or provide :api_key option"
        )

        {:error, :missing_api_key}

      api_key ->
        {:ok, api_key}
    end
  end

  defp request_transcription(payload, file_path, opts) do
    http_client =
      opts
      |> Keyword.get(:http_client, &Req.post/2)
      |> normalize_http_client!()

    base_url = Keyword.get(opts, :base_url) || config(:base_url) || "https://api.openai.com/v1"
    url = build_audio_transcriptions_url(base_url)
    model = transcription_model(opts)
    response_format = Keyword.get(opts, :response_format, "text") |> to_string()

    form_fields = Keyword.get(opts, :form_fields, [])

    unless Keyword.keyword?(form_fields) do
      raise ArgumentError, ":form_fields must be a keyword list"
    end

    filename = Keyword.get(opts, :filename) || default_filename(file_path)

    content_type =
      Keyword.get(opts, :content_type) ||
        MIME.from_path(filename) ||
        MIME.from_path(file_path) ||
        "application/octet-stream"

    form_data =
      [
        file: {payload, filename: filename, content_type: content_type},
        model: model,
        response_format: response_format
      ] ++ form_fields

    req_options =
      opts
      |> Keyword.get(:req_options, [])
      |> normalize_keyword_list!(:req_options)
      |> Keyword.put(:form_multipart, form_data)
      |> merge_headers(opts[:headers])
      |> ensure_authorization(opts[:api_key])
      |> ensure_receive_timeout(opts)

    case http_client.(url, req_options) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, %{status: status, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp transcription_model(opts) do
    value =
      Keyword.get(opts, :model) ||
        config(:transcription_model) ||
        config(:default_model) ||
        "gpt-4o-mini-transcribe"

    to_string(value)
  end

  defp build_audio_transcriptions_url(base_url) do
    trimmed =
      base_url
      |> to_string()
      |> String.trim_trailing("/")

    trimmed <> "/audio/transcriptions"
  end

  defp default_filename(file_path) do
    case Path.extname(file_path) do
      "" -> Path.basename(file_path) <> ".webm"
      _ -> Path.basename(file_path)
    end
  end

  defp merge_headers(req_options, nil), do: req_options

  defp merge_headers(req_options, headers) do
    existing = Keyword.get(req_options, :headers, [])
    Keyword.put(req_options, :headers, existing ++ List.wrap(headers))
  end

  defp ensure_authorization(req_options, api_key) do
    headers = Keyword.get(req_options, :headers, [])

    if Enum.any?(headers, fn {key, _} -> String.downcase(to_string(key)) == "authorization" end) do
      req_options
    else
      Keyword.put(req_options, :headers, [{"authorization", "Bearer #{api_key}"} | headers])
    end
  end

  defp ensure_receive_timeout(req_options, opts) do
    if Keyword.has_key?(req_options, :receive_timeout) do
      req_options
    else
      timeout =
        Keyword.get(opts, :receive_timeout) ||
          Keyword.get(opts, :timeout) ||
          config(:request_timeout) || 30_000

      Keyword.put(req_options, :receive_timeout, timeout)
    end
  end

  defp format_transcription_body(body, opts) do
    if Keyword.get(opts, :raw, false) do
      {:ok, body}
    else
      {:ok, normalize_transcription_text(body)}
    end
  end

  defp normalize_transcription_text(body) when is_binary(body), do: body

  defp normalize_transcription_text(%{"text" => text}) when is_binary(text), do: text
  defp normalize_transcription_text(%{text: text}) when is_binary(text), do: text
  defp normalize_transcription_text(body), do: inspect(body)

  defp normalize_keyword_list!(value, key_name) do
    if Keyword.keyword?(value) do
      value
    else
      raise ArgumentError, "#{key_name} must be a keyword list, got: #{inspect(value)}"
    end
  end

  defp normalize_http_client!(fun) when is_function(fun, 2), do: fun

  defp normalize_http_client!(fun) do
    raise ArgumentError,
          ":http_client must be a function accepting (url, options). Got: #{inspect(fun)}"
  end

  defp apply_cassette_defaults(opts) when is_list(opts) do
    cond do
      Keyword.has_key?(opts, :cassette) -> opts
      cassette = Cassette.current() -> merge_cassette_opts(opts, cassette)
      true -> opts
    end
  end

  defp merge_cassette_opts(opts, {name, cassette_opts}) do
    opts
    |> put_cassette_name(name)
    |> put_missing_opts(cassette_opts)
  end

  defp put_cassette_name(opts, name), do: Keyword.put(opts, :cassette, name)

  defp put_missing_opts(opts, cassette_opts) do
    Enum.reduce(cassette_opts, opts, fn {key, value}, acc ->
      Keyword.put_new(acc, key, value)
    end)
  end

  defp config(key) do
    Application.get_env(:aquila, :openai, []) |> Keyword.get(key)
  end
end
