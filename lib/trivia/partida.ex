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

  alias Trivia.BancoPreguntas
  alias Trivia.Persistencia
  alias Trivia.Puntaje

  @max_jugadores 4
  @min_bots 2
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
  Inicia la partida. Requiere al menos dos bots agregados y estar en estado `:esperando`.
  Selecciona las preguntas del banco y abre automáticamente la primera ronda.
  """
  def iniciar_partida(partida) do
    GenServer.call(partida, :iniciar_partida)
  end

  def start_game(partida), do: iniciar_partida(partida)

  @doc """
  Envía una respuesta para la ronda en curso.
  El cálculo de bonificación y validación de plazos se realiza exclusivamente
  en el servidor mediante su reloj monotónico.
  """
  def responder(partida, jugador, respuesta) do
    GenServer.call(partida, {:responder, jugador, respuesta})
  end

  def responder(partida, jugador, respuesta, _opts) do
    # Opciones externas son ignoradas intencionalmente para evitar manipulación de bonificación
    GenServer.call(partida, {:responder, jugador, respuesta})
  end

  def answer(partida, jugador, respuesta), do: responder(partida, jugador, respuesta)
  def answer(partida, jugador, respuesta, _opts), do: responder(partida, jugador, respuesta)

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

  @doc """
  Permite al creador abandonar la partida. Si está en espera, se cancela; si está en curso,
  se persiste el resultado hasta ese momento y termina.
  """
  def abandonar_partida(partida, jugador) do
    GenServer.call(partida, {:abandonar_partida, jugador})
  end

  def leave_game(partida, jugador), do: abandonar_partida(partida, jugador)

  @doc """
  Actualiza el puntaje de un jugador en la partida (uso interno/pruebas).
  """
  def actualizar_puntaje(partida, jugador, puntos) do
    GenServer.call(partida, {:actualizar_puntaje, jugador, puntos})
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

  def handle_call(:iniciar_partida, _from, state) do
    cond do
      state.estado != :esperando ->
        {:reply, {:error, :partida_ya_iniciada}, state}

      length(state.bots) < @min_bots ->
        {:reply, {:error, :minimo_dos_bots}, state}

      true ->
        case obtener_preguntas_partida(state) do
          {:ok, preguntas} ->
            ready_state = %{state | preguntas: preguntas, estado: :en_curso}

            notificar(
              ready_state,
              {:partida_iniciada,
               %{
                 partida_id: state.id,
                 tema: state.tema,
                 nivel: state.nivel,
                 total: state.total_preguntas,
                 tiempo_limite: state.tiempo_pregunta,
                 jugadores: state.jugadores
               }}
            )

            started_state = abrir_ronda(ready_state)
            {:reply, :ok, started_state}

          {:error, _reason} = err ->
            {:reply, err, state}
        end
    end
  end

  def handle_call({:responder, jugador, respuesta}, from, state) do
    handle_responder(jugador, respuesta, from, state)
  end

  def handle_call({:responder, jugador, respuesta, _opts}, from, state) do
    handle_responder(jugador, respuesta, from, state)
  end

  def handle_call({:actualizar_puntaje, jugador, puntos}, _from, state) do
    jugador_str = to_string(jugador)

    cond do
      state.estado != :en_curso ->
        {:reply, {:error, :partida_no_en_curso}, state}

      not is_integer(puntos) ->
        {:reply, {:error, :puntos_invalidos}, state}

      not Map.has_key?(state.puntajes, jugador_str) ->
        {:reply, {:error, :jugador_no_registrado}, state}

      true ->
        updated_puntajes = Map.put(state.puntajes, jugador_str, puntos)
        {:reply, :ok, %{state | puntajes: updated_puntajes}}
    end
  end

  def handle_call({:abandonar_partida, jugador}, _from, state) do
    jugador_str = to_string(jugador)

    cond do
      jugador_str == state.creador and state.estado == :esperando ->
        # Cancela antes de iniciar (sin registrar en results.log)
        {:stop, :normal, :ok, state}

      jugador_str == state.creador and state.estado == :finalizada ->
        # Ya finalizada y persistida; terminar normalmente sin duplicar persistencia
        cancelar_temporizadores(state)
        {:stop, :normal, :ok, state}

      jugador_str == state.creador and state.estado == :pendiente_persistencia ->
        # Intentar persistir inmediatamente
        new_state = intentar_persistencia_y_finalizar(state)

        if new_state.resultado_persistido do
          cancelar_temporizadores(new_state)
          {:stop, :normal, :ok, new_state}
        else
          {:reply, {:error, {:persistencia_pendiente, new_state.error_persistencia}}, new_state}
        end

      jugador_str == state.creador and state.estado == :en_curso ->
        # Abandono con partida en curso
        # 1. Cancelar temporizadores activos de ronda y pausa
        cancelar_temporizadores(state)

        # 2. Construir resultado final con los puntajes acumulados hasta el momento
        ganador = Puntaje.determinar_ganador(state.puntajes)
        ranking = Puntaje.calcular_ranking(state.puntajes)

        resultado = %{
          "id" => state.id,
          "fecha" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "tema" => to_string(state.tema),
          "nivel" => to_string(state.nivel),
          "ganador" => ganador,
          "puntajes" => state.puntajes
        }

        # 3. Transicionar fuera de :en_curso (evita quedar en curso con temporizadores cancelados)
        state_abandonada = %{
          state
          | estado: :pendiente_persistencia,
            ronda_abierta: false,
            en_pausa: false,
            timer_ref: nil,
            pause_timer: nil,
            resultado_final: resultado,
            ranking_final: ranking,
            ganador_final: ganador
        }

        # 4. Usar la misma ruta unificada de persistencia y reintento
        new_state = intentar_persistencia_y_finalizar(state_abandonada)

        if new_state.resultado_persistido do
          # Persistencia exitosa inmediata: termina normalmente y libera al creador
          cancelar_temporizadores(new_state)
          {:stop, :normal, :ok, new_state}
        else
          # Persistencia falló: permanece en :pendiente_persistencia,
          # con reintento automático programado y sin liberar al creador
          {:reply, {:error, {:persistencia_pendiente, new_state.error_persistencia}}, new_state}
        end

      jugador_str == state.creador ->
        {:reply, {:error, :partida_no_en_curso}, state}

      true ->
        {:reply, {:error, :jugador_no_autorizado}, state}
    end
  end

  # ── GenServer Info Callbacks (Temporizadores) ────────────────────────

  @impl true
  def handle_info({:reintentar_persistencia, ref}, state) do
    if state.estado == :pendiente_persistencia and state.retry_ref == ref do
      new_state = intentar_persistencia_y_finalizar(state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  def handle_info(:limpiar_y_terminar, state) do
    if state.estado == :finalizada and state.resultado_persistido do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

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

  # ── Lógica de Recepción de Respuestas ───────────────────────────────

  defp handle_responder(jugador, respuesta, _from, state) do
    jugador_str = to_string(jugador)

    cond do
      state.estado == :esperando ->
        {:reply, {:error, :partida_no_iniciada}, state}

      state.estado in [:finalizada, :pendiente_persistencia] ->
        {:reply, {:error, :partida_finalizada}, state}

      not Map.has_key?(state.puntajes, jugador_str) ->
        {:reply, {:error, :jugador_no_registrado}, state}

      not state.ronda_abierta ->
        {:reply, {:error, :ronda_no_abierta}, state}

      true ->
        now_mono = tiempo_actual_ms(state)
        elapsed_ms = now_mono - state.inicio_ronda_mono
        tiempo_limite_ms = state.tiempo_pregunta * 1000

        if elapsed_ms >= tiempo_limite_ms do
          # El plazo de la ronda ya venció en el servidor, incluso si el mensaje
          # del temporizador aún no ha sido procesado por el GenServer.
          # Cerramos la ronda exactamente una vez y rechazamos la respuesta.
          if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
          closed_state = cerrar_ronda(state, :tiempo_agotado)
          {:reply, {:error, :tiempo_agotado}, closed_state}
        else
          if not Puntaje.respuesta_valida?(respuesta) do
            {:reply, {:error, :respuesta_invalida}, state}
          else
            if Map.has_key?(state.respuestas_ronda, jugador_str) do
              {:reply, {:error, :ya_respondio}, state}
            else
              letra_norm = Puntaje.normalizar_respuesta(respuesta)
              elapsed_s = elapsed_ms / 1000.0
              segundos_restantes = max(0.0, state.tiempo_pregunta - elapsed_s)

              resp_data = %{
                respuesta: letra_norm,
                segundos_restantes: segundos_restantes,
                timestamp: now_mono
              }

              updated_respuestas = Map.put(state.respuestas_ronda, jugador_str, resp_data)
              new_state = %{state | respuestas_ronda: updated_respuestas}

              if map_size(updated_respuestas) >= length(state.jugadores) do
                if new_state.timer_ref, do: Process.cancel_timer(new_state.timer_ref)
                closed_state = cerrar_ronda(new_state, :todos_respondieron)
                {:reply, :ok, closed_state}
              else
                {:reply, :ok, new_state}
              end
            end
          end
        end
    end
  end

  # ── Ciclo de Rondas y Juego ─────────────────────────────────────────

  defp abrir_ronda(state) do
    num_ronda = state.pregunta_actual + 1
    pregunta = Enum.at(state.preguntas, num_ronda - 1)

    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    inicio_mono = tiempo_actual_ms(state)
    ronda_ref = make_ref()
    tiempo_ms = state.tiempo_pregunta * 1000
    timer_ref = Process.send_after(self(), {:timer_ronda, num_ronda, ronda_ref}, tiempo_ms)

    new_state = %{
      state
      | pregunta_actual: num_ronda,
        pregunta_actual_data: pregunta,
        ronda_abierta: true,
        en_pausa: false,
        inicio_ronda_mono: inicio_mono,
        ronda_ref: ronda_ref,
        timer_ref: timer_ref,
        pause_ref: nil,
        pause_timer: nil,
        respuestas_ronda: %{}
    }

    # Notificación sin la respuesta correcta (seguridad) para clientes humanos
    pregunta_cliente = BancoPreguntas.para_cliente(pregunta)

    notificacion_cliente =
      {:nueva_pregunta,
       %{
         partida_id: state.id,
         numero: num_ronda,
         total: state.total_preguntas,
         tema: state.tema,
         nivel: pregunta["nivel"] || pregunta[:nivel],
         enunciado: pregunta_cliente["enunciado"] || pregunta_cliente[:enunciado],
         opciones: pregunta_cliente["opciones"] || pregunta_cliente[:opciones],
         tiempo_limite: state.tiempo_pregunta
       }}

    notificar(new_state, notificacion_cliente)

    # Notificación interna para los bots (incluye respuesta correcta para su decisión)
    resp_correcta = Puntaje.normalizar_respuesta(pregunta["respuesta"] || pregunta[:respuesta])
    nivel_pregunta = pregunta["nivel"] || pregunta[:nivel]

    notificacion_bot =
      {:nueva_pregunta,
       %{
         partida_id: state.id,
         numero: num_ronda,
         total: state.total_preguntas,
         tema: state.tema,
         nivel: nivel_pregunta,
         enunciado: pregunta_cliente["enunciado"] || pregunta_cliente[:enunciado],
         opciones: pregunta_cliente["opciones"] || pregunta_cliente[:opciones],
         tiempo_limite: state.tiempo_pregunta,
         respuesta_correcta: resp_correcta
       }}

    notificar_bots(new_state, notificacion_bot)
    new_state
  end

  defp cerrar_ronda(state, _motivo) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    pregunta = state.pregunta_actual_data
    resp_correcta = Puntaje.normalizar_respuesta(pregunta["respuesta"] || pregunta[:respuesta])
    nivel_pregunta = pregunta["nivel"] || pregunta[:nivel]

    {puntos_ronda, detalles_ronda, updated_puntajes} =
      Enum.reduce(state.jugadores, {%{}, %{}, state.puntajes}, fn jugador,
                                                                  {pts_acc, det_acc, punt_acc} ->
        case Map.get(state.respuestas_ronda, jugador) do
          nil ->
            puntos =
              Puntaje.calcular_puntos_ronda(
                nivel_pregunta,
                :sin_responder,
                0,
                state.tiempo_pregunta
              )

            pts = Map.put(pts_acc, jugador, puntos)

            det =
              Map.put(det_acc, jugador, %{
                resultado: :sin_responder,
                puntos: puntos,
                bonificacion: 0,
                respuesta: nil
              })

            punt = Map.update(punt_acc, jugador, puntos, &(&1 + puntos))
            {pts, det, punt}

          %{respuesta: r, segundos_restantes: s_rest} ->
            if r == resp_correcta do
              bonif = Puntaje.bonificacion_rapidez(s_rest, state.tiempo_pregunta)

              puntos =
                Puntaje.calcular_puntos_ronda(
                  nivel_pregunta,
                  :correcta,
                  s_rest,
                  state.tiempo_pregunta
                )

              pts = Map.put(pts_acc, jugador, puntos)

              det =
                Map.put(det_acc, jugador, %{
                  resultado: :correcta,
                  puntos: puntos,
                  bonificacion: bonif,
                  respuesta: r
                })

              punt = Map.update(punt_acc, jugador, puntos, &(&1 + puntos))
              {pts, det, punt}
            else
              puntos =
                Puntaje.calcular_puntos_ronda(
                  nivel_pregunta,
                  :incorrecta,
                  0,
                  state.tiempo_pregunta
                )

              pts = Map.put(pts_acc, jugador, puntos)

              det =
                Map.put(det_acc, jugador, %{
                  resultado: :incorrecta,
                  puntos: puntos,
                  bonificacion: 0,
                  respuesta: r
                })

              punt = Map.update(punt_acc, jugador, puntos, &(&1 + puntos))
              {pts, det, punt}
            end
        end
      end)

    notificacion_cierre =
      {:fin_ronda,
       %{
         partida_id: state.id,
         numero: state.pregunta_actual,
         total: state.total_preguntas,
         respuesta_correcta: resp_correcta,
         puntos_ronda: puntos_ronda,
         detalles_ronda: detalles_ronda,
         puntajes_acumulados: updated_puntajes
       }}

    notificar(state, notificacion_cierre)
    notificar_bots(state, notificacion_cierre)

    if state.pregunta_actual < state.total_preguntas do
      pause_ref = make_ref()
      next_round = state.pregunta_actual + 1

      pause_timer =
        Process.send_after(
          self(),
          {:iniciar_siguiente_ronda, next_round, pause_ref},
          state.pausa_ms
        )

      %{
        state
        | ronda_abierta: false,
          en_pausa: true,
          pause_ref: pause_ref,
          pause_timer: pause_timer,
          timer_ref: nil,
          puntajes: updated_puntajes
      }
    else
      iniciar_finalizacion(
        %{
          state
          | ronda_abierta: false,
            en_pausa: false,
            timer_ref: nil,
            pause_timer: nil,
            puntajes: updated_puntajes
        },
        updated_puntajes
      )
    end
  end

  defp iniciar_finalizacion(state, final_puntajes) do
    ganador = Puntaje.determinar_ganador(final_puntajes)
    ranking = Puntaje.calcular_ranking(final_puntajes)

    resultado = %{
      "id" => state.id,
      "fecha" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "tema" => to_string(state.tema),
      "nivel" => to_string(state.nivel),
      "ganador" => ganador,
      "puntajes" => final_puntajes
    }

    state_preparado = %{
      state
      | resultado_final: resultado,
        ranking_final: ranking,
        ganador_final: ganador,
        puntajes: final_puntajes
    }

    intentar_persistencia_y_finalizar(state_preparado)
  end

  defp intentar_persistencia_y_finalizar(state) do
    if state.retry_timer, do: Process.cancel_timer(state.retry_timer)

    persistencia_res =
      try do
        Persistencia.registrar_resultado_unico(state.resultado_final, state.persistencia)
      catch
        :exit, reason -> {:error, {:persistencia_no_disponible, reason}}
      end

    case persistencia_res do
      res when res in [:ok, {:ok, :ya_registrado}] ->
        notificar_finalizacion_exitosa(state)

        if state.gestor do
          GenServer.cast(state.gestor, {:partida_finalizada, state.id, state.creador})
        end

        cleanup_timer =
          Process.send_after(self(), :limpiar_y_terminar, state.limpieza_ms)

        %{
          state
          | estado: :finalizada,
            resultado_persistido: true,
            error_persistencia: nil,
            retry_timer: nil,
            retry_ref: nil,
            cleanup_timer: cleanup_timer
        }

      {:error, reason} ->
        # Persistencia falló: no notificar fin exitoso, no liberar creador,
        # conservar estado recuperable y programar reintento controlado
        retry_ref = make_ref()

        retry_timer =
          Process.send_after(
            self(),
            {:reintentar_persistencia, retry_ref},
            state.reintento_ms
          )

        %{
          state
          | estado: :pendiente_persistencia,
            resultado_persistido: false,
            error_persistencia: reason,
            retry_ref: retry_ref,
            retry_timer: retry_timer
        }
    end
  end

  defp notificar_finalizacion_exitosa(state) do
    notificacion_final =
      {:fin_partida,
       %{
         partida_id: state.id,
         tema: state.tema,
         nivel: state.nivel,
         ganador: state.ganador_final,
         ranking: state.ranking_final,
         puntajes: state.puntajes
       }}

    notificar(state, notificacion_final)
    notificar_bots(state, notificacion_final)
  end

  # ── Helpers privados ────────────────────────────────────────────────

  defp tiempo_actual_ms(state), do: state.reloj_fun.()

  defp obtener_preguntas_partida(%{preguntas_fijadas: p}) when is_list(p) and length(p) > 0 do
    {:ok, p}
  end

  defp obtener_preguntas_partida(state) do
    case BancoPreguntas.cargar_banco(state.persistencia) do
      {:ok, preguntas} ->
        BancoPreguntas.sortear_preguntas(
          preguntas,
          state.tema,
          state.nivel,
          state.total_preguntas
        )

      {:error, _reason} = err ->
        err
    end
  end

  # Los oyentes pueden ser procesos de clientes en otros nodos. `Process.alive?/1`
  # solo acepta PIDs locales (lanza ArgumentError con PIDs remotos), así que se
  # envía directamente: `send` a un proceso muerto es inofensivo y `:noconnect`
  # evita que la partida intente reconectarse a un nodo de cliente caído.
  defp notificar(state, payload) do
    Enum.each(state.listeners, &enviar_seguro(&1, payload))
  end

  defp notificar_bots(state, payload) do
    Enum.each(Map.values(state.bot_pids), &enviar_seguro(&1, payload))
  end

  defp enviar_seguro(pid, payload) when is_pid(pid) do
    Process.send(pid, payload, [:noconnect])
  end

  defp enviar_seguro(_otro, _payload), do: :ok

  defp cancelar_temporizadores(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    if state.pause_timer, do: Process.cancel_timer(state.pause_timer)
    if state.retry_timer, do: Process.cancel_timer(state.retry_timer)
    if state.cleanup_timer, do: Process.cancel_timer(state.cleanup_timer)
  end

  defp normalizar_dificultad(:facil), do: :facil
  defp normalizar_dificultad(:dificil), do: :dificil
  defp normalizar_dificultad("facil"), do: :facil
  defp normalizar_dificultad("dificil"), do: :dificil
  defp normalizar_dificultad(other), do: other
end
