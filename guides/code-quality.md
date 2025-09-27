# Code Quality

Keeping the library healthy requires only a light amount of tooling. Credo is
still the go-to static analysis tool for Elixir projects and works nicely
alongside Mix formatting. This project ships with a focused `.credo.exs`
profile so you can adopt linting without extra setup.

## Credo Setup

Add the dependency in `mix.exs` with the `:dev` and `:test` environments so it
never ships in production builds:

```elixir
{:credo, "~> 1.7", only: [:dev, :test], runtime: false}
```

Fetch dependencies (`mix deps.get`) and you are ready to run Credo using the
included configuration. The default rules already check for:

- Code readability issues (naming, module docs, cyclomatic complexity)
- Readability and design hints such as `TooManyArguments` and `LargeNumbers`
- Consistent documentation coverage via `Credo.Check.Readability.ModuleDoc`

The provided `.credo.exs` enables the optional `Refactor.Duplication` and
`Design.TagTODO` checks for additional guard rails without excessive noise.

Run Credo as part of your development loop:

```shell
mix credo
mix credo --strict  # once the codebase is in good shape
```

The project ships with a convenience alias that bundles formatting and Credo:

```shell
mix quality
```

## Formatting and Dialyzer

Pair Credo with `mix format` to keep the codebase tidy:

```shell
mix format
```

For teams that require gradual type checking, add `dialyxir` later. The
recorder and streaming stack already expose typed public APIs, so dialyzer can
lock in those guarantees if you choose to adopt it.

## Continuous Integration

- Run `mix credo` in CI before the test suite to fail fast on lint issues.
- Store cassette files in version control so CI never hits the network.
- Surface Credo output in Pull Request annotations when your platform
  supports it (e.g. GitHub Actions with the reviewdog integration).
