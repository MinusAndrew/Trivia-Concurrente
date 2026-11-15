defmodule Mix.Tasks.Trivia.Cliente do
  @shortdoc "Abre la consola de un jugador conectada al servidor de Trivia Concurrente"

  @moduledoc """
  Abre la consola interactiva de un jugador sin abrir IEx.

      mix trivia.cliente [--nombre pedro] [--servidor servidor] [--cookie trivia]
      mix trivia.cliente --servidor servidor@203.0.113.5 --cookie <cookie> [--puerto 9100]

  Opciones:

    * `--nombre` – nombre del nodo del jugador (por defecto uno aleatorio,
      `jugador_<n>`, para poder abrir varios clientes en la misma máquina).
    * `--servidor` – nodo del servidor: `nombre` (se completa con el host de esta
      máquina) o `nombre@host` (por defecto `servidor`). Si el host es una IP o
      un dominio, el cliente usa el modo red para conectarse desde otra máquina.
    * `--cookie` – cookie compartida con el servidor (por defecto `trivia`).
    * `--puerto` – puerto del servidor en modo red (por defecto `9100`).
    * `--help` – muestra esta ayuda.

  Equivale a `iex --sname pedro --cookie trivia -S mix` seguido de
  `Trivia.Cliente.iniciar(:"servidor@host")`. El nombre del nodo no es el
  usuario del juego: el usuario se indica con `connect <usuario> <clave>`.
  """
  use Mix.Task

  alias Trivia.CLI

  @impl Mix.Task
  def run(argv) do
    case CLI.opciones_cliente(argv, CLI.host_local()) do
      {:ok, opciones} -> iniciar(opciones)
      :ayuda -> Mix.shell().info(@moduledoc)
      {:error, mensaje} -> Mix.raise(mensaje)
    end
  end

  defp iniciar(opciones) do
    Mix.Task.run("app.config")
    # Un nodo cliente nunca levanta su propio servidor
    System.put_env("TRIVIA_ROLE", "client")

    red = if opciones.red, do: Map.put(opciones.red, :rol, :cliente)

    case CLI.iniciar_nodo(opciones.nombre, opciones.cookie, red) do
      {:ok, _nodo} -> :ok
      {:error, mensaje} -> Mix.raise(mensaje)
    end

    Mix.Task.run("app.start")

    if Node.connect(opciones.servidor) != true do
      Mix.shell().error(
        "Aviso: no se pudo conectar con #{opciones.servidor}. Verifica que el servidor " <>
          "esté en marcha y que la cookie coincida; los comandos fallarán hasta entonces."
      )
    end

    Trivia.Cliente.iniciar(opciones.servidor)
  end
end
