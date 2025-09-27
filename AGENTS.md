# Repository Guidelines

## Project Structure & Module Organization
- `lib/` contains the Aquila runtime modules, including the public API (`aquila.ex`), transports, and engine logic.
- `test/` holds ExUnit suites plus cassette fixtures under `test/support/fixtures/aquila_cassettes/` for deterministic replay.
- `guides/` and `README.md` provide contributor-facing documentation; update them when the public API changes.
- `config/` manages Mix environments; `config/test.exs` pins the recorder transport and cassette directory.

## Build, Test, and Development Commands
- `mix deps.get` – fetch Elixir dependencies.
- `mix compile` – compile the library and surface any warnings.
- `mix test` – run the full ExUnit suite (cassette-backed tests included).
- `OPENAI_API_KEY=... mix test test/responses_retrieval_test.exs` – re-record live Responses fixtures.
- `mix coveralls` – execute tests with coverage enforcement (fails <82%).
- `mix deps.unlock --unused` – prune unused deps when altering `mix.exs`.

## Coding Style & Naming Conventions
- Use the default Elixir formatter (`mix format`) before committing; the project follows Elixir’s two-space indentation and snake_case module files.
- Module names are PascalCase (e.g., `Aquila.Transport.OpenAI`); private helpers stay in `defp`.
- Keep comments purposeful—explain non-obvious logic, not language syntax.

## Testing Guidelines
- ExUnit is the primary framework; tests live alongside their target modules (e.g., `test/transport_*`).
- Name tests descriptively using double-quoted strings; group related cases with `describe` blocks.
- Maintain ≥82% coverage via `mix coveralls`; add unit stubs or cassette-backed integration tests when introducing new behaviour.
- Record fresh cassettes whenever prompt payloads or transport semantics change.

## Commit & Pull Request Guidelines
- Write commits in the imperative mood (e.g., `Add retrieval helper`) and keep the subject under ~72 characters.
- Reference relevant issues in the body when applicable; group mechanical changes (formatting, deps) separately from functional work.
- Pull requests should call out API changes, updated guides, new cassettes, and any required environment variables. Include reproduction steps or screenshots for developer tooling updates.
