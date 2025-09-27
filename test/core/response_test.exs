defmodule Aquila.ResponseTest do
  use ExUnit.Case, async: true

  alias Aquila.Response

  test "new/3 flattens iodata" do
    response = Response.new(["hello", ?\s, "world"], %{foo: :bar}, %{})
    assert response.text == "hello world"
    assert response.meta[:foo] == :bar
  end

  test "update_meta/2" do
    response = Response.new("hi", %{count: 1})

    updated =
      Response.update_meta(response, &Map.update(&1, :count, 1, fn value -> value + 1 end))

    assert updated.meta[:count] == 2
  end
end
