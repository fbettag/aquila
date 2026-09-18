defmodule Aquila.TypeSafe.QuestionTest do
  use ExUnit.Case, async: true

  alias Aquila.TypeSafe.Question

  test "builds choice, score, and noul questions" do
    assert %Question{type: :choice} =
             Question.choice("Which outcome fits?", %{
               "yes" => "The condition holds",
               "no" => "The condition does not hold"
             })

    assert %Question{type: :score, criteria: ["low", "high"]} =
             Question.score("How strong is the evidence?", ["low", "high"])

    assert %Question{type: :noul, criteria: %{"true" => "yes", "false" => "no"}} =
             Question.noul("Does it match?", %{true => "yes", false => "no"})
  end

  test "validates question shapes" do
    assert_raise ArgumentError, ~r/at least two options/, fn ->
      Question.choice("Pick one", %{"only" => "one"})
    end

    assert_raise ArgumentError, ~r/ordered list/, fn ->
      Question.score("Score it", ["only"])
    end

    assert_raise ArgumentError, ~r/both true and false/, fn ->
      Question.noul("Is it true?", %{"true" => "yes"})
    end

    assert_raise ArgumentError, ~r/non-empty/, fn ->
      Question.noul("")
    end
  end
end
