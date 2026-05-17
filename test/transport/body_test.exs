defmodule Aquila.TransportBodyTest do
  use ExUnit.Case, async: true

  alias Aquila.Transport.Body

  defmodule SampleStruct do
    defstruct [:foo, :bar]
  end

  test "normalize transforms structs into sorted maps with string keys" do
    sample = %SampleStruct{foo: 1, bar: [baz: 2]}

    assert Body.normalize(sample) == %{
             "bar" => %{"baz" => 2},
             "foo" => 1
           }
  end

  test "normalize handles keyword lists and plain lists" do
    assert Body.normalize(foo: 1, bar: [baz: 2]) == %{
             "bar" => %{"baz" => 2},
             "foo" => 1
           }

    assert Body.normalize([%{alpha: 1}, %{beta: 2}]) == [%{"alpha" => 1}, %{"beta" => 2}]
  end

  test "normalize preserves continuation payloads and drops duplicated prior input" do
    recorded_shape = %{
      previous_response_id: "resp_123",
      input: [
        %{role: "user", content: [%{type: "input_text", text: "calculate"}]},
        %{type: "function_call_output", call_id: "call_1", output: "4"}
      ]
    }

    corrected_shape = %{
      previous_response_id: "resp_123",
      input: [
        %{type: "function_call_output", call_id: "call_1", output: "4"}
      ]
    }

    assert Body.normalize(recorded_shape) == Body.normalize(corrected_shape)

    assert Body.normalize(corrected_shape) == %{
             "input" => [
               %{"call_id" => "call_1", "output" => "4", "type" => "function_call_output"}
             ]
           }
  end
end
