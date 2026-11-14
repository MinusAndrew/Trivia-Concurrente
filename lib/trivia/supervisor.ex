defmodule Trivia.Supervisor do
  @moduledoc """
  Supervisor principal para el rol de servidor.

  Inicia y supervisa bajo la estrategia `:one_for_one`:
    1. `Trivia.Persistencia`: Acceso centralizado a archivos de datos.
    2. `Trivia.SupervisorPartidas`: DynamicSupervisor para partidas independientes.
    3. `Trivia.GestorPartidas`: GenServer de gestión y coordinación de partidas.
    4. `Trivia.GestorJugadores`: GenServer de sesiones, autenticación y estadísticas.
    5. `Trivia.Servidor`: Punto de entrada remoto para peticiones de clientes.
  """
  use Supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(init_arg) do
    data_dir =
      Keyword.get(init_arg, :data_dir) ||
        Application.get_env(:trivia, :data_dir, default_data_dir())

    children = [
      {Trivia.Persistencia, data_dir: data_dir},
      Trivia.SupervisorPartidas,
      Trivia.GestorPartidas,
      Trivia.GestorJugadores,
      Trivia.Servidor
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp default_data_dir do
    Path.expand("data")
  end
end
