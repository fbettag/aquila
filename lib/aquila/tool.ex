defmodule Aquila.Tool do
  @moduledoc """
  Representation of a callable tool/function exposed to a model.

  Tools wrap a function that receives decoded JSON arguments and returns a
  payload compatible with the Responses API tool-calling contract.
  """

  @enforce_keys [:name, :function]
  defstruct [:name, :description, :parameters, :function]

  @typedoc "JSON-function definition used when exposing tools to the model."
  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          parameters: map(),
          function: (map() -> any()) | (map(), any() -> any())
        }

  @doc """
  Creates a tool definition from a name, optional metadata, and a callback.

  The callback receives a map decoded from the JSON arguments sent by the
  model and should return a map or string response.

  ## Options

  * `:parameters` (required) – JSON Schema map describing the tool arguments.
  * `:description` – short description surfaced in the model prompt.
  """
  @spec new(String.t(), keyword()) :: t()
  def new(name, opts) when is_list(opts) do
    {function, remaining_opts} =
      cond do
        Keyword.has_key?(opts, :function) ->
          Keyword.pop(opts, :function)

        Keyword.has_key?(opts, :fn) ->
          Keyword.pop(opts, :fn)

        Keyword.has_key?(opts, :fun) ->
          Keyword.pop(opts, :fun)

        true ->
          raise ArgumentError, "tool requires :function callback"
      end

    new(name, remaining_opts, function)
  end

  @spec new(String.t(), (map() -> any())) :: t()
  def new(name, function) when is_function(function, 1), do: new(name, [], function)
  def new(name, function) when is_function(function, 2), do: new(name, [], function)

  @spec new(String.t(), keyword(), (map() -> any())) :: t()
  def new(name, opts, function)
      when is_binary(name) and (is_function(function, 1) or is_function(function, 2)) do
    parameters = Keyword.get(opts, :parameters, %{"type" => "object", "properties" => %{}})

    normalized_parameters = normalize_parameters(parameters)

    struct!(__MODULE__,
      name: name,
      description: Keyword.get(opts, :description),
      parameters: normalized_parameters,
      function: function
    )
  end

  @doc """
  Converts a tool definition into the wire-format map expected by OpenAI.

  Accepts either `%Aquila.Tool{}` structs or pre-normalised maps. Useful when you
  want to provide hand-crafted payloads for advanced tool types.
  """
  @spec to_openai(map() | t()) :: map()
  def to_openai(%__MODULE__{name: name, description: description, parameters: parameters}) do
    function =
      maybe_put(%{name: name, parameters: parameters}, :description, description)

    %{type: "function", function: function}
  end

  def to_openai(%{type: type} = map) when is_atom(type) do
    map
    |> Map.put(:type, Atom.to_string(type))
    |> maybe_stringify_function_type()
  end

  def to_openai(%{type: type} = map) when is_binary(type) do
    maybe_stringify_function_type(map)
  end

  def to_openai(%{"type" => type} = map) when is_atom(type) do
    Map.put(map, "type", Atom.to_string(type))
  end

  def to_openai(%{"type" => type} = map) when is_binary(type), do: map

  defp maybe_stringify_function_type(%{type: type, function: function} = map) do
    # Preserve the name field if it exists (as atom or string key), but don't add nil
    updated_function =
      case {Map.get(function, :name), Map.get(function, "name")} do
        # No name field, keep as-is
        {nil, nil} -> function
        # Has atom :name
        {atom_name, nil} when not is_nil(atom_name) -> function
        # Has string "name"
        {nil, string_name} when not is_nil(string_name) -> function
        # Has both, prefer atom key
        {_atom_name, _} -> Map.delete(function, "name")
      end

    # Don't add top-level name field as it's not supported by all providers (e.g., Mistral)
    # The name should only be inside the function object
    base = %{map | type: type, function: updated_function}

    # Preserve existing top-level name if it was explicitly provided, but don't add it from function.name
    cond do
      Map.has_key?(base, :name) ->
        base

      Map.has_key?(base, "name") ->
        base

      true ->
        base
    end
  end

  defp maybe_stringify_function_type(map), do: map

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_parameters(%{} = params) do
    if string_key_map?(params) do
      params
    else
      {normalized, required} = normalize_schema(params)

      if required == [] do
        normalized
      else
        Map.put(normalized, "required", Enum.uniq(required))
      end
    end
  end

  defp normalize_parameters(other), do: other

  defp string_key_map?(map) do
    Enum.all?(Map.keys(map), &is_binary/1)
  end

  defp normalize_schema(value) when is_map(value) do
    if string_key_map?(value) do
      {value, []}
    else
      {normalized, required} =
        Enum.reduce(value, {%{}, []}, fn {key, val}, {acc, reqs} ->
          key_string = key_to_string(key)

          case key_string do
            "properties" ->
              {props, prop_required} = normalize_properties(val)
              {Map.put(acc, "properties", props), reqs ++ prop_required}

            _ ->
              {normalized_val, _} = normalize_schema(val)
              {Map.put(acc, key_string, normalized_val), reqs}
          end
        end)

      normalized =
        if required == [] do
          normalized
        else
          Map.put(normalized, "required", Enum.uniq(required))
        end

      {normalized, []}
    end
  end

  defp normalize_schema(list) when is_list(list) do
    {normalized_list, _} =
      Enum.map_reduce(list, [], fn item, acc ->
        {normalized, _} = normalize_schema(item)
        {normalized, acc}
      end)

    {normalized_list, []}
  end

  defp normalize_schema(value) when is_atom(value) do
    if value in [true, false, nil] do
      {value, []}
    else
      {Atom.to_string(value), []}
    end
  end

  defp normalize_schema(other), do: {other, []}

  defp normalize_properties(%{} = props) do
    Enum.reduce(props, {%{}, []}, fn {name, schema}, {acc, reqs} ->
      {required?, schema_without_flag} = extract_required(schema)
      {normalized_schema, _} = normalize_schema(schema_without_flag)
      prop_name = key_to_string(name)

      acc = Map.put(acc, prop_name, normalized_schema)
      reqs = if required?, do: [prop_name | reqs], else: reqs

      {acc, reqs}
    end)
  end

  defp normalize_properties(other), do: {other, []}

  defp extract_required(%{} = schema) do
    cond do
      Map.has_key?(schema, :required) and is_boolean(schema[:required]) ->
        {schema[:required], Map.delete(schema, :required)}

      Map.has_key?(schema, "required") and is_boolean(schema["required"]) ->
        {schema["required"], Map.delete(schema, "required")}

      true ->
        {false, schema}
    end
  end

  defp extract_required(other), do: {false, other}

  defp key_to_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_to_string(key) when is_binary(key), do: key
  defp key_to_string(key), do: to_string(key)
end
