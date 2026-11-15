defmodule Mix.Tasks.Trivia.Servidor do
  @shortdoc "Inicia el servidor de Trivia Concurrente en un nodo distribuido"

  @moduledoc """
  Inicia el servidor de Trivia Concurrente sin abrir IEx.

      mix trivia.servidor [--nombre servidor] [--cookie trivia] [--datos data]

  Opciones:

    * `--nombre` – nombre corto del nodo (por defecto `servidor`).
    * `--cookie` – cookie compartida con los clientes (por defecto `trivia`).
    * `--datos` – directorio de `questions.json`, `users.json` y `results.log`
      (por defecto `data`).
    * `--help` – muestra esta ayuda.

  Equivale a `iex --sname servidor --cookie trivia -S mix`. El servidor queda
  en marcha hasta que se detiene con Ctrl+C dos veces.
  """
  use Mix.Task

  alias Trivia.CLI

  @impl Mix.Task
  def run(argv) do
    case CLI.opciones_servidor(argv) do
      {:ok, opciones} -> iniciar(opciones)
      :ayuda -> Mix.shell().info(@moduledoc)
      {:error, mensaje} -> Mix.raise(mensaje)
    end
  end

  defp iniciar(opciones) do
    # Cargar la configuración antes de ajustarla: app.start no la vuelve a cargar
    Mix.Task.run("app.config")

    if opciones.datos do
      Application.put_env(:trivia, :data_dir, Path.expand(opciones.datos))
    end

    System.put_env("TRIVIA_ROLE", "server")

    nodo =
      case CLI.iniciar_nodo(opciones.nombre, opciones.cookie) do
        {:ok, nodo} -> nodo
        {:error, mensaje} -> Mix.raise(mensaje)
      end

    Mix.Task.run("app.start")

    Mix.shell().info("""
    Servidor de Trivia Concurrente en marcha.
      Nodo  : #{nodo}
      Cookie: #{opciones.cookie}
      Datos : #{Application.get_env(:trivia, :data_dir)}

    Para conectar un jugador, en otra terminal:
      mix trivia.cliente --servidor #{nodo}

    Detén el servidor con Ctrl+C dos veces.
    """)

    Process.sleep(:infinity)
  end
end
