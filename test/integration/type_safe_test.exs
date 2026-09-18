defmodule Aquila.TypeSafeIntegrationTest do
  use ExUnit.Case, async: false
  use Aquila.Cassette

  alias Aquila.TypeSafe
  alias Aquila.TypeSafe.Answer.{Choice, Noul, Score}
  alias Aquila.TypeSafe.{Model, Question}

  test "lists Jev models with a recorded response" do
    aquila_cassette "typesafe/models" do
      assert {:ok, models} = TypeSafe.list_models()
      assert Enum.any?(models, &match?(%Model{name: "jev-latest"}, &1))
    end
  end

  test "evaluates a mixed Jev judgment with a recorded response" do
    aquila_cassette "typesafe/mixed-judgment" do
      state = %{
        "theme" => "Longevity: evidence about healthy human lifespan",
        "claim" => "Rapamycin extends healthy lifespan in humans.",
        "passage" =>
          "In genetically heterogeneous mice, intermittent rapamycin increased median lifespan. Human outcomes were not reported.",
        "source" =>
          "A trial protocol will study rapamycin safety biomarkers in older adults; no outcome results are available."
      }

      questions = %{
        "claim_type" =>
          Question.choice("Classify `state.claim` by what it asserts, without judging truth.", %{
            "effect" => "An intervention or exposure changes an outcome",
            "mechanism" => "A biological or causal pathway",
            "descriptive" => "A factual event or status rather than an effect"
          }),
        "source_relevance" =>
          Question.score("How relevant is `state.source` to `state.theme`?", [
            "Unrelated",
            "Topically adjacent",
            "Directly useful context",
            "Core outcome evidence"
          ]),
        "passage_supports_claim" =>
          Question.noul(
            "Does `state.passage` directly support `state.claim` as written, preserving the species distinction?",
            %{
              true => "Directly supports the human claim",
              false => "Does not establish the human claim"
            }
          )
      }

      assert {:ok, result} = TypeSafe.evaluate(state, questions)
      assert result.model =~ "jev-"
      assert %Choice{choice: "effect"} = result.answers["claim_type"]
      assert %Score{score: score} = result.answers["source_relevance"]
      assert score >= 1.0 and score <= 3.0
      assert %Noul{probability: support} = result.answers["passage_supports_claim"]
      assert support < 0.5
      assert is_integer(result.usage["input_tokens"])
    end
  end
end
