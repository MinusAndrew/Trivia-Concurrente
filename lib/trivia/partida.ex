defmodule Trivia.Partida do
  @moduledoc """
  GenServer que representa UNA partida independiente de trivia.

  Gestiona el estado completo y el ciclo de juego de la partida:
    * Sorteo de preguntas al iniciar según el nivel del jugador y tema.
    * Apertura y temporización de rondas individuales.
    * Recepción y validación de respuestas de humanos y bots.
    * Verificación estricta de plazos en el servidor mediante reloj monotónico.
    * Cálculo de puntajes base y bonificaciones por rapidez calculadas en el servidor.
    * Notificaciones estructuradas a los oyentes (clientes/bots).
    * Pausas de 3 segundos entre rondas.
    * Estrategia de persistencia con reintentos e idempotencia.
    * Limpieza y terminación normal del proceso tras una finalización exitosa.
  """
  use GenServer

  @max_jugadores 4
  @max_bots 3
  @dificultades_validas [:facil, :dificil, "facil", "dificil"]

  # ── Especificación para DynamicSupervisor ──────────────────────────

  def child_spec(args) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [args]},
      restart: :transient,
      type: :worker
    }
  end

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Inicia un proceso GenServer para una partida individual.
  """
  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @doc """
  Obtiene el estado completo de la partida como un mapa.
  """
  def obtener_estado(partida) do
    GenServer.call(partida, :obtener_estado)
  end

  def obtener_info(partida), do: obtener_estado(partida)

  @doc """
  Agrega un bot a la partida con la dificultad especificada (`:facil` o `:dificil`).
  Solo permitido en estado `:esperando` y mientras haya cupo (< 4 jugadores).
  """
  def agregar_bot(partida, dificultad \\ :facil) do
    GenServer.call(partida, {:agregar_bot, dificultad})
  end

  def add_bot(partida, dificultad \\ :facil), do: agregar_bot(partida, dificultad)

  @doc """
  Registra un proceso oyente para recibir notificaciones de la partida.
  """
  def registrar_oyente(partida, pid) when is_pid(pid) do
    GenServer.call(partida, {:registrar_oyente, pid})
  end

  def register_listener(partida, pid), do: registrar_oyente(partida, pid)

  @doc """
  Registra el PID de un bot asociado a su nombre dentro de la partida.
  """
  def registrar_bot(partida, nombre, pid) when is_pid(pid) do
    GenServer.cast(partida, {:registrar_bot, to_string(nombre), pid})
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────

  @impl true
  def init(args) do
    id = Keyword.fetch!(args, :id)
    creador = Keyword.fetch!(args, :creador) |> to_string()
    tema = Keyword.fetch!(args, :tema) |> to_string()
    nivel = Keyword.get(args, :nivel, :basico)
    total_preguntas = Keyword.fetch!(args, :total_preguntas)
    tiempo_pregunta = Keyword.fetch!(args, :tiempo_pregunta)
    cliente_pid = Keyword.get(args, :cliente_pid)
    gestor = Keyword.get(args, :gestor, Trivia.GestorPartidas)
    persistencia = Keyword.get(args, :persistencia, Trivia.Persistencia)
    pausa_ms = Keyword.get(args, :pausa_ms, 3000)
    reintento_ms = Keyword.get(args, :reintento_ms, 1000)
    limpieza_ms = Keyword.get(args, :limpieza_ms, 100)
    preguntas_fijadas = Keyword.get(args, :preguntas)
    reloj_fun = Keyword.get(args, :reloj_fun, fn -> System.monotonic_time(:millisecond) end)
    bot_opts = Keyword.get(args, :bot_opts, [])

    Process.flag(:trap_exit, true)

    # Reportar PID a GestorPartidas mediante cast para evitar deadlock
    if gestor do
      GenServer.cast(gestor, {:reportar_pid, id, self()})
    end

    listeners = if is_pid(cliente_pid), do: [cliente_pid], else: []

    state = %{
      id: id,
      creador: creador,
      tema: tema,
      nivel: nivel,
      total_preguntas: total_preguntas,
      tiempo_pregunta: tiempo_pregunta,
      jugadores: [creador],
      bots: [],
      bot_pids: %{},
      bot_opts: bot_opts,
      estado: :esperando,
      puntajes: %{creador => 0},
      pregunta_actual: 0,
      cliente_pid: cliente_pid,
      gestor: gestor,
      persistencia: persistencia,
      pausa_ms: pausa_ms,
      reintento_ms: reintento_ms,
      limpieza_ms: limpieza_ms,
      reloj_fun: reloj_fun,
      preguntas_fijadas: preguntas_fijadas,
      preguntas: [],
      pregunta_actual_data: nil,
      ronda_abierta: false,
      en_pausa: false,
      inicio_ronda_mono: nil,
      respuestas_ronda: %{},
      timer_ref: nil,
      ronda_ref: nil,
      pause_ref: nil,
      pause_timer: nil,
      retry_ref: nil,
      retry_timer: nil,
      cleanup_timer: nil,
      resultado_persistido: false,
      resultado_final: nil,
      ranking_final: nil,
      ganador_final: nil,
      error_persistencia: nil,
      listeners: listeners
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:obtener_estado, _from, state) do
    {:reply, state, state}
  end

  def handle_call({:registrar_oyente, pid}, _from, state) do
    listeners = if pid in state.listeners, do: state.listeners, else: [pid | state.listeners]
    {:reply, :ok, %{state | listeners: listeners}}
  end

  def handle_call({:registrar_bot, nombre, pid}, _from, state) do
    nombre_str = to_string(nombre)
    bot_pids = Map.put(state.bot_pids, nombre_str, pid)
    {:reply, :ok, %{state | bot_pids: bot_pids}}
  end

  def handle_call({:agregar_bot, dificultad}, _from, state) do
    cond do
      state.estado != :esperando ->
        {:reply, {:error, :partida_en_curso}, state}

      length(state.jugadores) >= @max_jugadores or length(state.bots) >= @max_bots ->
        {:reply, {:error, :partida_llena}, state}

      dificultad not in @dificultades_validas ->
        {:reply, {:error, :dificultad_invalida}, state}

      true ->
        dif_norm = normalizar_dificultad(dificultad)
        bot_num = length(state.bots) + 1
        bot_nombre = "bot_#{bot_num}"

        # Iniciar el proceso autónomo del bot
        bot_args = [
          nombre: bot_nombre,
          dificultad: dif_norm,
          partida: self()
        ]

        bot_args =
          if Map.has_key?(state, :bot_opts) and is_list(state.bot_opts) do
            Keyword.merge(bot_args, state.bot_opts)
          else
            bot_args
          end

        case Trivia.Bot.start_link(bot_args) do
          {:ok, bot_pid} ->
            nuevo_bot = %{nombre: bot_nombre, dificultad: dif_norm}
            bot_pids = Map.put(state.bot_pids, bot_nombre, bot_pid)

            updated_state = %{
              state
              | bots: state.bots ++ [nuevo_bot],
                bot_pids: bot_pids,
                jugadores: state.jugadores ++ [bot_nombre],
                puntajes: Map.put(state.puntajes, bot_nombre, 0)
            }

            {:reply, {:ok, bot_nombre}, updated_state}

          {:error, reason} ->
            {:reply, {:error, {:fallo_iniciar_bot, reason}}, state}
        end
    end
  end

  # ── GenServer Info Callbacks (Temporizadores) ────────────────────────

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state) do
    # Capturar la salida o fallas de bots sin afectar la partida
    {:noreply, state}
  end

  def handle_info(_other, state) do
    {:noreply, state}
  end

  @impl true
  def handle_cast({:registrar_bot, nombre, pid}, state) do
    nombre_str = to_string(nombre)
    bot_pids = Map.put(state.bot_pids, nombre_str, pid)
    {:noreply, %{state | bot_pids: bot_pids}}
  end

  def handle_cast(_other, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(Map.values(state.bot_pids), fn pid ->
      if is_pid(pid) and Process.alive?(pid) do
        Process.exit(pid, :kill)
      end
    end)

    :ok
  end

  # ── Helpers privados ────────────────────────────────────────────────

  defp normalizar_dificultad(:facil), do: :facil
  defp normalizar_dificultad(:dificil), do: :dificil
  defp normalizar_dificultad("facil"), do: :facil
  defp normalizar_dificultad("dificil"), do: :dificil
  defp normalizar_dificultad(other), do: other
end
