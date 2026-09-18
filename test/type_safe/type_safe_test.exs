defmodule Aquila.TypeSafeTest do
  use ExUnit.Case, async: false

  alias Aquila.TypeSafe
  alias Aquila.TypeSafe.Answer.{Choice, Noul, Score}
  alias Aquila.TypeSafe.{Model, Question, Response}

  defmodule StubTransport do
    @behaviour Aquila.Transport

    @impl true
    def post(request) do
      send(self(), {:typesafe_request, :post, request})
      Process.get(:typesafe_post_result, {:ok, response_body()})
    end

    @impl true
    def get(request) do
      send(self(), {:typesafe_request, :get, request})

      Process.get(:typesafe_get_result, {
        :ok,
        %{
          "models" => [
            %{
              "name" => "jev-latest",
              "description" => "Latest stable Jev model",
              "release_date" => "2026-09-17"
            }
          ]
        }
      })
    end

    @impl true
    def delete(_request), do: {:error, :not_supported}

    @impl true
    def stream(_request, _callback), do: {:error, :not_supported}

    defp response_body do
      %{
        "model" => "jev-1.13.0",
        "answers" => %{
          "category" => %{
            "type" => "choice",
            "choice" => "science",
            "probabilities" => %{"science" => 0.9, "other" => 0.1},
            "confidence" => 0.8
          },
          "relevance" => %{
            "type" => "score",
            "score" => 1.7,
            "legend" => %{"0" => "none", "1" => "useful", "2" => "core"},
            "probabilities" => %{"0" => 0.0, "1" => 0.3, "2" => 0.7},
            "confidence" => 0.75
          },
          "supported" => %{"type" => "noul", "noul" => 0.92}
        },
        "usage" => %{"input_tokens" => 120, "output_tokens" => 30}
      }
    end
  end

  setup do
    on_exit(fn ->
      Process.delete(:typesafe_post_result)
      Process.delete(:typesafe_get_result)
    end)

    :ok
  end

  test "evaluates typed questions and returns typed answers" do
    questions = %{
      category:
        Question.choice("Which category?", %{
          "science" => "Scientific content",
          "other" => "Anything else"
        }),
      relevance: Question.score("How relevant?", ["none", "useful", "core"]),
      supported: Question.noul("Is the claim supported?")
    }

    assert {:ok, %Response{} = response} =
             TypeSafe.evaluate(%{"passage" => "Evidence"}, questions,
               transport: StubTransport,
               api_key: "test-key",
               base_url: "https://typesafe.test/v1",
               model: "jev-test",
               timeout: 9_000
             )

    assert response.model == "jev-1.13.0"
    assert %Choice{choice: "science", confidence: 0.8} = response.answers["category"]
    assert %Score{score: 1.7, confidence: 0.75} = response.answers["relevance"]
    assert %Noul{probability: 0.92} = response.answers["supported"]
    assert response.usage == %{"input_tokens" => 120, "output_tokens" => 30}

    assert_receive {:typesafe_request, :post, request}
    assert request.endpoint == :system_one
    assert request.url == "https://typesafe.test/v1/systemone"
    assert request.body["model"] == "jev-test"
    assert request.body["state"] == %{"passage" => "Evidence"}
    assert Map.keys(request.body["questions"]) |> Enum.sort() == ~w(category relevance supported)
    assert {"authorization", "Bearer test-key"} in request.headers
    assert request.opts[:receive_timeout] == 9_000
  end

  test "accepts raw question maps" do
    questions = %{
      "category" => %{
        type: :choice,
        instructions: "Which category?",
        criteria: %{"science" => "Scientific", "other" => "Other"}
      },
      "relevance" => %{
        type: "score",
        instructions: "How relevant?",
        criteria: ["none", "useful"]
      },
      "supported" => %{type: "noul", instructions: "Supported?"}
    }

    assert {:ok, %Response{}} =
             TypeSafe.evaluate("Evidence", questions,
               transport: StubTransport,
               api_key: "test-key"
             )
  end

  test "lists available models" do
    assert {:ok, [%Model{name: "jev-latest", release_date: "2026-09-17"}]} =
             TypeSafe.list_models(
               transport: StubTransport,
               api_key: "test-key",
               base_url: "https://typesafe.test/v1"
             )

    assert_receive {:typesafe_request, :get, request}
    assert request.endpoint == :typesafe_models
    assert request.url == "https://typesafe.test/v1/models"
  end

  test "requires an API key outside cassette replay" do
    original = Application.get_env(:aquila, :typesafe)
    original_api_key = System.get_env("TYPESAFE_API_KEY")
    original_api_key_file = System.get_env("TYPESAFE_API_KEY_FILE")

    Application.put_env(:aquila, :typesafe, base_url: "https://typesafe.test/v1")
    System.delete_env("TYPESAFE_API_KEY")
    System.delete_env("TYPESAFE_API_KEY_FILE")

    on_exit(fn ->
      Application.put_env(:aquila, :typesafe, original)
      restore_env("TYPESAFE_API_KEY", original_api_key)
      restore_env("TYPESAFE_API_KEY_FILE", original_api_key_file)
    end)

    assert {:error, :missing_api_key} =
             TypeSafe.evaluate(
               "state",
               %{
                 "yes" => Question.noul("Does this hold?")
               },
               transport: StubTransport
             )
  end

  test "allows credential-free cassette replay" do
    Process.put(:typesafe_post_result, {
      :ok,
      %{
        "model" => "jev-1.13.0",
        "answers" => %{"yes" => %{"type" => "noul", "noul" => 0.5}},
        "usage" => %{}
      }
    })

    assert {:ok, %Response{}} =
             TypeSafe.evaluate("state", %{"yes" => Question.noul("Does this hold?")},
               transport: StubTransport,
               cassette: "typesafe/replay"
             )
  end

  test "rejects missing, extra, or malformed answers" do
    Process.put(:typesafe_post_result, {
      :ok,
      %{
        "model" => "jev-1.13.0",
        "answers" => %{},
        "usage" => %{}
      }
    })

    assert {:error, {:invalid_response, {:answer_ids, ["yes"], []}}} =
             TypeSafe.evaluate("state", %{"yes" => Question.noul("Does this hold?")},
               transport: StubTransport,
               api_key: "test-key"
             )

    Process.put(:typesafe_post_result, {
      :ok,
      %{
        "model" => "jev-1.13.0",
        "answers" => %{"yes" => %{"type" => "noul", "noul" => 1.2}},
        "usage" => %{}
      }
    })

    assert {:error, {:invalid_response, {"yes", {:invalid_noul_answer, _}}}} =
             TypeSafe.evaluate("state", %{"yes" => Question.noul("Does this hold?")},
               transport: StubTransport,
               api_key: "test-key"
             )
  end

  test "propagates transport errors" do
    Process.put(:typesafe_post_result, {:error, {:http_error, 429, %{"error" => "rate limit"}}})

    assert {:error, {:http_error, 429, %{"error" => "rate limit"}}} =
             TypeSafe.evaluate("state", %{"yes" => Question.noul("Does this hold?")},
               transport: StubTransport,
               api_key: "test-key"
             )
  end

  test "validates request state and questions" do
    assert {:error, {:invalid_request, :state}} =
             TypeSafe.evaluate(123, %{"yes" => Question.noul("Does this hold?")},
               transport: StubTransport,
               api_key: "test-key"
             )

    assert {:error, {:invalid_request, :questions}} =
             TypeSafe.evaluate("state", %{}, transport: StubTransport, api_key: "test-key")
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
