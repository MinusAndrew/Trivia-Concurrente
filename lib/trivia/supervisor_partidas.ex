defmodule Trivia.SupervisorPartidas do
  @moduledoc """
  DynamicSupervisor para gestionar los procesos independientes de cada partida (`Trivia.Partida`).

  Cada partida es supervisada individualmente con estrategia `:one_for_one` y
  estrategia de reinicio `restart: :transient` (las partidas terminadas normalmente
  no se reinician; las partidas que terminan por falla o choque son reiniciadas
  automáticamente con sus argumentos iniciales).
  """
  use DynamicSupervisor

  @max_reinicios 100
  @ventana_reinicios_s 5

  @doc """
  Inicia el DynamicSupervisor de partidas.

  Opciones: `:name`, `:max_restarts` (por defecto #{@max_reinicios}) y
  `:max_seconds` (por defecto #{@ventana_reinicios_s}).
  """
  def start_link(init_arg \\ []) do
    {name, opts} = Keyword.pop(init_arg, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    # El presupuesto de reinicios es compartido por todas las partidas: con los
    # valores por defecto (3 en 5 s) unas pocas fallas seguidas tumbarían a todas.
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: Keyword.get(opts, :max_restarts, @max_reinicios),
      max_seconds: Keyword.get(opts, :max_seconds, @ventana_reinicios_s)
    )
  end

  @doc """
  Inicia un proceso supervisado para una nueva partida con los argumentos dados.
  """
  def iniciar_partida(supervisor \\ __MODULE__, args) do
    child_spec = {Trivia.Partida, args}
    DynamicSupervisor.start_child(supervisor, child_spec)
  end

  @doc """
  Termina y desasocia una partida supervisada.
  """
  def terminar_partida(supervisor \\ __MODULE__, pid) do
    DynamicSupervisor.terminate_child(supervisor, pid)
  end

  @doc """
  Retorna la lista de PIDs de partidas hijas actualmente supervisadas.
  """
  def listar_hijos(supervisor \\ __MODULE__) do
    DynamicSupervisor.which_children(supervisor)
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.filter(fn pid -> is_pid(pid) end)
  end
end
