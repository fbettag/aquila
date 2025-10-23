# Overview

`Aquila` is a minimal Elixir interface for OpenAI-compatible Responses and Chat
Completions endpoints. The library covers both synchronous and streaming
workflows behind a unified prompt API and tool orchestration loop, and it fits
cleanly inside background processors such as Oban without any custom wrappers.

> Why “Aquila”? Aquila is Latin for *eagle*—a nod to the project’s goal of
> providing sharp vision over AI responses while matching the mythological
> tone of Phoenix in the Elixir ecosystem.

## Design Principles

- **Transport agnostic** – production code talks to the `Aquila.Transport`
  behaviour, making it easy to swap real HTTP calls for cassette-backed
  replays in tests.
- **Prompt integrity** – cassette metadata stores canonical request bodies so
  mismatched prompts fail fast and guide you toward re-recording.
- **Streaming first** – even synchronous calls use streaming under the hood,
  enabling telemetry and consistent sink handling.
- **Minimal surface area** – modules focus on a single role (messages,
  endpoint helpers, sinks, transports) and are documented to encourage
  direct re-use in bespoke integrations.
- **Live context pivots** – the Responses API support for
  `previous_response_id` lets you pivot instructions mid-conversation while
  keeping history intact.
- **Managed storage optionality** – the `store` flag rides along with the
  Responses API so you can persist or discard output intentionally, and the
  public API exposes helpers to retrieve or delete stored conversations on
  demand.

## Prerequisites

- Elixir 1.15 or newer with Mix.
- An OpenAI-compatible API key. Configure it in `config/runtime.exs` as shown
  in the [Getting Started](getting-started.md#install-and-configure) guide.
- Optional: [Credo](code-quality.md) if you want linting in development.

## Key Modules

- `Aquila` – developer-facing API for `ask/2`, `stream/2`,
  `retrieve_response/2`, `delete_response/2`, `transcribe_audio/2`, and
  `deep_research_*` helpers.
- `Aquila.Engine` – internal orchestrator that normalises events, manages tool
  invocations, and reports telemetry.
- `Aquila.Transport.*` – adapters for real HTTP (`OpenAI`), auto-recording
  (`Record`), and deterministic playback (`Replay`).
- `Aquila.Sink` – helpers for pushing streaming events to processes or callback
  functions.

## Feature Matrix

| Capability | Module(s) | Notes |
| --- | --- | --- |
| Sync calls | `Aquila`, `Aquila.Engine` | Buffers streamed chunks into `%Aquila.Response{}` |
| Streaming | `Aquila`, `Aquila.Sink` | Emits chunks/events to configurable sinks |
| Tool loop | `Aquila.Engine`, `Aquila.Tool` | Supports JSON tool schema + local execution |
| Prompt verification | `Aquila.Transport.Record`, `Aquila.Transport.Replay` | Cassettes fail when prompts diverge |
| Background jobs | Oban | Call `Aquila.ask/2` from your existing workers |
| Process/UI integration | `Aquila.Sink`, `Aquila.Engine` | Forward sink events to controllers, GenServers, or custom processes |
| Response storage | `Aquila`, `Aquila.Engine` | `store: true` persists Responses output |
| Retrieve/delete stored responses | `Aquila`, `Aquila.Transport.Record` | Helpers fetch and purge stored conversations, recorder tracks GET/DELETE |
| Audio transcription | `Aquila` | `transcribe_audio/2` posts multipart payloads to `/audio/transcriptions` |

## Multi-Provider Access via LiteLLM

When your application needs to reach beyond OpenAI, pair this library with
[LiteLLM](https://docs.litellm.ai/docs/) acting as a drop-in OpenAI-compatible
gateway. LiteLLM translates requests into each provider’s native API while
preserving the OpenAI Responses and Chat formats we already support, so
fallbacks and cassette recording keep working no matter which upstream model
you target.

## Where To Go Next

- Read the [Getting Started](getting-started.md) guide for configuration and
  first requests.
- Explore [Streaming and Sinks](streaming-and-sinks.md) to wire chunks into
  UI layers or background consumers.
- Follow [LiveView Integration](liveview-integration.md) for real-time UI
  examples using Phoenix LiveView.
- Queue work with [Oban Integration](oban-integration.md) to run Aquila
  requests in background jobs.
- Learn how the cassette recorder keeps prompts honest in
  [Cassette Recording & Testing](cassettes-and-testing.md).
