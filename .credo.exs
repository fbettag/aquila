%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "guides/", "mix.exs"],
        excluded: ["_build/", "deps/"]
      },
      strict: false,
      checks: %{
        enabled: [
          {Credo.Check.Design.DuplicatedCode, []},
          {Credo.Check.Design.TagTODO, []}
        ]
      }
    }
  ]
}
