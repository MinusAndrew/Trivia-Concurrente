defmodule Mix.Tasks.Trivia.Servidor do
  @shortdoc "Inicia el servidor de Trivia Concurrente en un nodo distribuido"

  @moduledoc """
  Inicia el servidor de Trivia Concurrente sin abrir IEx.

      mix trivia.servidor [--nombre servidor] [--cookie trivia] [--datos data]
      mix trivia.servidor --publico [--host ip_o_dominio] [--puerto 9100] ...

  Opciones:

    * `--nombre` – nombre del nodo (por defecto `servidor`).
    * `--cookie` – cookie compartida con los clientes (por defecto `trivia`;
      en modo red, una aleatoria).
    * `--datos` – directorio de `questions.json`, `users.json` y `results.log`
      (por defecto `data`).
    * `--publico` – modo red: acepta jugadores de otras máquinas (LAN o
      Internet con redirección de puertos).
    * `--host` – IP o dominio con que los jugadores llegan a esta máquina
      (implica `--publico`; por defecto la IP local).
    * `--puerto` – único puerto TCP que usa el modo red (por defecto `9100`).
    * `--help` – muestra esta ayuda.

  Sin `--publico` equivale a `iex --sname servidor --cookie trivia -S mix`. El
  servidor queda en marcha hasta que se detiene con Ctrl+C dos veces.
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
      case CLI.iniciar_nodo(opciones.nombre, opciones.cookie, red(opciones)) do
        {:ok, nodo} -> nodo
        {:error, mensaje} -> Mix.raise(mensaje)
      end

    Mix.Task.run("app.start")

    Mix.shell().info("""
    Servidor de Trivia Concurrente en marcha.
      Nodo  : #{nodo}
      Cookie: #{opciones.cookie}
      Datos : #{Application.get_env(:trivia, :data_dir)}
    #{instrucciones_conexion(nodo, opciones)}
    Detén el servidor con Ctrl+C dos veces.
    """)

    Process.sleep(:infinity)
  end

  defp red(%{red: nil}), do: nil
  defp red(%{red: red}), do: Map.put(red, :rol, :servidor)

  defp instrucciones_conexion(nodo, %{red: nil}) do
    """

    Para conectar un jugador, en otra terminal:
      mix trivia.cliente --servidor #{nodo}
    """
  end

  defp instrucciones_conexion(nodo, %{red: %{puerto: puerto}, cookie: cookie}) do
    opcion_puerto = if puerto == 9100, do: "", else: " --puerto #{puerto}"

    """
      Puerto: #{puerto} (TCP)

    Para conectar un jugador desde cualquier máquina con el proyecto:
      mix trivia.cliente --servidor #{nodo} --cookie #{cookie}#{opcion_puerto}

    Para jugadores fuera de esta red, redirige en el router el puerto TCP
    #{puerto} hacia esta máquina (y también el 4369 si algún jugador usa
    Erlang/OTP anterior a 27.2). Comparte la cookie solo con quien deba jugar:
    da acceso completo a este nodo.
    """
  end
end
