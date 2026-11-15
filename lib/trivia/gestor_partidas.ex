defmodule Trivia.GestorPartidas do
  @moduledoc """
  GenServer responsable de coordinar la creación, ubicación y ciclo de vida de las partidas activas.

  Responsabilidades:
    * Asignar identificadores únicos a cada partida (`P-1001`, `P-1002`, ...).
    * Crear los procesos de partida a través de `Trivia.SupervisorPartidas`.
    * Mantener el mapeo entre PIDs de partida y sus metadatos.
    * Mantener el mapeo entre jugadores y la partida en la que participan.
    * Evitar que un jugador participe en más de una partida a la vez.
    * Ubicar la partida de un jugador sin exponer el PID interno al cliente.
    * Atender notificaciones de reinicio de partidas (mediante `cast`) y actualizar el PID.
    * Notificar al creador cuando su partida se reinicia tras una falla anormal.
  """
  use GenServer

  alias Trivia.BancoPreguntas
  alias Trivia.Nivel
  alias Trivia.Persistencia
  alias Trivia.SupervisorPartidas

  require Logger

  @primer_id 1001

  @aviso_reinicio_plantilla "La partida %{id} falló y se reinició sin su progreso. Agrega los bots y ejecuta start_game para jugar de nuevo."

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Inicia el GenServer del gestor de partidas.
  Opciones admitidas:
    * `:name` – Nombre registrado (por defecto `__MODULE__`).
    * `:supervisor` – Nombre o PID del DynamicSupervisor (por defecto `Trivia.SupervisorPartidas`).
    * `:persistencia` – Nombre o PID de Persistencia (por defecto `Trivia.Persistencia`).
  """
  def start_link(opts \\ []) do
    {name, genserver_opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, Keyword.merge([name: name], genserver_opts))
  end

  @doc """
  Crea una nueva partida para un jugador creador.

  Parámetros:
    * `creador`: Nombre de usuario del creador.
    * `tema`: Tema seleccionado para la partida.
    * `total_preguntas`: Cantidad de preguntas.
    * `tiempo_pregunta`: Tiempo por pregunta en segundos.
    * `opts`: Opciones adicionales (ej. `:cliente_pid`, `:id`, `:nivel`).

  Retorna:
    * `{:ok, id, nivel}` en caso de éxito.
    * `{:error, :jugador_en_partida}` si el creador ya tiene una partida activa.
    * `{:error, :tema_inexistente}` si el tema no existe en el banco.
    * `{:error, :preguntas_insuficientes}` si no hay suficientes preguntas en el banco.
  """
  def crear_partida(creador, tema, total_preguntas, tiempo_pregunta) when is_binary(creador) do
    crear_partida(__MODULE__, creador, tema, total_preguntas, tiempo_pregunta, [])
  end

  def crear_partida(creador, tema, total_preguntas, tiempo_pregunta, opts)
      when is_binary(creador) and is_list(opts) do
    crear_partida(__MODULE__, creador, tema, total_preguntas, tiempo_pregunta, opts)
  end

  def crear_partida(gestor, creador, tema, total_preguntas, tiempo_pregunta, opts \\ []) do
    GenServer.call(
      gestor,
      {:crear_partida, creador, tema, total_preguntas, tiempo_pregunta, opts}
    )
  end

  @doc """
  Ubica el identificador de la partida en la que participa un jugador, sin exponer el PID.
  """
  def obtener_partida(jugador) when is_binary(jugador) do
    obtener_partida(__MODULE__, jugador)
  end

  def obtener_partida(gestor, jugador) do
    GenServer.call(gestor, {:obtener_partida, to_string(jugador)})
  end

  @doc """
  Retorna el PID del proceso de la partida para propósitos internos del servidor o pruebas.
  """
  def obtener_pid_partida(jugador_o_id) when is_binary(jugador_o_id) do
    obtener_pid_partida(__MODULE__, jugador_o_id)
  end

  def obtener_pid_partida(gestor, jugador_o_id) do
    GenServer.call(gestor, {:obtener_pid_partida, to_string(jugador_o_id)})
  end

  @doc """
  Obtiene el estado interno de la partida asociada a un jugador o ID.
  """
  def obtener_estado_partida(jugador_o_id) when is_binary(jugador_o_id) do
    obtener_estado_partida(__MODULE__, jugador_o_id)
  end

  def obtener_estado_partida(gestor, jugador_o_id) do
    case obtener_pid_partida(gestor, jugador_o_id) do
      {:ok, pid} -> {:ok, Trivia.Partida.obtener_estado(pid)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Agrega un bot a la partida del jugador indicado.
  """
  def agregar_bot(jugador) when is_binary(jugador) do
    agregar_bot(__MODULE__, jugador, :facil)
  end

  def agregar_bot(jugador, dificultad) when is_binary(jugador) do
    agregar_bot(__MODULE__, jugador, dificultad)
  end

  def agregar_bot(gestor, jugador) when is_binary(jugador) do
    agregar_bot(gestor, jugador, :facil)
  end

  def agregar_bot(gestor, jugador, dificultad) do
    case obtener_pid_partida(gestor, jugador) do
      {:ok, pid} -> Trivia.Partida.agregar_bot(pid, dificultad)
      {:error, _} = err -> err
    end
  end

  @doc """
  Inicia la partida del jugador indicado.
  """
  def iniciar_partida(jugador) when is_binary(jugador) do
    iniciar_partida(__MODULE__, jugador)
  end

  def iniciar_partida(gestor, jugador) do
    case obtener_pid_partida(gestor, jugador) do
      {:ok, pid} -> Trivia.Partida.iniciar_partida(pid)
      {:error, _} = err -> err
    end
  end

  def start_game(jugador) when is_binary(jugador), do: iniciar_partida(jugador)
  def start_game(gestor, jugador), do: iniciar_partida(gestor, jugador)

  @doc """
  Envía una respuesta a la partida del jugador indicado.
  """
  def responder(jugador, respuesta) when is_binary(jugador) do
    responder(__MODULE__, jugador, respuesta, [])
  end

  def responder(gestor, jugador, respuesta) when is_binary(jugador) do
    responder(gestor, jugador, respuesta, [])
  end

  def responder(gestor, jugador, respuesta, opts) when is_list(opts) do
    case obtener_pid_partida(gestor, jugador) do
      {:ok, pid} -> Trivia.Partida.responder(pid, jugador, respuesta, opts)
      {:error, _} = err -> err
    end
  end

  def answer(jugador, respuesta), do: responder(jugador, respuesta)
  def answer(gestor, jugador, respuesta), do: responder(gestor, jugador, respuesta)
  def answer(gestor, jugador, respuesta, opts), do: responder(gestor, jugador, respuesta, opts)

  @doc """
  Permite al jugador creador abandonar su partida activa.
  """
  def abandonar_partida(jugador) when is_binary(jugador) do
    abandonar_partida(__MODULE__, jugador)
  end

  def abandonar_partida(gestor, jugador) do
    GenServer.call(gestor, {:abandonar_partida, to_string(jugador)})
  end

  def leave_game(jugador) when is_binary(jugador), do: abandonar_partida(jugador)
  def leave_game(gestor, jugador), do: abandonar_partida(gestor, jugador)

  @doc """
  Reporte asíncrono del PID de una partida al gestor.
  Invocado exclusivamente mediante `cast` desde el `init` de `Trivia.Partida`.
  """
  def reportar_pid(gestor \\ __MODULE__, id, pid) do
    GenServer.cast(gestor, {:reportar_pid, id, pid})
  end

  @doc """
  Lista las partidas activas actualmente registradas en el gestor.
  """
  def listar_partidas(gestor \\ __MODULE__) do
    GenServer.call(gestor, :listar_partidas)
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────

  @impl true
  def init(opts) do
    supervisor = Keyword.get(opts, :supervisor, SupervisorPartidas)
    persistencia = Keyword.get(opts, :persistencia, Persistencia)

    state = %{
      supervisor: supervisor,
      persistencia: persistencia,
      contador_id: contador_inicial(persistencia, supervisor),
      partidas: %{},
      jugador_partida: %{},
      monitores: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call(
        {:crear_partida, creador, tema, total_preguntas, tiempo_pregunta, opts},
        _from,
        state
      ) do
    creador_str = to_string(creador)
    tema_str = to_string(tema)

    cond do
      String.starts_with?(creador_str, "bot_") ->
        {:reply, {:error, :usuario_reservado}, state}

      not is_integer(total_preguntas) or total_preguntas <= 0 ->
        {:reply, {:error, :parametros_invalidos}, state}

      not is_integer(tiempo_pregunta) or tiempo_pregunta <= 0 ->
        {:reply, {:error, :parametros_invalidos}, state}

      Map.has_key?(state.jugador_partida, creador_str) ->
        {:reply, {:error, :jugador_en_partida}, state}

      true ->
        with {:ok, nivel} <- resolver_nivel(state, creador_str, tema_str),
             :ok <- validar_banco(state.persistencia, tema_str, nivel, total_preguntas) do
          id = Keyword.get(opts, :id, "P-#{state.contador_id}")
          cliente_pid = Keyword.get(opts, :cliente_pid)

          # Referencia hacia el gestor para que la partida reporte su PID
          gestor_ref =
            case Process.info(self(), :registered_name) do
              {:registered_name, name} when is_atom(name) and name != nil -> name
              _ -> self()
            end

          partida_args =
            opts
            |> Keyword.merge(
              id: id,
              creador: creador_str,
              tema: tema_str,
              nivel: nivel,
              total_preguntas: total_preguntas,
              tiempo_pregunta: tiempo_pregunta,
              cliente_pid: cliente_pid,
              gestor: gestor_ref,
              persistencia: state.persistencia
            )

          case SupervisorPartidas.iniciar_partida(state.supervisor, partida_args) do
            {:ok, pid} ->
              ref = Process.monitor(pid)

              partida_info = %{
                id: id,
                pid: pid,
                creador: creador_str,
                tema: tema_str,
                nivel: nivel,
                total_preguntas: total_preguntas,
                tiempo_pregunta: tiempo_pregunta,
                cliente_pid: cliente_pid,
                ref: ref
              }

              updated_partidas = Map.put(state.partidas, id, partida_info)
              updated_jugadores = Map.put(state.jugador_partida, creador_str, id)
              updated_monitores = Map.put(state.monitores, ref, id)

              new_state = %{
                state
                | contador_id: state.contador_id + 1,
                  partidas: updated_partidas,
                  jugador_partida: updated_jugadores,
                  monitores: updated_monitores
              }

              {:reply, {:ok, id, nivel}, new_state}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
        else
          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:obtener_partida, jugador}, _from, state) do
    case Map.fetch(state.jugador_partida, jugador) do
      {:ok, id} -> {:reply, {:ok, id}, state}
      :error -> {:reply, {:error, :partida_no_encontrada}, state}
    end
  end

  def handle_call({:obtener_pid_partida, jugador_o_id}, _from, state) do
    pid =
      case Map.fetch(state.partidas, jugador_o_id) do
        {:ok, info} ->
          info.pid

        :error ->
          case Map.fetch(state.jugador_partida, jugador_o_id) do
            {:ok, id} ->
              get_in(state.partidas, [id, :pid])

            :error ->
              nil
          end
      end

    if pid && Process.alive?(pid) do
      {:reply, {:ok, pid}, state}
    else
      {:reply, {:error, :partida_no_encontrada}, state}
    end
  end

  def handle_call({:abandonar_partida, jugador}, _from, state) do
    case Map.fetch(state.jugador_partida, jugador) do
      {:ok, id} ->
        case Map.fetch(state.partidas, id) do
          {:ok, info} ->
            case Trivia.Partida.abandonar_partida(info.pid, jugador) do
              :ok ->
                # Limpiar registro del jugador y partida solo si se completó exitosamente
                Process.demonitor(info.ref, [:flush])
                new_partidas = Map.delete(state.partidas, id)
                new_jugadores = Map.delete(state.jugador_partida, jugador)
                new_monitores = Map.delete(state.monitores, info.ref)

                new_state = %{
                  state
                  | partidas: new_partidas,
                    jugador_partida: new_jugadores,
                    monitores: new_monitores
                }

                {:reply, :ok, new_state}

              {:error, _reason} = err ->
                {:reply, err, state}
            end

          :error ->
            {:reply, {:error, :partida_no_encontrada}, state}
        end

      :error ->
        {:reply, {:error, :jugador_sin_partida}, state}
    end
  end

  def handle_call(:listar_partidas, _from, state) do
    res =
      state.partidas
      |> Map.values()
      |> Enum.map(fn info ->
        %{id: info.id, creador: info.creador, tema: info.tema, nivel: info.nivel}
      end)

    {:reply, res, state}
  end

  @impl true
  def handle_cast({:reportar_pid, id, nuevo_pid}, state) do
    case Map.fetch(state.partidas, id) do
      {:ok, info} ->
        # Verificar si se trata de un reinicio por choque
        if info.pid != nil and info.pid != nuevo_pid do
          # Reinicio por falla anormal detectado
          Process.demonitor(info.ref, [:flush])
          nueva_ref = Process.monitor(nuevo_pid)

          updated_info = %{info | pid: nuevo_pid, ref: nueva_ref}
          new_partidas = Map.put(state.partidas, id, updated_info)
          new_monitores = state.monitores |> Map.delete(info.ref) |> Map.put(nueva_ref, id)

          # Notificar al cliente creador
          notificar_reinicio(info.cliente_pid, id)

          {:noreply, %{state | partidas: new_partidas, monitores: new_monitores}}
        else
          # Registro inicial del PID si aún no estaba asignado
          nueva_ref = if info.ref, do: info.ref, else: Process.monitor(nuevo_pid)
          updated_info = %{info | pid: nuevo_pid, ref: nueva_ref}
          new_partidas = Map.put(state.partidas, id, updated_info)
          new_monitores = Map.put(state.monitores, nueva_ref, id)
          {:noreply, %{state | partidas: new_partidas, monitores: new_monitores}}
        end

      :error ->
        # La partida reportó antes de que se completara el call en el gestor (asincronía)
        {:noreply, state}
    end
  end

  def handle_cast({:partida_finalizada, id, creador}, state) do
    creador_str = to_string(creador)

    new_jugadores =
      case Map.fetch(state.jugador_partida, creador_str) do
        {:ok, ^id} -> Map.delete(state.jugador_partida, creador_str)
        _ -> state.jugador_partida
      end

    {:noreply, %{state | jugador_partida: new_jugadores}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitores, ref) do
      {nil, _} ->
        {:noreply, state}

      {id, remaining_monitores} ->
        case Map.fetch(state.partidas, id) do
          {:ok, info} ->
            if reason in [:normal, :shutdown] do
              # Terminación normal o voluntaria: remover la partida definitivamente
              new_partidas = Map.delete(state.partidas, id)

              new_jugadores =
                case Map.fetch(state.jugador_partida, info.creador) do
                  {:ok, ^id} -> Map.delete(state.jugador_partida, info.creador)
                  _ -> state.jugador_partida
                end

              new_state = %{
                state
                | partidas: new_partidas,
                  jugador_partida: new_jugadores,
                  monitores: remaining_monitores
              }

              {:noreply, new_state}
            else
              # Terminación anormal: DynamicSupervisor reiniciará la partida.
              # Mantenemos el registro del creador para que conserve su pertenencia
              # a la partida cuando se restablezca.
              {:noreply, %{state | monitores: remaining_monitores}}
            end

          :error ->
            {:noreply, %{state | monitores: remaining_monitores}}
        end
    end
  end

  # ── Helpers privados ────────────────────────────────────────────────

  defp resolver_nivel(state, creador, tema) do
    case obtener_historial_seguro(state.persistencia) do
      {:ok, historial} ->
        puntaje = Nivel.puntaje_por_tema(historial, creador, tema)
        nivel = Nivel.calcular(puntaje)
        {:ok, nivel}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp obtener_historial_seguro(persistencia) do
    try do
      case Persistencia.obtener_historial(persistencia) do
        historial when is_list(historial) ->
          {:ok, historial}

        {:error, reason} ->
          {:error, reason}
      end
    catch
      :exit, reason ->
        {:error, {:persistencia_no_disponible, reason}}
    end
  end

  # Primer número de id libre: el mayor "P-<n>" del historial y de las partidas
  # aún vivas en el DynamicSupervisor, más uno (o @primer_id si no hay ninguno).
  # Si el historial no se puede leer, no se adivina: se registra el error y se usa
  # el reloj de pared (ms), que siempre supera a los ids secuenciales previos.
  defp contador_inicial(persistencia, supervisor) do
    ids_vivos = ids_partidas_vivas(supervisor)

    case obtener_historial_seguro(persistencia) do
      {:ok, historial} ->
        ids_historial = Enum.map(historial, fn registro -> Map.get(registro, "id") end)
        max_numero_id(ids_historial ++ ids_vivos) + 1

      {:error, reason} ->
        contador = max(System.os_time(:millisecond), max_numero_id(ids_vivos) + 1)

        Logger.error(
          "GestorPartidas: no se pudo leer el historial (#{inspect(reason)}); " <>
            "se usará P-#{contador} como primer id para no reutilizar ids existentes"
        )

        contador
    end
  end

  defp ids_partidas_vivas(supervisor) do
    supervisor
    |> SupervisorPartidas.listar_hijos()
    |> Enum.flat_map(fn pid ->
      try do
        [Trivia.Partida.obtener_estado(pid).id]
      catch
        :exit, _ -> []
      end
    end)
  catch
    :exit, _ -> []
  end

  defp max_numero_id(ids) do
    Enum.reduce(ids, @primer_id - 1, fn id, acc ->
      case numero_id(id) do
        nil -> acc
        n -> max(n, acc)
      end
    end)
  end

  defp numero_id("P-" <> numero) do
    case Integer.parse(numero) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp numero_id(_), do: nil

  defp validar_banco(persistencia, tema, nivel, total_preguntas) do
    case cargar_banco_seguro(persistencia) do
      {:ok, preguntas} ->
        preguntas_tema = BancoPreguntas.filtrar_por_tema(preguntas, tema)

        if preguntas_tema == [] do
          {:error, :tema_inexistente}
        else
          reparto = Nivel.reparto(nivel, total_preguntas)

          insuficientes =
            Enum.any?([:basico, :intermedio, :avanzado], fn lvl ->
              req = Map.get(reparto, lvl, 0)
              disp = length(BancoPreguntas.filtrar_por_nivel(preguntas_tema, lvl))
              disp < req
            end)

          if insuficientes do
            {:error, :preguntas_insuficientes}
          else
            :ok
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cargar_banco_seguro(persistencia) do
    try do
      BancoPreguntas.cargar_banco(persistencia)
    catch
      :exit, reason ->
        {:error, {:persistencia_no_disponible, reason}}
    end
  end

  defp notificar_reinicio(nil, _id), do: :ok

  defp notificar_reinicio(cliente_pid, id) when is_pid(cliente_pid) do
    # El cliente puede vivir en otro nodo: `Process.alive?/1` no acepta PIDs
    # remotos, así que se envía directamente (seguro aunque el proceso no exista).
    mensaje = String.replace(@aviso_reinicio_plantilla, "%{id}", id)
    Process.send(cliente_pid, {:partida_reiniciada, id, mensaje}, [:noconnect])
    Process.send(cliente_pid, {:notificacion, mensaje}, [:noconnect])
    :ok
  end
end
