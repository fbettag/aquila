# LiveView Integration

Phoenix LiveView remains a popular way to present streamed AI output.
Although Aquila no longer ships Phoenix or LiveView as dependencies, the
streaming API meshes neatly with LiveView’s message handling. This guide
walks through the wiring required inside your own Phoenix app.

## Prerequisites

- Phoenix 1.7+ with LiveView 0.20+ added to *your* application’s `mix.exs`.
- A running Aquila configuration (see [Getting Started](getting-started.md)).
- Optional: cassette recording enabled to keep LiveView tests deterministic.

Add the LiveView packages to your project if they are not already present:

```elixir
{:phoenix, "~> 1.7"},
{:phoenix_live_view, "~> 0.20"},
{:phoenix_html, "~> 4.0"},
{:phoenix_pubsub, "~> 2.1"}
```

## Streaming in a LiveView

LiveView receives chunks through the regular mailbox. Capture the stream
reference when you call `Aquila.stream/2` and update assigns as messages
arrive.

```elixir
defmodule MyAppWeb.ChatLive do
  use MyAppWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, messages: [], stream_ref: nil, loading?: false)}
  end

  def handle_event("send", %{"prompt" => prompt}, socket) do
    {:ok, ref} =
      Aquila.stream(prompt,
        sink: Aquila.Sink.pid(self()),
        instruction: socket.assigns[:instruction]
      )

    {:noreply, assign(socket, loading?: true, stream_ref: ref, messages: socket.assigns.messages ++ [""])}
  end

  def handle_info({:aquila_chunk, chunk, ref}, %{assigns: %{stream_ref: ref}} = socket) do
    {:noreply, update(socket, :messages, &List.update_at(&1, -1, fn text -> text <> chunk end))}
  end

  def handle_info({:aquila_done, text, _meta, ref}, %{assigns: %{stream_ref: ref}} = socket) do
    {:noreply, socket |> assign(loading?: false, stream_ref: nil) |> update(:messages, &List.replace_at(&1, -1, text))}
  end

  def handle_info({:aquila_error, reason, ref}, %{assigns: %{stream_ref: ref}} = socket) do
    Logger.error("stream failed", reason: inspect(reason))
    {:noreply, socket |> assign(loading?: false, stream_ref: nil)}
  end
end
```

Render the messages in your `.heex` template:

```heex
<.form for={:prompt} phx-submit="send">
  <.input name="prompt" label="Prompt" phx-debounce="300" />
  <.button type="submit" disabled={@loading?}>Send</.button>
</.form>

<div id="chat-output">
  <%= for message <- @messages do %>
    <p><%= message %></p>
  <% end %>
</div>
```

## Testing LiveView Streams

Push the stream through `Aquila.Sink.collector/1` when running LiveView tests.
Pair it with cassette recording so the streamed content is deterministic.

```elixir
defmodule MyAppWeb.ChatLiveTest do
  use MyAppWeb.ConnCase
  import Phoenix.LiveViewTest

  test "renders streamed tokens", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/chat")

    render_submit(lv, "send", %{"prompt" => "Hello"})

    assert eventually(fn -> render(lv) =~ "Hello" end)
  end

  defp eventually(fun, attempts \\ 5)
  defp eventually(fun, 0), do: raise "expected condition to succeed"
  defp eventually(fun, attempts) do
    case fun.() do
      true -> true
      _ -> Process.sleep(50); eventually(fun, attempts - 1)
    end
  end
end
```

Because Aquila does not depend on Phoenix, remember to start the required
endpoint and PubSub modules in your test support.

## Tips

- Use the metadata returned in `{:aquila_done, _text, meta, ref}` to annotate
  session history or log usage statistics.
- Combine streaming with LiveView temporary assigns when rendering long logs
  to keep memory usage predictable.
- When you need multiple simultaneous streams per LiveView, track each stream
  reference separately and route updates based on the `ref` in each tuple.
