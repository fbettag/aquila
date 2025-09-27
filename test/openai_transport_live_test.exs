key = System.get_env("OPENAI_API_KEY")

cond do
  is_binary(key) and String.trim(key) != "" ->
    defmodule Aquila.OpenAITransportLiveTest do
      use ExUnit.Case, async: false

      @moduletag :live

      setup do
        {:ok, api_key: System.get_env("OPENAI_API_KEY")}
      end

      test "direct transport completes", %{api_key: api_key} do
        response =
          Aquila.ask("Reply with the word coverage.",
            transport: Aquila.Transport.OpenAI,
            api_key: api_key,
            timeout: 60_000
          )

        assert String.contains?(String.downcase(response.text), "coverage")
      end

      test "stream emits delta events", %{api_key: api_key} do
        req = %{
          endpoint: :responses,
          url: "https://api.openai.com/v1/responses",
          headers: [
            {"authorization", "Bearer #{api_key}"},
            {"content-type", "application/json"}
          ],
          body: %{
            model: "gpt-4o-mini",
            input: [
              %{
                role: "user",
                content: [%{"type" => "input_text", "text" => "State the word coverage"}]
              }
            ],
            stream: true
          },
          opts: [receive_timeout: 60_000]
        }

        {:ok, agent} = Agent.start_link(fn -> [] end)
        on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent, :normal) end)

        callback = fn event -> Agent.update(agent, &[event | &1]) end

        assert {:ok, _ref} = Aquila.Transport.OpenAI.stream(req, callback)

        events = Agent.get(agent, &Enum.reverse/1)
        assert match?([_ | _], events)
        assert Enum.any?(events, &match?(%{type: :response_ref}, &1))
        assert Enum.any?(events, &match?(%{type: :delta}, &1))
        assert %{type: :done, status: :completed} = List.last(events)
      end

      test "post surfaces http errors", %{api_key: api_key} do
        req = %{
          endpoint: :responses,
          url: "https://api.openai.com/v1/responses",
          headers: [
            {"authorization", "Bearer #{api_key}"},
            {"content-type", "application/json"}
          ],
          body: %{model: "gpt-4o-mini", input: [], stream: true},
          opts: [receive_timeout: 5_000]
        }

        assert {:error, {:http_error, status, _body}} =
                 Aquila.Transport.OpenAI.post(%{
                   req
                   | headers: [{"authorization", "Bearer invalid"} | req.headers]
                 })

        assert status in 400..499
      end
    end

  true ->
    defmodule Aquila.OpenAITransportLiveTest do
      use ExUnit.Case, async: false

      @moduletag :live

      @tag skip: "OPENAI_API_KEY not set; run with mix test --include live after exporting it"
      test "skipped – OPENAI_API_KEY not configured" do
        assert true
      end
    end
end
