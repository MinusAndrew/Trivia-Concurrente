defmodule Trivia.CLI do
  @moduledoc """
  Funciones compartidas por las tareas `mix trivia.servidor` y `mix trivia.cliente`.

  El análisis de opciones es puro (se puede probar sin levantar nodos); el
  arranque del nodo distribuido queda en `iniciar_nodo/3`.

  Hay dos modos de red:

    * **local** (por defecto): nombres cortos (`--sname`), para jugar en la
      misma máquina.
    * **red** (`--publico` o `--host` en el servidor; `--servidor nombre@ip` en
      el cliente): nombres largos y un único puerto TCP fijo (por defecto
      9100), para jugar desde otras máquinas de la LAN o por Internet con
      redirección de puertos. El cliente no abre puertos: solo se conecta.
  """

  @nombre_servidor "servidor"
  @cookie "trivia"
  @puerto_red 9100
  @nombre_valido ~r/^[A-Za-z0-9_-]+$/
  # IP o dominio: al menos un punto, como exigen los nombres largos de Erlang
  @host_red_valido ~r/^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/

  @doc """
  Analiza los argumentos de `mix trivia.servidor`.

  Retorna `{:ok, %{nombre: _, cookie: _, datos: _ | nil, red: nil | %{host: _ | nil, puerto: _}}}`,
  `:ayuda` o `{:error, mensaje}`. En modo red, sin `--cookie` se genera una
  cookie aleatoria; sin `--host` se usa la IP local al iniciar el nodo.
  """
  def opciones_servidor(argv) do
    tipos = [
      nombre: :string,
      cookie: :string,
      datos: :string,
      publico: :boolean,
      host: :string,
      puerto: :integer
    ]

    con_opciones(argv, tipos, fn opts ->
      en_red? = Keyword.get(opts, :publico, false) or Keyword.has_key?(opts, :host)
      cookie_por_defecto = if en_red?, do: cookie_aleatoria(), else: @cookie

      with {:ok, nombre} <- validar_nombre(Keyword.get(opts, :nombre, @nombre_servidor)),
           {:ok, cookie} <- validar_cookie(Keyword.get(opts, :cookie, cookie_por_defecto)),
           {:ok, red} <- red_servidor(en_red?, opts) do
        {:ok, %{nombre: nombre, cookie: cookie, datos: Keyword.get(opts, :datos), red: red}}
      end
    end)
  end

  @doc """
  Analiza los argumentos de `mix trivia.cliente`. `host` es el host corto de
  esta máquina y se usa para completar el nodo del servidor cuando no se indica.

  Retorna `{:ok, %{nombre: _, cookie: _, servidor: nodo, red: nil | %{puerto: _}}}`,
  `:ayuda` o `{:error, mensaje}`. Sin `--nombre` se genera uno aleatorio
  (`jugador_<n>`) para que varios clientes en la misma máquina no choquen. Si
  el host del servidor es una IP o un dominio (`servidor@1.2.3.4`), el cliente
  entra en modo red.
  """
  def opciones_cliente(argv, host) do
    tipos = [nombre: :string, cookie: :string, servidor: :string, puerto: :integer]

    con_opciones(argv, tipos, fn opts ->
      nombre_por_defecto = "jugador_#{:rand.uniform(9000) + 999}"

      with {:ok, nombre} <- validar_nombre(Keyword.get(opts, :nombre, nombre_por_defecto)),
           {:ok, cookie} <- validar_cookie(Keyword.get(opts, :cookie, @cookie)),
           {:ok, servidor} <- nodo_servidor(Keyword.get(opts, :servidor, @nombre_servidor), host),
           {:ok, red} <- red_cliente(servidor, opts) do
        {:ok, %{nombre: nombre, cookie: cookie, servidor: servidor, red: red}}
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
  Primera IPv4 de una interfaz activa que no sea loopback ni de enlace local
  (`169.254.x.x`). Si no hay ninguna, `"127.0.0.1"`.
  """
  def ip_local do
    case :inet.getifaddrs() do
      {:ok, interfaces} ->
        Enum.find_value(interfaces, "127.0.0.1", fn {_nombre, opts} ->
          flags = Keyword.get(opts, :flags, [])
          if :up in flags and :loopback not in flags, do: ipv4_util(opts)
        end)

      _ ->
        "127.0.0.1"
    end
  end

  @doc """
  Convierte este proceso de Mix en un nodo distribuido con la cookie indicada.

  Con `red = nil` usa un nombre corto (`nombre@host`). Con
  `%{rol: :servidor, host: _, puerto: _}` usa un nombre largo y escucha solo
  en `puerto`; con `%{rol: :cliente, puerto: _}` usa un nombre largo, no abre
  ningún puerto y se conecta directo al `puerto` del servidor, sin consultar
  `epmd` en la máquina remota.

  Si el nodo ya es distribuido (p. ej. se lanzó con `elixir --sname ...`),
  conserva su nombre y solo fija la cookie.
  """
  def iniciar_nodo(nombre, cookie, red \\ nil) do
    resultado =
      if Node.alive?() do
        {:ok, node()}
      else
        arrancar_distribucion(nombre, red)
      end

    case resultado do
      {:ok, nodo} ->
        Node.set_cookie(String.to_atom(cookie))
        {:ok, nodo}

      :error ->
        {:error, mensaje_error_nodo(nombre, red)}
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

  defp validar_puerto(puerto) when puerto in 1..65_535, do: {:ok, puerto}

  defp validar_puerto(puerto),
    do: {:error, "Puerto no válido: #{puerto}. Usa un número entre 1 y 65535."}

  defp validar_host_red(host) do
    if Regex.match?(@host_red_valido, host) do
      {:ok, host}
    else
      {:error,
       "Host no válido: #{inspect(host)}. Usa una IP (192.168.1.20) o un dominio " <>
         "(mi-casa.duckdns.org)."}
    end
  end

  defp red_servidor(false, opts) do
    if Keyword.has_key?(opts, :puerto),
      do: {:error, "--puerto solo aplica en modo red. Agrega --publico o --host."},
      else: {:ok, nil}
  end

  defp red_servidor(true, opts) do
    with {:ok, puerto} <- validar_puerto(Keyword.get(opts, :puerto, @puerto_red)),
         {:ok, host} <- host_opcional(Keyword.get(opts, :host)) do
      {:ok, %{host: host, puerto: puerto}}
    end
  end

  defp host_opcional(nil), do: {:ok, nil}
  defp host_opcional(host), do: validar_host_red(host)

  # El modo red del cliente lo decide el host del servidor: una IP o un dominio
  defp red_cliente(servidor, opts) do
    host_servidor = servidor |> Atom.to_string() |> String.split("@") |> List.last()

    cond do
      String.contains?(host_servidor, ".") ->
        with {:ok, _} <- validar_host_red(host_servidor),
             {:ok, puerto} <- validar_puerto(Keyword.get(opts, :puerto, @puerto_red)),
             do: {:ok, %{puerto: puerto}}

      Keyword.has_key?(opts, :puerto) ->
        {:error, "--puerto solo aplica a servidores remotos (--servidor nombre@ip)."}

      true ->
        {:ok, nil}
    end
  end

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

  defp cookie_aleatoria do
    :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
  end

  defp ipv4_util(opts) do
    Enum.find_value(opts, fn
      {:addr, {a, b, _, _} = ip} when a != 127 and {a, b} != {169, 254} ->
        ip |> :inet.ntoa() |> to_string()

      _ ->
        nil
    end)
  end

  defp arrancar_distribucion(nombre, nil) do
    iniciar_epmd()

    # Node.start/3 existe tanto en Elixir 1.17 como en versiones recientes
    case Node.start(String.to_atom(nombre), :shortnames, 15_000) do
      {:ok, _pid} -> {:ok, node()}
      {:error, _motivo} -> :error
    end
  end

  defp arrancar_distribucion(nombre, %{rol: rol, puerto: puerto} = red) do
    # Con este parámetro (OTP 27.2+) el nodo escucha en `puerto` y supone que
    # todo nodo remoto escucha en el mismo, sin preguntar a su epmd. En OTP
    # anteriores se ignora y la conexión pasa por epmd (puerto 4369).
    Application.put_env(:kernel, :erl_epmd_node_listen_port, puerto)

    opciones =
      case rol do
        :servidor ->
          # Fija el puerto también en OTP anteriores; epmd sigue registrando
          # el nodo para clientes que lo consulten
          Application.put_env(:kernel, :inet_dist_listen_min, puerto)
          Application.put_env(:kernel, :inet_dist_listen_max, puerto)
          iniciar_epmd()
          %{name_domain: :longnames}

        :cliente ->
          # Sin puerto de escucha (y oculto): solo conexiones salientes, así
          # que no necesita redirección y los clientes no se conectan entre sí
          %{name_domain: :longnames, dist_listen: false}
      end

    host = Map.get(red, :host) || ip_local()

    case :net_kernel.start(String.to_atom("#{nombre}@#{host}"), opciones) do
      {:ok, _pid} -> {:ok, node()}
      {:error, _motivo} -> :error
    end
  end

  defp mensaje_error_nodo(nombre, nil) do
    "No se pudo iniciar el nodo #{nombre}@#{host_local()}. ¿Ya hay otro nodo con ese " <>
      "nombre en esta máquina? Prueba con --nombre otro_nombre."
  end

  defp mensaje_error_nodo(nombre, %{rol: :servidor, puerto: puerto}) do
    "No se pudo iniciar el nodo #{nombre} en modo red. ¿Ya hay otro servidor usando " <>
      "el puerto #{puerto}? Prueba con --puerto otro_puerto."
  end

  defp mensaje_error_nodo(nombre, %{rol: :cliente}) do
    "No se pudo iniciar el nodo #{nombre} en modo red. ¿Ya hay otro cliente con ese " <>
      "nombre en esta máquina? Prueba con --nombre otro_nombre."
  end

  defp iniciar_epmd do
    case System.find_executable("epmd") do
      nil -> :ok
      epmd -> System.cmd(epmd, ["-daemon"])
    end
  end
end
