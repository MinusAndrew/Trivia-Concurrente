defmodule Trivia.Cliente do
  @moduledoc """
  Módulo del CLIENTE para conectarse al servidor central de Trivia Concurrente,
  enviar comandos de juego y ejecutar la interfaz de consola (secciones 8.2 y 8.3).

  El cliente **no** contiene lógica de juego ni toca archivos de datos:
    * Traduce lo que el jugador escribe en peticiones hacia `Trivia.Servidor`.
    * Inicia un proceso separado (`Trivia.Receptor`) para recibir notificaciones
      asíncronas de la partida sin bloquearse por la lectura del teclado.
    * Monitorea al proceso del servidor y el enlace entre nodos para detectar
      caídas o desconexiones del servidor de forma controlada.
  """
  use GenServer

  alias Trivia.Receptor

  @default_timeout 10_000

  # ── Arranque y ciclo de vida ────────────────────────────────────────

  @doc """
  Inicia un proceso `Trivia.Cliente` junto con su `Trivia.Receptor`.

  Opciones:
    * `:nodo_servidor` – átomo del nodo donde corre el servidor (por defecto `Node.self()`).
    * `:servidor` – nombre registrado del servidor (por defecto `Trivia.Servidor`).
    * `:suscriptor` – PID opcional que recibirá copia de cada notificación del receptor.
    * `:silencioso` – si es `true` (por defecto en pruebas cuando se indica), no imprime en consola.
    * `:timeout` – tiempo máximo de espera por petición en ms (por defecto `10_000`).
    * `:name` – nombre opcional para registrar el proceso del cliente.
  """
  def start_link(opts \\ []) do
    {name, init_opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc """
  Inicia un proceso `Trivia.Cliente` sin enlazarlo al proceso llamador
  (útil al iniciarlo remotamente mediante RPC o en consolas independientes).
  """
  def start(opts \\ []) do
    {name, init_opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start(__MODULE__, init_opts, gen_opts)
  end

  @doc """
  Detiene el cliente y su receptor asociado.
  """
  def stop(cliente) do
    GenServer.stop(cliente, :normal)
  end

  # ── Comandos del protocolo (secciones 4, 5 y 6) ─────────────────────

  @doc """
  Comando `connect <usuario> <clave>`: conecta al nodo del servidor e inicia
  sesión (registrando al usuario automáticamente si no existía).
  """
  def conectar(cliente \\ __MODULE__, usuario, clave) do
    GenServer.call(cliente, {:conectar, to_string(usuario), to_string(clave)}, @default_timeout)
  end

  def connect(cliente \\ __MODULE__, usuario, clave), do: conectar(cliente, usuario, clave)

  @doc """
  Comando `disconnect`: cierra la sesión activa en el servidor. Si el jugador
  estaba en una partida en curso, aplica la sección 6.5.
  """
  def desconectar(cliente \\ __MODULE__) do
    GenServer.call(cliente, {:peticion, :disconnect}, @default_timeout)
  end

  def disconnect(cliente \\ __MODULE__), do: desconectar(cliente)

  @doc """
  Comando `score`: solicita al servidor el puntaje acumulado, partidas jugadas
  y nivel por tema del jugador conectado.
  """
  def score(cliente \\ __MODULE__) do
    GenServer.call(cliente, {:peticion, :score}, @default_timeout)
  end

  @doc """
  Comando `ranking [tema]`: solicita al servidor el ranking histórico global o
  filtrado por un tema específico.
  """
  def ranking(cliente \\ __MODULE__, tema \\ nil) do
    tema_norm =
      case tema do
        nil -> nil
        "" -> nil
        t -> to_string(t)
      end

    GenServer.call(cliente, {:peticion, {:ranking, tema_norm}}, @default_timeout)
  end

  @doc """
  Comando `create_game tema=<tema> preguntas=<n> tiempo=<segundos>`: solicita al
  servidor crear una nueva partida.
  """
  def crear_partida(cliente \\ __MODULE__, tema, preguntas, tiempo) do
    GenServer.call(
      cliente,
      {:peticion, {:create_game, to_string(tema), preguntas, tiempo}},
      @default_timeout
    )
  end

  def create_game(cliente \\ __MODULE__, tema, preguntas, tiempo),
    do: crear_partida(cliente, tema, preguntas, tiempo)

  @doc """
  Comando `add_bot <facil|dificil>`: agrega un bot a la partida del jugador.
  """
  def agregar_bot(cliente \\ __MODULE__, dificultad \\ "facil") do
    GenServer.call(
      cliente,
      {:peticion, {:add_bot, to_string(dificultad)}},
      @default_timeout
    )
  end

  def add_bot(cliente \\ __MODULE__, dificultad \\ "facil"),
    do: agregar_bot(cliente, dificultad)

  @doc """
  Comando `start_game`: inicia la partida del jugador.
  """
  def iniciar_partida(cliente \\ __MODULE__) do
    GenServer.call(cliente, {:peticion, :start_game}, @default_timeout)
  end

  def start_game(cliente \\ __MODULE__), do: iniciar_partida(cliente)

  @doc """
  Comando `leave_game`: abandona la partida activa.
  """
  def abandonar_partida(cliente \\ __MODULE__) do
    GenServer.call(cliente, {:peticion, :leave_game}, @default_timeout)
  end

  def leave_game(cliente \\ __MODULE__), do: abandonar_partida(cliente)

  @doc """
  Comando `answer <letra>`: envía la respuesta del jugador para la ronda abierta.
  """
  def responder(cliente \\ __MODULE__, letra) do
    GenServer.call(cliente, {:peticion, {:answer, to_string(letra)}}, @default_timeout)
  end

  def answer(cliente \\ __MODULE__, letra), do: responder(cliente, letra)

  @doc """
  Envía una petición cruda al servidor desde la sesión del cliente.
  Permite verificar que el servidor rechace comandos o formas inválidas.
  """
  def enviar_peticion(cliente \\ __MODULE__, peticion) do
    GenServer.call(cliente, {:peticion, peticion}, @default_timeout)
  end

  @doc """
  Retorna el estado local de la sesión del cliente.
  """
  def estado(cliente \\ __MODULE__) do
    GenServer.call(cliente, :estado)
  end

  @doc """
  Retorna el PID del proceso `Trivia.Receptor` asociado al cliente.
  """
  def receptor_pid(cliente \\ __MODULE__) do
    GenServer.call(cliente, :receptor_pid)
  end

  @doc """
  Retorna las notificaciones recibidas por el `Trivia.Receptor` del cliente.
  """
  def notificaciones(cliente \\ __MODULE__) do
    pid = receptor_pid(cliente)
    Receptor.obtener_notificaciones(pid)
  end

  # ── Intérprete de comandos de consola ───────────────────────────────

  @doc """
  Parsea una línea de comando escrita por el jugador y la convierte en una
  instrucción estructurada sin ejecutar lógica de juego.

  Ejemplos:
    * `"connect pedro 1234"` -> `{:ok, {:connect, "pedro", "1234"}}`
    * `"create_game tema=ciencia preguntas=5 tiempo=15"` -> `{:ok, {:create_game, "ciencia", 5, 15}}`
    * `"add_bot dificil"` -> `{:ok, {:add_bot, "dificil"}}`
    * `"start_game"` -> `{:ok, :start_game}`
    * `"answer B"` -> `{:ok, {:answer, "B"}}`
    * `"leave_game"` -> `{:ok, :leave_game}`
    * `"score"` -> `{:ok, :score}`
    * `"ranking"` -> `{:ok, {:ranking, nil}}`
    * `"ranking ciencia"` -> `{:ok, {:ranking, "ciencia"}}`
    * `"disconnect"` -> `{:ok, :disconnect}`
  """
  def parsear_comando(linea) when is_binary(linea) do
    partes = linea |> String.trim() |> String.split(~r/\s+/, trim: true)

    case partes do
      [] ->
        {:ok, :vacio}

      ["help"] ->
        {:ok, :ayuda}

      ["ayuda"] ->
        {:ok, :ayuda}

      ["exit"] ->
        {:ok, :salir}

      ["quit"] ->
        {:ok, :salir}

      ["connect", usuario, clave] ->
        {:ok, {:connect, usuario, clave}}

      ["disconnect"] ->
        {:ok, :disconnect}

      ["score"] ->
        {:ok, :score}

      ["ranking"] ->
        {:ok, {:ranking, nil}}

      ["ranking", tema] ->
        {:ok, {:ranking, tema}}

      ["create_game" | kv_args] when kv_args != [] ->
        parsear_create_game(kv_args)

      ["add_bot", dificultad] ->
        {:ok, {:add_bot, dificultad}}

      ["start_game"] ->
        {:ok, :start_game}

      ["leave_game"] ->
        {:ok, :leave_game}

      ["answer", letra] ->
        {:ok, {:answer, letra}}

      _ ->
        {:error, :comando_invalido}
    end
  end

  defp parsear_create_game(kv_args) do
    pares =
      Enum.reduce_while(kv_args, %{}, fn token, acc ->
        case String.split(token, "=", parts: 2) do
          [k, v] when k != "" and v != "" -> {:cont, Map.put(acc, String.downcase(k), v)}
          _ -> {:halt, :error}
        end
      end)

    with %{} = mapa <- pares,
         {:ok, tema} <- Map.fetch(mapa, "tema"),
         {:ok, preg_str} <- Map.fetch(mapa, "preguntas"),
         {:ok, tiempo_str} <- Map.fetch(mapa, "tiempo"),
         {preguntas, ""} <- Integer.parse(preg_str),
         {tiempo, ""} <- Integer.parse(tiempo_str) do
      {:ok, {:create_game, tema, preguntas, tiempo}}
    else
      _ -> {:error, :parametros_invalidos}
    end
  end

  @doc """
  Parsea y ejecuta una línea de texto de comando contra el servidor.
  """
  def ejecutar_comando(cliente \\ __MODULE__, linea) when is_binary(linea) do
    case parsear_comando(linea) do
      {:ok, :vacio} ->
        :ok

      {:ok, :ayuda} ->
        {:ok, texto_ayuda()}

      {:ok, :salir} ->
        _ = desconectar(cliente)
        {:ok, :salir}

      {:ok, {:connect, usuario, clave}} ->
        conectar(cliente, usuario, clave)

      {:ok, peticion} ->
        enviar_peticion(cliente, peticion)

      {:error, _motivo} = err ->
        err
    end
  end

  @doc """
  Inicia un cliente conectado al `nodo_servidor` dado y abre el ciclo interactivo
  de consola para el jugador.

  Ejemplo en IEx de un nodo cliente (`iex --sname pedro -S mix`):

      Trivia.Cliente.iniciar(:"servidor@nombre_host")
  """
  def iniciar(nodo_servidor, opts \\ []) when is_atom(nodo_servidor) do
    {:ok, cliente} =
      start_link(
        Keyword.merge(opts,
          nodo_servidor: nodo_servidor,
          silencioso: Keyword.get(opts, :silencioso, false)
        )
      )

    IO.puts("""
                  TRIVIA CONCURRENTE — CLIENTE
    Nodo cliente : #{node()}
    Nodo servidor: #{nodo_servidor}
    Escribe 'help' para ver los comandos disponibles.
    """)

    bucle_consola(cliente)
  end

  defp bucle_consola(cliente) do
    case IO.gets("trivia> ") do
      :eof ->
        _ = stop(cliente)
        :ok

      {:error, _} ->
        _ = stop(cliente)
        :ok

      linea when is_binary(linea) ->
        case ejecutar_comando(cliente, linea) do
          :ok ->
            bucle_consola(cliente)

          {:ok, :salir} ->
            IO.puts("Hasta pronto.")
            _ = stop(cliente)
            :ok

          {:ok, texto} when is_binary(texto) ->
            IO.puts(texto)
            bucle_consola(cliente)

          {:ok, {:score, stats}} ->
            IO.puts(Receptor.formatear_score(stats))
            bucle_consola(cliente)

          {:ok, {:ranking, tema, entradas}} ->
            IO.puts(Receptor.formatear_ranking(tema, entradas))
            bucle_consola(cliente)

          {:ok, _respuesta} ->
            bucle_consola(cliente)

          {:error, motivo} ->
            IO.puts(Receptor.formatear_error(motivo))
            bucle_consola(cliente)
        end
    end
  end

  defp texto_ayuda do
    """
    Comandos disponibles:
      connect <usuario> <clave>                        Inicia sesión o registra usuario
      disconnect                                       Cierra la sesión actual
      score                                            Muestra tu puntaje acumulado y niveles
      ranking [tema]                                   Muestra el ranking histórico (global o por tema)
      create_game tema=<t> preguntas=<n> tiempo=<s>    Crea una nueva partida
      add_bot <facil|dificil>                          Agrega un bot a la partida en espera
      start_game                                       Inicia la partida
      answer <A|B|C|D>                                 Envía tu respuesta en la ronda actual
      leave_game                                       Abandona la partida actual
      exit                                             Cierra el cliente
    """
    |> String.trim_trailing()
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────

  @impl true
  def init(opts) do
    nodo_servidor = Keyword.get(opts, :nodo_servidor, Node.self())
    servidor = Keyword.get(opts, :servidor, Trivia.Servidor)
    suscriptor = Keyword.get(opts, :suscriptor)
    silencioso = Keyword.get(opts, :silencioso, false)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    {:ok, receptor} =
      Receptor.start_link(
        suscriptor: suscriptor,
        silencioso: silencioso
      )

    if Node.alive?() do
      :net_kernel.monitor_nodes(true)
    end

    state = %{
      nodo_servidor: nodo_servidor,
      servidor: servidor,
      receptor: receptor,
      usuario: nil,
      conectado: false,
      monitor_ref: nil,
      timeout: timeout
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:estado, _from, state) do
    info = %{
      usuario: state.usuario,
      conectado: state.conectado,
      nodo_servidor: state.nodo_servidor,
      receptor: state.receptor
    }

    {:reply, info, state}
  end

  def handle_call(:receptor_pid, _from, state) do
    {:reply, state.receptor, state}
  end

  def handle_call({:conectar, usuario, clave}, _from, state) do
    case asegurar_conexion_nodo(state.nodo_servidor) do
      :ok ->
        peticion = {:connect, usuario, clave, state.receptor}

        case llamar_servidor(state, peticion) do
          {:ok, {:conectado, usuario_conectado, _tipo}} = exito ->
            if state.monitor_ref, do: Process.demonitor(state.monitor_ref, [:flush])
            ref = monitorear_servidor(state)
            send(state.receptor, {:conexion, exito})

            nuevo_state = %{
              state
              | usuario: usuario_conectado,
                conectado: true,
                monitor_ref: ref
            }

            {:reply, exito, nuevo_state}

          {:error, _motivo} = error ->
            send(state.receptor, {:conexion, error})
            {:reply, error, state}
        end

      {:error, _motivo} = error ->
        send(state.receptor, {:conexion, error})
        {:reply, error, state}
    end
  end

  def handle_call({:peticion, :disconnect}, _from, state) do
    res = llamar_servidor(state, :disconnect)

    nuevo_state =
      case res do
        {:ok, :desconectado} ->
          if state.monitor_ref, do: Process.demonitor(state.monitor_ref, [:flush])
          send(state.receptor, {:conexion, res})
          %{state | usuario: nil, conectado: false, monitor_ref: nil}

        _ ->
          state
      end

    {:reply, res, nuevo_state}
  end

  def handle_call({:peticion, peticion}, _from, state) do
    res = llamar_servidor(state, peticion)
    notificar_evento_comando(state.receptor, peticion, res)
    {:reply, res, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor_ref: ref} = state) do
    send(state.receptor, {:servidor_desconectado, state.nodo_servidor})
    {:noreply, %{state | usuario: nil, conectado: false, monitor_ref: nil}}
  end

  def handle_info({:nodedown, nodo}, %{nodo_servidor: nodo} = state) do
    if state.conectado do
      if state.monitor_ref, do: Process.demonitor(state.monitor_ref, [:flush])
      send(state.receptor, {:servidor_desconectado, nodo})
      {:noreply, %{state | usuario: nil, conectado: false, monitor_ref: nil}}
    else
      {:noreply, state}
    end
  end

  def handle_info(_otro, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_pid(state.receptor) and Process.alive?(state.receptor) do
      try do
        GenServer.stop(state.receptor, :normal, 1000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  # ── Helpers privados de comunicación remota ─────────────────────────

  defp asegurar_conexion_nodo(nodo) do
    cond do
      nodo == node() ->
        :ok

      not Node.alive?() ->
        {:error, :servidor_no_disponible}

      Node.connect(nodo) == true ->
        :ok

      true ->
        {:error, :servidor_no_disponible}
    end
  end

  defp destino_servidor(state) do
    if is_pid(state.servidor) do
      state.servidor
    else
      {state.servidor, state.nodo_servidor}
    end
  end

  defp monitorear_servidor(state) do
    try do
      Process.monitor(destino_servidor(state))
    rescue
      ArgumentError -> nil
    end
  end

  defp llamar_servidor(state, peticion) do
    with :ok <- asegurar_conexion_nodo(state.nodo_servidor) do
      try do
        GenServer.call(destino_servidor(state), {:peticion, peticion}, state.timeout)
      catch
        :exit, {:noproc, _} -> {:error, :servidor_no_disponible}
        :exit, {{:nodedown, _}, _} -> {:error, :servidor_no_disponible}
        :exit, {:timeout, _} -> {:error, :tiempo_espera_agotado}
        :exit, _reason -> {:error, :servidor_no_disponible}
      end
    end
  end

  defp notificar_evento_comando(receptor, _peticion, {:ok, {:partida_creada, _id, _nivel} = info}) do
    send(receptor, {:estado_partida, info})
  end

  defp notificar_evento_comando(receptor, _peticion, {:ok, {:bot_agregado, _nombre} = info}) do
    send(receptor, {:estado_partida, info})
  end

  defp notificar_evento_comando(receptor, _peticion, {:ok, :partida_iniciada}) do
    send(receptor, {:estado_partida, :partida_iniciada})
  end

  defp notificar_evento_comando(receptor, _peticion, {:ok, :partida_abandonada}) do
    send(receptor, {:estado_partida, :partida_abandonada})
  end

  defp notificar_evento_comando(receptor, _peticion, {:ok, :respuesta_registrada}) do
    send(receptor, {:estado_partida, :respuesta_registrada})
  end

  defp notificar_evento_comando(_receptor, _peticion, _resultado), do: :ok
end
