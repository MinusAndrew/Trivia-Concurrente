defmodule Trivia.CLI do
  @moduledoc """
  Funciones compartidas por las tareas `mix trivia.servidor` y `mix trivia.cliente`.

  El análisis de opciones es puro (se puede probar sin levantar nodos); el
  arranque del nodo distribuido queda en `iniciar_nodo/2`.
  """

  @nombre_servidor "servidor"
  @cookie "trivia"
  @nombre_valido ~r/^[A-Za-z0-9_-]+$/

  @doc """
  Analiza los argumentos de `mix trivia.servidor`.

  Retorna `{:ok, %{nombre: _, cookie: _, datos: _ | nil}}`, `:ayuda` o
  `{:error, mensaje}`.
  """
  def opciones_servidor(argv) do
    con_opciones(argv, [nombre: :string, cookie: :string, datos: :string], fn opts ->
      with {:ok, nombre} <- validar_nombre(Keyword.get(opts, :nombre, @nombre_servidor)),
           {:ok, cookie} <- validar_cookie(Keyword.get(opts, :cookie, @cookie)) do
        {:ok, %{nombre: nombre, cookie: cookie, datos: Keyword.get(opts, :datos)}}
      end
    end)
  end

  @doc """
  Analiza los argumentos de `mix trivia.cliente`. `host` es el host corto de
  esta máquina y se usa para completar el nodo del servidor cuando no se indica.

  Retorna `{:ok, %{nombre: _, cookie: _, servidor: nodo}}`, `:ayuda` o
  `{:error, mensaje}`. Sin `--nombre` se genera uno aleatorio (`jugador_<n>`)
  para que varios clientes en la misma máquina no choquen.
  """
  def opciones_cliente(argv, host) do
    con_opciones(argv, [nombre: :string, cookie: :string, servidor: :string], fn opts ->
      nombre_por_defecto = "jugador_#{:rand.uniform(9000) + 999}"

      with {:ok, nombre} <- validar_nombre(Keyword.get(opts, :nombre, nombre_por_defecto)),
           {:ok, cookie} <- validar_cookie(Keyword.get(opts, :cookie, @cookie)),
           {:ok, servidor} <- nodo_servidor(Keyword.get(opts, :servidor, @nombre_servidor), host) do
        {:ok, %{nombre: nombre, cookie: cookie, servidor: servidor}}
      end
    end)
  end

  @doc """
  Host corto de esta máquina, tal como aparece en los nombres de nodo `--sname`.
  """
  def host_local do
    if Node.alive?() do
      node() |> Atom.to_string() |> String.split("@") |> List.last()
    else
      {:ok, host} = :inet.gethostname()
      host |> to_string() |> String.split(".") |> hd()
    end
  end

  @doc """
  Convierte este proceso de Mix en el nodo distribuido `nombre@host` con la
  cookie indicada. Si el nodo ya es distribuido (p. ej. se lanzó con
  `elixir --sname ...`), conserva su nombre y solo fija la cookie.
  """
  def iniciar_nodo(nombre, cookie) do
    resultado =
      if Node.alive?() do
        {:ok, node()}
      else
        iniciar_epmd()

        # Node.start/3 existe tanto en Elixir 1.17 como en versiones recientes
        case Node.start(String.to_atom(nombre), :shortnames, 15_000) do
          {:ok, _pid} -> {:ok, node()}
          {:error, _motivo} -> :error
        end
      end

    case resultado do
      {:ok, nodo} ->
        Node.set_cookie(String.to_atom(cookie))
        {:ok, nodo}

      :error ->
        {:error,
         "No se pudo iniciar el nodo #{nombre}@#{host_local()}. ¿Ya hay otro nodo con ese " <>
           "nombre en esta máquina? Prueba con --nombre otro_nombre."}
    end
  end

  # ── Helpers privados ────────────────────────────────────────────────

  defp con_opciones(argv, tipos, fun) do
    case OptionParser.parse(argv,
           strict: [{:help, :boolean} | tipos],
           aliases: [h: :help]
         ) do
      {opts, [], []} ->
        if Keyword.get(opts, :help, false), do: :ayuda, else: fun.(opts)

      # Una opción desconocida deja su valor como argumento suelto: se reporta la opción
      {_opts, _, [{opcion, _} | _]} ->
        {:error, "Opción no válida: #{opcion}. Usa --help para ver las opciones."}

      {_opts, [extra | _], []} ->
        {:error, "Argumento inesperado: #{extra}. Usa --help para ver las opciones."}
    end
  end

  defp validar_nombre(nombre) do
    if Regex.match?(@nombre_valido, nombre) do
      {:ok, nombre}
    else
      {:error, "Nombre de nodo no válido: #{inspect(nombre)}. Usa letras, números, _ o -."}
    end
  end

  defp validar_cookie(""), do: {:error, "La cookie no puede estar vacía."}
  defp validar_cookie(cookie), do: {:ok, cookie}

  # "servidor" se completa con el host local; "servidor@otra_maquina" se usa tal cual
  defp nodo_servidor(valor, host) do
    case String.split(valor, "@") do
      [nombre] ->
        with {:ok, nombre} <- validar_nombre(nombre),
             do: {:ok, String.to_atom("#{nombre}@#{host}")}

      [nombre, host_servidor] when host_servidor != "" ->
        with {:ok, _} <- validar_nombre(nombre), do: {:ok, String.to_atom(valor)}

      _ ->
        {:error, "Nodo del servidor no válido: #{inspect(valor)}. Usa nombre o nombre@host."}
    end
  end

  defp iniciar_epmd do
    case System.find_executable("epmd") do
      nil -> :ok
      epmd -> System.cmd(epmd, ["-daemon"])
    end
  end
end
