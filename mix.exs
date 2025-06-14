defmodule PlugLoggerJson.Mixfile do
  use Mix.Project

  def project do
    [
      app: :plug_logger_json,
      build_embedded: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [
        plt_add_deps: true
      ],
      description: "Elixir Plug that formats http request logs as json",
      docs: [extras: ["README.md"]],
      elixir: "~> 1.15",
      homepage_url: "https://github.com/bleacherreport/plug_logger_json",
      name: "Plug Logger JSON",
      package: package(),
      preferred_cli_env: [coveralls: :test, "coveralls.detail": :test, "coveralls.post": :test, "coveralls.html": :test],
      source_url: "https://github.com/bleacherreport/plug_logger_json",
      start_permanent: Mix.env() == :prod,
      test_coverage: [tool: ExCoveralls],
      version: "0.9.0"
    ]
  end

  def application do
    [applications: [:logger, :plug, :jason]]
  end

  defp deps do
    [
      {:jason, "~> 1.4", runtime: true},
      {:credo, "~> 1.7", only: [:dev]},
      {:dialyxir, "~> 1.4", only: [:dev]},
      {:earmark, "~> 1.4", only: [:dev]},
      {:earmark_parser, "~> 1.4.39", only: [:dev]},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false, warn_if_outdated: true},
      {:makeup, "~> 1.2", only: :dev, runtime: false},
      {:makeup_elixir, ">= 0.0.0", only: :dev, runtime: false},
      {:makeup_html, ">= 0.0.0", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: [:test]},
      {:plug, "~> 1.18"}
    ]
  end

  defp package do
    [
      files: ["lib", "mix.exs", "README*", "LICENSE*"],
      licenses: ["Apache 2.0"],
      links: %{"GitHub" => "https://github.com/bleacherreport/plug_logger_json"},
      maintainers: ["John Kelly, Ben Marx"]
    ]
  end
end
