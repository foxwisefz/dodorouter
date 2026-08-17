defmodule DodoRouter.MixProject do
  use Mix.Project

  def project do
    [
      app: :dodo_router,
      version: "0.1.75",
      # 1.18, not 1.15: `attesto_mcp` requires it, and the `attesto` libraries
      # under it call the `JSON` module that 1.18 introduced. Claiming 1.15
      # let CI pin an Elixir the app cannot actually run on.
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      # Phoenix 1.8.11 wants the code reloader registered as a Mix listener;
      # without it every dev request logs a warning with a stacktrace.
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {DodoRouter.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp releases do
    [
      dodo_router: [
        include_executables_for: [:unix],
        strip_beams: true,
        include_erts: true,
        applications: [sasl: :permanent],
        steps: [
          &Forecastle.pre_assemble/1,
          :assemble,
          &compile_appup/1,
          &Forecastle.post_assemble/1,
          :tar
        ]
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:bcrypt_elixir, "~> 3.0"},
      # SPIKE (dodo_router-5m5.5): verifying whether OAuth 2.1 is viable for the
      # MCP endpoint before committing to it. Remove if the answer is no.
      # Dev-only: required by `mix attesto_phoenix.install` scaffolding.
      {:igniter, "~> 0.5", only: [:dev], runtime: false},
      {:attesto, "~> 1.14"},
      {:attesto_phoenix, "~> 2.12"},
      {:attesto_mcp, "~> 1.1"},
      {:phoenix, "~> 1.8.1"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 0.26"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:logger_file_backend, "~> 0.0.14"},
      {:castle, "~> 0.3.1"},
      {:forecastle, "~> 0.1.3"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind dodo_router", "esbuild dodo_router"],
      "assets.deploy": [
        "tailwind dodo_router --minify",
        "esbuild dodo_router --minify",
        "phx.digest"
      ],
      precommit: [
        "compile --warning-as-errors",
        "migrations.check_versions",
        "deps.unlock --unused",
        "format",
        "test"
      ]
    ]
  end

  defp compile_appup(release) do
    if File.exists?("appup.ex") do
      {appup, _} = Code.eval_file("appup.ex")
      ebin = Path.join([release.path, "lib", "dodo_router-#{release.version}", "ebin"])
      File.mkdir_p!(ebin)
      File.write!(Path.join(ebin, "dodo_router.appup"), :io_lib.format("~tp.\n", [appup]))
    end

    release
  end
end
