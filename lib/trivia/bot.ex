defmodule Trivia.Bot do
  @moduledoc """
  Proceso GenServer que implementa un jugador automático (bot) para Trivia Concurrente.

  Cada bot corre en su propio proceso independiente en el servidor, asociado
  a una partida y con un nivel de dificultad (`:facil` o `:dificil`).

  Comportamiento según la especificación (Sección 6.6):
    * Recibe notificaciones de nuevas preguntas con el nivel y respuesta correcta
      (información interna del servidor, jamás enviada a clientes).
    * Decide su respuesta (A, B, C o D) y retardo de forma asíncrona según su dificultad.
    * Programa el envío de su respuesta mediante `Process.send_after/3` (sin bloquear con sleep).
    * Envía la respuesta a la partida mediante la API pública `Trivia.Partida.responder/3`.
    * Obedece las reglas de tiempo, pausas y una sola respuesta por ronda.
    * Monitorea el proceso de la partida para terminar limpiamente si la partida
      finaliza o falla.
  """
  use GenServer

  alias Trivia.Puntaje

  @opciones_validas ["A", "B", "C", "D"]

  # ── Especificación para DynamicSupervisor o Supervisión ────────────

  def child_spec(args) do
    id = Keyword.get(args, :nombre, __MODULE__)

    %{
      id: id,
      start: {__MODULE__, :start_link, [args]},
      restart: :transient,
      type: :worker
    }
  end

  # ── Public API (Procesos) ───────────────────────────────────────────

  @doc """
  Inicia el proceso GenServer de un bot.
  Opciones requeridas:
    * `:nombre` - Nombre único del bot (ej. `"bot_1"`).
    * `:dificultad` - `:facil` o `:dificil`.
    * `:partida` - PID del GenServer de la partida.
  """
  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @doc """
  Obtiene el estado interno del proceso del bot.
  """
  def obtener_estado(bot) do
    GenServer.call(bot, :obtener_estado)
  end

  # ── Funciones Puras de Decisión (Testables independientemente) ─────

  @doc """
  Retorna la probabilidad de acierto (en rango 0.0 .. 1.0) para la combinación
  de dificultad del bot y nivel de la pregunta:

    * `:facil`:
      - básica: 40% (0.40)
      - intermedia: 30% (0.30)
      - avanzada: 20% (0.20)
    * `:dificil`:
      - básica: 80% (0.80)
      - intermedia: 70% (0.70)
      - avanzada: 60% (0.60)
  """
  @spec probabilidad_acierto(term(), term()) :: float()
  def probabilidad_acierto(dificultad_bot, nivel_pregunta) do
    dif = normalizar_dificultad(dificultad_bot)
    niv = normalizar_nivel(nivel_pregunta)

    case {dif, niv} do
      {:facil, :basico} -> 0.40
      {:facil, :intermedio} -> 0.30
      {:facil, :avanzado} -> 0.20
      {:dificil, :basico} -> 0.80
      {:dificil, :intermedio} -> 0.70
      {:dificil, :avanzado} -> 0.60
    end
  end

  @doc """
  Retorna el rango de tiempo de respuesta (como tupla de ratios {min, max})
  según la dificultad del bot:

    * `:facil`: entre el 40% y el 90% del tiempo disponible.
    * `:dificil`: entre el 10% y el 40% del tiempo disponible.
  """
  @spec rango_tiempo(term()) :: {float(), float()}
  def rango_tiempo(dificultad_bot) do
    case normalizar_dificultad(dificultad_bot) do
      :facil -> {0.40, 0.90}
      :dificil -> {0.10, 0.40}
    end
  end

  @doc """
  Retorna las tres opciones incorrectas para una respuesta correcta dada.
  Nunca incluye la respuesta correcta.
  """
  @spec opciones_incorrectas(term()) :: [String.t()]
  def opciones_incorrectas(respuesta_correcta) do
    correcta = Puntaje.normalizar_respuesta(respuesta_correcta)
    Enum.filter(@opciones_validas, fn opcion -> opcion != correcta end)
  end

  @doc """
  Función pura principal de decisión.
  Calcula la opción elegida (A, B, C o D) y el retardo en milisegundos.

  Parámetros:
    * `dificultad_bot`: `:facil` o `:dificil`.
    * `nivel_pregunta`: `:basico`, `:intermedio` o `:avanzado`.
    * `respuesta_correcta`: `"A"`, `"B"`, `"C"` o `"D"`.
    * `tiempo_pregunta`: Tiempo por pregunta en segundos (entero o float > 0).
    * `opts`: Opciones opcionales para pruebas deterministas:
      - `:acierto?` (boolean): Forzar si acierta o falla.
      - `:prob` (float 0.0..1.0): Valor pseudoaleatorio para evaluar acierto.
      - `:time_ratio` (float 0.0..1.0): Posición relativa dentro del rango de tiempo.
      - `:incorrecta_idx` (entero): Índice (0..2) de la opción incorrecta a seleccionar si falla.

  Retorna un mapa con:
    * `:respuesta` - Opción elegida ("A", "B", "C" o "D").
    * `:delay_ms` - Retardo en milisegundos dentro del rango de la dificultad.
    * `:acerto?` - Si la respuesta es la correcta.
  """
  @spec decidir(term(), term(), term(), number(), keyword()) :: map()
  def decidir(dificultad_bot, nivel_pregunta, respuesta_correcta, tiempo_pregunta, opts \\ [])
      when is_number(tiempo_pregunta) and tiempo_pregunta > 0 do
    dif = normalizar_dificultad(dificultad_bot)
    niv = normalizar_nivel(nivel_pregunta)
    correcta_norm = Puntaje.normalizar_respuesta(respuesta_correcta)
    prob_acierto = probabilidad_acierto(dif, niv)

    # 1. Determinar si acierta
    acierta? =
      cond do
        Keyword.has_key?(opts, :acierto?) ->
          Keyword.get(opts, :acierto?) == true

        Keyword.has_key?(opts, :prob) ->
          Keyword.get(opts, :prob) < prob_acierto

        true ->
          :rand.uniform() < prob_acierto
      end

    # 2. Elegir opción
    respuesta =
      if acierta? do
        correcta_norm
      else
        incorrectas = opciones_incorrectas(correcta_norm)

        cond do
          Keyword.has_key?(opts, :incorrecta_idx) ->
            idx = rem(Keyword.get(opts, :incorrecta_idx), 3)
            Enum.at(incorrectas, idx)

          true ->
            Enum.random(incorrectas)
        end
      end

    # 3. Calcular retardo en milisegundos
    {min_ratio, max_ratio} = rango_tiempo(dif)

    t_ratio =
      cond do
        Keyword.has_key?(opts, :time_ratio) ->
          val = Keyword.get(opts, :time_ratio)
          max(0.0, min(1.0, val * 1.0))

        true ->
          :rand.uniform()
      end

    ratio = min_ratio + t_ratio * (max_ratio - min_ratio)
    delay_ms = round(tiempo_pregunta * ratio * 1000)

    # Asegurar que esté estrictamente dentro de los límites
    min_ms = round(tiempo_pregunta * min_ratio * 1000)
    max_ms = round(tiempo_pregunta * max_ratio * 1000)
    delay_ms_clamped = max(min_ms, min(max_ms, delay_ms))

    %{
      "respuesta" => respuesta,
      "delay_ms" => delay_ms_clamped,
      respuesta: respuesta,
      delay_ms: delay_ms_clamped,
      acerto?: acierta?
    }
  end

  @doc """
  Helper puro que retorna exclusivamente la opción elegida ("A", "B", "C" o "D").
  """
  def decidir_respuesta(dificultad_bot, nivel_pregunta, respuesta_correcta, opts \\ []) do
    decidir(dificultad_bot, nivel_pregunta, respuesta_correcta, 15, opts).respuesta
  end

  @doc """
  Helper puro que retorna exclusivamente el retardo en milisegundos.
  """
  def decidir_delay(dificultad_bot, tiempo_pregunta, opts \\ []) do
    decidir(dificultad_bot, :basico, "A", tiempo_pregunta, opts).delay_ms
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────

  @impl true
  def init(args) do
    nombre = Keyword.fetch!(args, :nombre) |> to_string()
    dificultad = Keyword.fetch!(args, :dificultad) |> normalizar_dificultad()
    partida = Keyword.fetch!(args, :partida)

    monitor_ref =
      if is_pid(partida) and Process.alive?(partida) do
        Process.monitor(partida)
      else
        nil
      end

    # Registrar PID de forma asíncrona mediante cast si la partida está disponible
    if is_pid(partida) and Process.alive?(partida) do
      Trivia.Partida.registrar_bot(partida, nombre, self())
    end

    state = %{
      nombre: nombre,
      dificultad: dificultad,
      partida: partida,
      monitor_ref: monitor_ref,
      timer_ref: nil,
      ronda_actual: nil,
      round_ref: nil,
      opts: args
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:obtener_estado, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info({tag, info}, state)
      when tag in [:nueva_pregunta, :nueva_pregunta_bot] and is_map(info) do
    # Cancelar cualquier temporizador previo
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    num_ronda = info[:numero] || info["numero"]
    nivel = info[:nivel] || info["nivel"] || :basico

    correcta =
      info[:respuesta_correcta] || info["respuesta_correcta"] || info[:respuesta] ||
        info["respuesta"]

    tiempo =
      info[:tiempo_limite] || info["tiempo_limite"] || info[:tiempo_pregunta] ||
        info["tiempo_pregunta"] || 15

    if correcta != nil and num_ronda != nil do
      decision = decidir(state.dificultad, nivel, correcta, tiempo, state.opts)
      round_ref = make_ref()

      timer_ref =
        Process.send_after(
          self(),
          {:enviar_respuesta, num_ronda, round_ref, decision.respuesta},
          decision.delay_ms
        )

      {:noreply, %{state | timer_ref: timer_ref, ronda_actual: num_ronda, round_ref: round_ref}}
    else
      # Notificación sin la clave de respuesta correcta (seguridad)
      {:noreply, %{state | timer_ref: nil, ronda_actual: num_ronda, round_ref: nil}}
    end
  end

  def handle_info({:enviar_respuesta, num_ronda, round_ref, respuesta}, state) do
    if state.round_ref == round_ref and state.ronda_actual == num_ronda do
      # Enviar respuesta a la partida mediante la API pública de partida
      if is_pid(state.partida) and Process.alive?(state.partida) do
        try do
          Trivia.Partida.responder(state.partida, state.nombre, respuesta)
        catch
          :exit, _reason -> :ok
        end
      end

      {:noreply, %{state | timer_ref: nil}}
    else
      # Temporizador obsoleto de ronda anterior: ignorar
      {:noreply, state}
    end
  end

  def handle_info({:fin_ronda, _info}, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    {:noreply, %{state | timer_ref: nil}}
  end

  def handle_info({:fin_partida, _info}, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    {:stop, :normal, %{state | timer_ref: nil}}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    if ref == state.monitor_ref and pid == state.partida do
      if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
      {:stop, :normal, %{state | timer_ref: nil}}
    else
      {:noreply, state}
    end
  end

  def handle_info(_other, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    :ok
  end

  # ── Helpers privados ────────────────────────────────────────────────

  defp normalizar_dificultad(:facil), do: :facil
  defp normalizar_dificultad("facil"), do: :facil
  defp normalizar_dificultad(:dificil), do: :dificil
  defp normalizar_dificultad("dificil"), do: :dificil

  defp normalizar_dificultad(other) do
    raise ArgumentError,
          "Dificultad de bot inválida: #{inspect(other)}. Debe ser :facil o :dificil"
  end

  defp normalizar_nivel(:basico), do: :basico
  defp normalizar_nivel("basico"), do: :basico
  defp normalizar_nivel(:intermedio), do: :intermedio
  defp normalizar_nivel("intermedio"), do: :intermedio
  defp normalizar_nivel(:avanzado), do: :avanzado
  defp normalizar_nivel("avanzado"), do: :avanzado

  defp normalizar_nivel(other) do
    raise ArgumentError, "Nivel de pregunta inválido: #{inspect(other)}"
  end
end
