defmodule Aquila.TypeSafe do
  @moduledoc """
  Adapter for TypeSafe System One models such as Jev.

  System One evaluates a shared state against independent typed questions. It
  returns decisions and calibrated probability distributions rather than
  generated text, so application code retains control over thresholds and
  side effects.
  """

  alias Aquila.Cassette
  alias Aquila.TypeSafe.{Answer, Model, Question, Response}

  @default_base_url "https://api.typesafe.ai/v1"
  @default_model "jev-latest"
  @default_timeout 60_000

  @typedoc "Textual or structured state accepted by TypeSafe System One."
  @type state :: String.t() | map() | list()
  @type questions :: %{required(String.t() | atom()) => Question.t() | map()}
  @type options :: keyword()

  @doc """
  Evaluates `state` against one or more typed questions.

  Question IDs are normalized to strings. Successful responses include the
  actual model version, typed answers, token usage, and the raw provider body.
  """
  @spec evaluate(state(), questions(), options()) :: {:ok, Response.t()} | {:error, term()}
  def evaluate(state, questions, opts \\ []) do
    opts = apply_cassette_defaults(opts)

    with :ok <- validate_state(state),
         {:ok, normalized_questions} <- normalize_questions(questions),
         {:ok, request} <- build_request(state, normalized_questions, opts) do
      metadata = %{model: request.body["model"], question_count: map_size(normalized_questions)}
      started_at = System.monotonic_time()

      :telemetry.execute(
        [:aquila, :typesafe, :request, :start],
        %{system_time: System.system_time()},
        metadata
      )

      result =
        request.transport.post(Map.delete(request, :transport))
        |> parse_evaluation_result(Map.keys(normalized_questions))

      emit_stop(started_at, metadata, result)
      result
    end
  rescue
    exception ->
      :telemetry.execute(
        [:aquila, :typesafe, :request, :exception],
        %{system_time: System.system_time()},
        %{kind: :error, reason: exception}
      )

      reraise(exception, __STACKTRACE__)
  end

  @doc "Lists the TypeSafe model names and aliases available to the account."
  @spec list_models(options()) :: {:ok, [Model.t()]} | {:error, term()}
  def list_models(opts \\ []) do
    opts = apply_cassette_defaults(opts)

    with {:ok, request} <- build_models_request(opts),
         {:ok, body} <- request.transport.get(Map.delete(request, :transport)),
         {:ok, models} <- parse_models(body) do
      {:ok, models}
    end
  end

  defp build_request(state, questions, opts) do
    with {:ok, api_key} <- fetch_api_key(opts) do
      config = config()
      model = Keyword.get(opts, :model) || config[:default_model] || @default_model

      if is_binary(model) and model != "" do
        {:ok,
         %{
           transport: transport(opts),
           endpoint: :system_one,
           url: endpoint_url(opts, "systemone"),
           headers: headers(api_key),
           body: %{"state" => state, "model" => model, "questions" => questions},
           opts: request_opts(opts)
         }}
      else
        {:error, {:invalid_request, :model}}
      end
    end
  end

  defp build_models_request(opts) do
    with {:ok, api_key} <- fetch_api_key(opts) do
      {:ok,
       %{
         transport: transport(opts),
         endpoint: :typesafe_models,
         url: endpoint_url(opts, "models"),
         headers: headers(api_key),
         body: nil,
         opts: request_opts(opts)
       }}
    end
  end

  defp validate_state(state) when is_binary(state) or is_map(state) or is_list(state), do: :ok
  defp validate_state(_state), do: {:error, {:invalid_request, :state}}

  defp normalize_questions(questions) when is_map(questions) and map_size(questions) > 0 do
    Enum.reduce_while(questions, {:ok, %{}}, fn {id, question}, {:ok, acc} ->
      id = to_string(id)

      if id == "" do
        {:halt, {:error, {:invalid_request, :question_id}}}
      else
        case normalize_question(question) do
          {:ok, normalized} -> {:cont, {:ok, Map.put(acc, id, normalized)}}
          {:error, reason} -> {:halt, {:error, {:invalid_question, id, reason}}}
        end
      end
    end)
  end

  defp normalize_questions(_questions), do: {:error, {:invalid_request, :questions}}

  defp normalize_question(%Question{} = question), do: {:ok, Question.to_map(question)}

  defp normalize_question(question) when is_map(question) do
    type = map_value(question, "type")
    instructions = map_value(question, "instructions")
    criteria = map_value(question, "criteria")

    try do
      normalized =
        case to_string(type) do
          "choice" -> Question.choice(instructions, criteria)
          "score" -> Question.score(instructions, criteria)
          "noul" -> Question.noul(instructions, criteria)
          _other -> raise ArgumentError, "unknown question type"
        end

      {:ok, Question.to_map(normalized)}
    rescue
      exception in ArgumentError -> {:error, Exception.message(exception)}
    end
  end

  defp normalize_question(_question), do: {:error, "question must be a Question struct or map"}

  defp parse_evaluation_result({:ok, body}, expected_ids), do: parse_response(body, expected_ids)
  defp parse_evaluation_result({:error, reason}, _expected_ids), do: {:error, reason}

  defp parse_response(body, expected_ids) when is_map(body) do
    model = map_value(body, "model")
    answers = map_value(body, "answers")
    usage = map_value(body, "usage")

    with true <- is_binary(model) and model != "",
         true <- is_map(answers),
         :ok <- validate_answer_ids(answers, expected_ids),
         {:ok, parsed_answers} <- parse_answers(answers),
         true <- is_map(usage) do
      {:ok,
       %Response{
         model: model,
         answers: parsed_answers,
         usage: stringify_keys(usage),
         raw: body
       }}
    else
      {:error, reason} -> {:error, {:invalid_response, reason}}
      _invalid -> {:error, {:invalid_response, :shape}}
    end
  end

  defp parse_response(body, _expected_ids), do: {:error, {:invalid_response, {:body, body}}}

  defp validate_answer_ids(answers, expected_ids) do
    actual = answers |> Map.keys() |> Enum.map(&to_string/1) |> MapSet.new()
    expected = MapSet.new(expected_ids)

    if actual == expected,
      do: :ok,
      else: {:error, {:answer_ids, MapSet.to_list(expected), MapSet.to_list(actual)}}
  end

  defp parse_answers(answers) do
    Enum.reduce_while(answers, {:ok, %{}}, fn {id, answer}, {:ok, acc} ->
      case Answer.parse(answer) do
        {:ok, parsed} -> {:cont, {:ok, Map.put(acc, to_string(id), parsed)}}
        {:error, reason} -> {:halt, {:error, {to_string(id), reason}}}
      end
    end)
  end

  defp parse_models(body) when is_map(body) do
    case map_value(body, "models") do
      models when is_list(models) -> parse_model_entries(models)
      _invalid -> {:error, {:invalid_response, :models}}
    end
  end

  defp parse_models(_body), do: {:error, {:invalid_response, :models}}

  defp parse_model_entries(models) do
    Enum.reduce_while(models, {:ok, []}, fn entry, {:ok, acc} ->
      name = map_value(entry, "name")
      description = map_value(entry, "description")
      release_date = map_value(entry, "release_date")

      if Enum.all?([name, description, release_date], &is_binary/1) do
        model = %Model{name: name, description: description, release_date: release_date}
        {:cont, {:ok, [model | acc]}}
      else
        {:halt, {:error, {:invalid_response, {:model, entry}}}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp fetch_api_key(opts) do
    key = Keyword.get(opts, :api_key) || config()[:api_key]

    case resolve_api_key(key) || resolve_default_api_key() do
      nil ->
        if Keyword.has_key?(opts, :cassette), do: {:ok, nil}, else: {:error, :missing_api_key}

      "" ->
        if Keyword.has_key?(opts, :cassette), do: {:ok, nil}, else: {:error, :missing_api_key}

      api_key ->
        {:ok, api_key}
    end
  end

  defp resolve_default_api_key do
    System.get_env("TYPESAFE_API_KEY") ||
      read_key_file(System.get_env("TYPESAFE_API_KEY_FILE"))
  end

  defp resolve_api_key({:system, variable}) when is_binary(variable), do: System.get_env(variable)
  defp resolve_api_key({:file, path}) when is_binary(path), do: read_key_file(path)
  defp resolve_api_key(key) when is_binary(key), do: key
  defp resolve_api_key(_key), do: nil

  defp read_key_file(nil), do: nil

  defp read_key_file(path) do
    case File.read(path) do
      {:ok, contents} -> String.trim(contents)
      {:error, _reason} -> nil
    end
  end

  defp endpoint_url(opts, endpoint) do
    base_url = Keyword.get(opts, :base_url) || config()[:base_url] || @default_base_url
    String.trim_trailing(base_url, "/") <> "/" <> endpoint
  end

  defp transport(opts) do
    Keyword.get(opts, :transport) ||
      Application.get_env(:aquila, :transport, Aquila.Transport.OpenAI)
  end

  defp headers(nil), do: [{"content-type", "application/json"}]

  defp headers(api_key) do
    [{"content-type", "application/json"}, {"authorization", "Bearer #{api_key}"}]
  end

  defp request_opts(opts) do
    timeout =
      Keyword.get(opts, :receive_timeout) || Keyword.get(opts, :timeout) ||
        config()[:request_timeout] || @default_timeout

    opts
    |> Keyword.take([:cassette, :cassette_index, :verify_prompt])
    |> Keyword.put(:receive_timeout, timeout)
  end

  defp emit_stop(started_at, metadata, result) do
    status = if match?({:ok, _}, result), do: :ok, else: :error

    :telemetry.execute(
      [:aquila, :typesafe, :request, :stop],
      %{duration: System.monotonic_time() - started_at},
      Map.put(metadata, :status, status)
    )
  end

  defp apply_cassette_defaults(opts) do
    cond do
      Keyword.has_key?(opts, :cassette) -> opts
      cassette = Cassette.current() -> merge_cassette_opts(opts, cassette)
      true -> opts
    end
  end

  defp merge_cassette_opts(opts, {name, cassette_opts}) do
    Enum.reduce(cassette_opts, Keyword.put(opts, :cassette, name), fn {key, value}, acc ->
      Keyword.put_new(acc, key, value)
    end)
  end

  defp config, do: Application.get_env(:aquila, :typesafe, [])
  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp map_value(_map, _key), do: nil
end
