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

  # ── GenServer Info Callbacks (Temporizadores) ────────────────────────

  @impl true
  def handle_info(_other, state) do
    {:noreply, state}
  end

  @impl true
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
end
