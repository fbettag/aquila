defmodule AquilaTranscriptionTest do
  use ExUnit.Case, async: true

  alias Req.Response

  setup do
    path =
      System.tmp_dir!()
      |> Path.join("aquila-transcribe-#{System.unique_integer([:positive])}")

    File.write!(path, "binary-audio")

    on_exit(fn -> File.rm(path) end)

    {:ok, file_path: path}
  end

  test "returns plain text response when body is binary", %{file_path: file_path} do
    client = fn url, opts ->
      assert String.ends_with?(url, "/audio/transcriptions")
      assert Keyword.keyword?(opts)

      {:ok, %Response{status: 200, body: "hello"}}
    end

    assert {:ok, "hello"} =
             Aquila.transcribe_audio(file_path,
               http_client: client,
               api_key: "test-key",
               model: "test-model"
             )
  end

  test "extracts text key from map body", %{file_path: file_path} do
    client = fn _url, _opts ->
      {:ok, %{status: 200, body: %{"text" => "transcribed"}}}
    end

    assert {:ok, "transcribed"} =
             Aquila.transcribe_audio(file_path, http_client: client, api_key: "test-key")
  end

  test "falls back to inspecting unknown body shapes", %{file_path: file_path} do
    client = fn _url, _opts ->
      {:ok, %{status: 200, body: %{foo: :bar}}}
    end

    assert {:ok, inspected} =
             Aquila.transcribe_audio(file_path, http_client: client, api_key: "test-key")

    assert inspected =~ "foo"
  end

  test "returns raw body when requested", %{file_path: file_path} do
    client = fn _url, _opts ->
      {:ok, %{status: 200, body: %{json: true}}}
    end

    assert {:ok, %{json: true}} =
             Aquila.transcribe_audio(file_path,
               http_client: client,
               api_key: "test-key",
               raw: true
             )
  end

  test "propagates http error tuples", %{file_path: file_path} do
    client = fn _url, _opts ->
      {:ok, %{status: 422, body: %{"error" => "bad"}}}
    end

    assert {:error, %{status: 422, body: %{"error" => "bad"}}} =
             Aquila.transcribe_audio(file_path, http_client: client, api_key: "test-key")
  end

  test "propagates transport errors", %{file_path: file_path} do
    client = fn _url, _opts ->
      {:error, :timeout}
    end

    assert {:error, :timeout} =
             Aquila.transcribe_audio(file_path, http_client: client, api_key: "test-key")
  end

  test "includes additional form fields in request", %{file_path: file_path} do
    client = fn _url, opts ->
      form = Keyword.fetch!(opts, :form_multipart)

      assert {:ok, language} = fetch_field(form, :language)
      assert language == "en"

      {:ok, %Response{status: 200, body: "ok"}}
    end

    assert {:ok, "ok"} =
             Aquila.transcribe_audio(file_path,
               api_key: "test-key",
               http_client: client,
               form_fields: [language: "en"]
             )
  end

  test "uses default filename suffix when original path lacks extension", %{file_path: file_path} do
    client = fn _url, opts ->
      form = Keyword.fetch!(opts, :form_multipart)

      assert {:ok, {payload, metadata}} = fetch_field(form, :file)
      assert payload == "binary-audio"
      assert metadata[:filename] =~ ".webm"
      assert metadata[:content_type] in ["audio/webm", "video/webm", "application/octet-stream"]

      {:ok, %Response{status: 200, body: "ok"}}
    end

    assert {:ok, "ok"} =
             Aquila.transcribe_audio(file_path, api_key: "test-key", http_client: client)
  end

  test "raises when :form_fields is not a keyword list", %{file_path: file_path} do
    assert_raise ArgumentError, fn ->
      Aquila.transcribe_audio(file_path,
        api_key: "test-key",
        http_client: fn _, _ -> {:ok, %{status: 200, body: "ok"}} end,
        form_fields: [:invalid]
      )
    end
  end

  test "raises when http_client does not obey arity", %{file_path: file_path} do
    assert_raise ArgumentError, fn ->
      Aquila.transcribe_audio(file_path, api_key: "test-key", http_client: :not_a_fun)
    end
  end

  test "returns error when API key is missing", %{file_path: file_path} do
    original = Application.get_env(:aquila, :openai, [])
    cleaned = Keyword.delete(original, :api_key)

    Application.put_env(:aquila, :openai, cleaned)
    on_exit(fn -> Application.put_env(:aquila, :openai, original) end)

    assert {:error, :missing_api_key} =
             Aquila.transcribe_audio(file_path,
               http_client: fn _, _ -> flunk("should not call client") end
             )
  end

  test "returns file read errors", %{file_path: file_path} do
    File.rm!(file_path)

    assert {:error, :enoent} = Aquila.transcribe_audio(file_path)
  end

  defp fetch_field(form, key) do
    form
    |> Enum.find_value(fn
      {^key, value} -> {:ok, value}
      _other -> false
    end)
    |> case do
      nil -> {:error, :missing}
      {:ok, value} -> {:ok, value}
    end
  end
end
