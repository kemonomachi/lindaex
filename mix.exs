defmodule LindaEx.Mixfile do
  use Mix.Project

  def project do
    [app: :lindaex,
     version: "0.9.0",
     elixir: "~> 1.0",
     name: "LindaEx",
     docs: [
       main: "LindaEx"
     ],
     source_url: "https://github.com/kemonomachi/lindaex",
     deps: deps]
  end

  def application do
    env = case Mix.env do
      :test ->
        [spaces: [:empty, :test]]
      _ ->
        [spaces: [:space]]
    end

    [applications: [:logger],
     mod: {LindaEx.Supervisor, []},
     env: env]
  end

  defp deps do
    [{:ex_doc, "~> 0.7", only: :dev}]
  end
end

