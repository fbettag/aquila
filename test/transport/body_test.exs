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
    assert Body.normalize([foo: 1, bar: [baz: 2]]) == %{
             "bar" => %{"baz" => 2},
             "foo" => 1
           }

    assert Body.normalize([%{alpha: 1}, %{beta: 2}]) == [%{"alpha" => 1}, %{"beta" => 2}]
  end
end
