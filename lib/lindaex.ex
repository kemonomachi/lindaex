defmodule LindaEx.Supervisor do
  use Application

  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    children = Application.get_env(:lindaex, :spaces)
               |> Enum.map(fn(name) ->
                    worker LindaEx, [name], id: :"LindaEx.#{name}"
                  end)

    opts = [strategy: :one_for_one, name: __MODULE__]

    Supervisor.start_link children, opts
  end
end

