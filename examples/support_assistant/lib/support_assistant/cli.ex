defmodule SupportAssistant.CLI do
  @moduledoc "Runs offline by default; --live explicitly enables a paid model request."
  def main(args) do
    {options, words, _} = OptionParser.parse(args, strict: [live: :boolean])
    question = if words == [], do: "What is the refund policy?", else: Enum.join(words, " ")

    opts =
      if options[:live] do
        [api_key: System.fetch_env!("OPENAI_API_KEY"), model: System.fetch_env!("OPENAI_MODEL")]
      else
        [
          transport: SupportAssistant.DemoTransport,
          api_key: "offline-demo",
          model: "offline-demo"
        ]
      end

    case SupportAssistant.stream(question, opts) do
      {:ok, ref} -> await(ref)
      {:error, reason} -> raise "Could not start assistant: #{inspect(reason)}"
    end
  end

  defp await(ref) do
    receive do
      {:aquila_chunk, text, ^ref} ->
        IO.write(text)
        await(ref)

      {:aquila_done, _text, _meta, ^ref} ->
        IO.puts("")

      {:aquila_error, reason, ^ref} ->
        raise "Assistant failed: #{inspect(reason)}"

      _event ->
        await(ref)
    after
      30_000 -> raise "Assistant timed out; no action was taken"
    end
  end
end
