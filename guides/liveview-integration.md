# LiveView Integration

Phoenix LiveView remains a popular way to present streamed AI output. Aquila
does not depend on Phoenix, but its streaming API slots neatly into LiveView’s
async helpers. This guide walks through the recommended wiring using
`start_async/3`, `handle_async/3`, and the testing conveniences they unlock.

## Prerequisites

- Phoenix 1.7+ and Phoenix LiveView 0.20+ in *your* application’s dependencies.
- An Aquila configuration (see [Getting Started](getting-started.md)).
- Optional: cassette recording enabled to keep tests deterministic (see
  [Cassette Recording & Testing](cassettes-and-testing.md)).

Add LiveView packages to `mix.exs` if they are not already present:

```elixir
{:phoenix, "~> 1.7"},
{:phoenix_live_view, "~> 0.20"},
{:phoenix_html, "~> 4.0"},
{:phoenix_pubsub, "~> 2.1"}
```

## Streaming with `start_async/3`

Use LiveView’s async lifecycle to coordinate streaming and make your code easy
to test. The pattern is:

1. Generate a unique stream reference.
2. Start the stream from within `start_async/3`, forwarding Aquila events back
   to the LiveView process via `Aquila.Sink.pid/1` and blocking until the final
   message arrives.
3. Update assigns incrementally in `handle_info/2` when chunks arrive.
4. Finalise the conversation inside `handle_async/3` once the async task returns.

```elixir
defmodule MyAppWeb.ChatLive do
  use MyAppWeb, :live_view
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, messages: [], response: "", stream_ref: nil, loading?: false)}
  end

  @impl true
  def handle_event("send", %{"prompt" => prompt}, %{assigns: %{loading?: true}} = socket),
    do: {:noreply, socket}

  def handle_event("send", %{"prompt" => prompt}, socket) do
    ref = make_ref()

    socket =
      socket
      |> assign(loading?: true, stream_ref: ref, response: "")
      |> update(:messages, &(&1 ++ [%{role: :user, content: prompt}]))

    {:noreply,
     start_async(socket, :stream, fn ->
       {:ok, ^ref} = Aquila.stream(prompt, sink: Aquila.Sink.pid(self()), ref: ref)
       await_completion(ref)
     end)}
  end

  @impl true
  def handle_info({:aquila_chunk, chunk, ref}, %{assigns: %{stream_ref: ref}} = socket) do
    {:noreply, update(socket, :response, &(&1 <> chunk))}
  end

  def handle_info({:aquila_chunk, _chunk, _ref}, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:aquila_done, text, meta, ref}, %{assigns: %{stream_ref: ref}} = socket) do
    {:noreply, finalize(socket, text, meta)}
  end

  def handle_info({:aquila_error, reason, ref}, %{assigns: %{stream_ref: ref}} = socket) do
    {:noreply, stream_failed(socket, reason)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:stream, {:ok, {:done, ref, text, meta}}, %{assigns: %{stream_ref: ref}} = socket) do
    {:noreply, finalize(socket, text, meta)}
  end

  def handle_async(:stream, {:ok, {:error, ref, reason}}, %{assigns: %{stream_ref: ref}} = socket) do
    {:noreply, stream_failed(socket, reason)}
  end

  def handle_async(:stream, {:exit, reason}, socket) do
    {:noreply, stream_failed(socket, {:exit, reason})}
  end

  defp finalize(socket, text, meta) do
    messages =
      socket.assigns.messages ++
        [%{role: :assistant, content: text, meta: meta}]

    socket
    |> assign(messages: messages, response: "", loading?: false, stream_ref: nil)
  end

  defp stream_failed(socket, reason) do
    Logger.error("Aquila stream failed", reason: inspect(reason))

    socket
    |> assign(loading?: false, stream_ref: nil)
    |> update(:messages, &(&1 ++ [%{role: :assistant, content: "Something went wrong."}]))
  end

  defp await_completion(ref) do
    receive do
      {:aquila_done, text, meta, ^ref} -> {:done, ref, text, meta}
      {:aquila_error, reason, ^ref} -> {:error, ref, reason}
      _other -> await_completion(ref)
    after
      120_000 -> {:error, ref, :timeout}
    end
  end
end
```

Render whatever shape you prefer in HEEx. A minimal example:

```heex
<.form for={:prompt} id="prompt-form" phx-submit="send">
  <.input name="prompt" label="Prompt" />
  <.button type="submit" disabled={@loading?}>Send</.button>
</.form>

<div id="chat-output">
  <p :for={message <- @messages}><%= message.content %></p>
  <p :if={@response != ""}><%= @response %></p>
</div>
```

### LiveComponents

LiveComponents can adopt the same approach: use `start_async/3`, pass the parent
PID to `Aquila.stream/2`, and implement `handle_async/3` to consolidate the
final response. Because components share the parent’s process, events delivered
via `Aquila.Sink.pid(assigns.parent_pid)` remain in-process and do not require
additional PubSub wiring.

## Testing LiveView streams

Async-aware tests become straightforward once the LiveView uses `start_async/3`.
Trigger the event and then wait for completion with
`Phoenix.LiveViewTest.render_async/1`:

```elixir
defmodule MyAppWeb.ChatLiveTest do
  use MyAppWeb.ConnCase
  use Aquila.Cassette
  import Phoenix.LiveViewTest

  test "renders streamed response", %{conn: conn} do
    aquila_cassette "chat_live.responds" do
      {:ok, lv, _html} = live(conn, ~p"/chat")

      lv
      |> form("#prompt-form", prompt: %{content: "Hello"})
      |> render_submit()

      assert render_async(lv) =~ "Hello"
    end
  end
end
```

`render_async/1` waits for any `start_async` jobs to finish before rendering the
view, replacing ad-hoc polling or sleeps. When the LiveView pushes messages or
browser events (downloads, flashes, etc.) you can pair it with
`assert_push_event/4` and `assert_flash/3` for deterministic verification.

## Tips

- The metadata in `{:aquila_done, _text, meta, ref}` (or the tuple returned by
  `await_completion/1`) is a convenient place to persist conversation IDs or
  usage metrics.
- Use `temporary_assigns` to cap memory when rendering long transcripts.
- When tracking multiple concurrent conversations, store a map of `ref => state`
  in the socket assigns and branch on each incoming message’s reference.
- If you model the conversation in a LiveComponent, use `send_update/2` from the
  parent LiveView to forward `:aquila_*` events to the component while keeping
  all async orchestration in one place.
