# Testing Matrix

This guide documents the matrix we now target when exercising Aquila against
tool-calling models. It covers both the LiteLLM proxy (our default integration)
and direct OpenAI connectivity so regressions in one path can be caught without
slipping through the other.

## Providers & Credentials

| Provider        | Env Vars                             | Default Base URL                | Notes |
|-----------------|--------------------------------------|---------------------------------|-------|
| LiteLLM Proxy   | `OPENAI_API_KEY`, `OPENAI_BASE_URL`  |         | Model names keep the `provider/model` prefix (e.g. `openai/gpt-5`). |
| OpenAI (direct) | `OPENAI_DIRECT_API_KEY`, `OPENAI_DIRECT_BASE_URL` (optional) | `https://api.openai.com/v1` | Model names drop the prefix (`gpt-5`, `gpt-4.1`, etc.). Falls back to `OPENAI_API_KEY_DIRECT` if provided. |

- Supply both API keys to record or replay every cassette in the matrix.
- Direct OpenAI credentials are mandatory for the suite; missing keys raise a
  descriptive failure so the gap can be fixed before recording or replaying.

## Tool Compatibility Coverage

| Provider        | Models Exercised                       | Endpoints       | Cassette Prefix                                    |
|-----------------|-----------------------------------------|-----------------|----------------------------------------------------|
| LiteLLM Proxy   | `openai/gpt-3.5-turbo`, `openai/gpt-4o`, `openai/gpt-4o-mini`, `openai/gpt-4.1[-mini]`, `openai/gpt-5[-mini]`, `openai/o3-mini`, Anthropic, Mistral, etc. | `:chat`, `:responses` (reasoning models use `:responses` only) | `tool_compat/<sanitized-model>/<endpoint>/{custom_function,parallel_calls,retry_tool}` |
| OpenAI (direct) | `gpt-4.1-mini`, `gpt-4.1`, `gpt-5-mini`, `gpt-5`, `o3-mini` | `:chat`, `:responses` (reasoning models `:responses` only) | `tool_compat/openai_direct/<sanitized-model>/<endpoint>/{custom_function,parallel_calls,retry_tool}` |

Each slot in the matrix now covers three scenarios:

- `custom_function` — baseline single tool call validation.
- `parallel_calls` — prompts triggering multiple calculator invocations to make sure we surface parallel tool use correctly.
- `retry_tool` — a flaky tool that fails once before succeeding, asserting our orchestration survives transient tool errors.

## Recording Strategy

1. Export both sets of credentials.

   ```bash
   export OPENAI_API_KEY="..."             # LiteLLM proxy key
   export OPENAI_BASE_URL="..."            # LiteLLM proxy URL
   export OPENAI_DIRECT_API_KEY="..."      # Direct OpenAI key
   export OPENAI_DIRECT_BASE_URL="https://api.openai.com/v1"
   ```

2. Re-record litellm fixtures (unchanged workflow):

   ```bash
   mix test test/integration/tool_compatibility_test.exs
   ```

3. Re-run the same command to record/refresh direct OpenAI cassettes. The
   harness writes them under `tool_compat/openai_direct/...`.

Because `Aquila.Transport.Record` normalises request bodies, the same call can
double as a live test run whenever you need to validate a fresh tool payload.
