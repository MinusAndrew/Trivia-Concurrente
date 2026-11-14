defmodule Trivia.Application do
  @moduledoc """
  Punto de entrada de la aplicación OTP.

  Inicia `Trivia.Supervisor` únicamente cuando el nodo actúa en rol `:server`.
  Los nodos cliente (`iex --sname pedro -S mix`, `TRIVIA_ROLE=client`, etc.) no
  levantan su propio servidor central (sección 8.2).
  """
  use Application

  @impl true
  def start(_type, _args) do
    children =
      case resolver_rol() do
        :server -> [{Trivia.Supervisor, []}]
        _ -> []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: Trivia.AppSupervisor)
  end

  @doc """
  Determina el rol del nodo actual (`:server`, `:client` o `:none`).
  """
  def resolver_rol(nodo \\ Node.self(), env_role \\ System.get_env("TRIVIA_ROLE")) do
    config_role = Application.get_env(:trivia, :role, :none)

    cond do
      env_role in ["server", "servidor"] ->
        :server

      env_role in ["client", "cliente", "none"] ->
        :client

      config_role == :none ->
        :none

      nodo != :nonode@nohost ->
        nombre_corto =
          nodo
          |> Atom.to_string()
          |> String.split("@")
          |> List.first("")
          |> String.downcase()

        if String.starts_with?(nombre_corto, "servidor") or
             String.starts_with?(nombre_corto, "server") do
          :server
        else
          :client
        end

      true ->
        config_role
    end
  end
end
