defmodule Trivia.Receptor do
  @moduledoc """
  Proceso del CLIENTE dedicado a recibir y mostrar las notificaciones asíncronas
  enviadas por el servidor y las partidas (sección 8.3).

  Corre en un proceso separado del que lee el teclado en la consola del jugador,
  de modo que las preguntas, cierres de ronda, rankings finales y avisos de
  reinicio o desconexión lleguen de inmediato sin quedar bloqueados por `IO.gets`.
  """
  use GenServer

  @max_notificaciones 100

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Inicia el proceso receptor de notificaciones del cliente.

  Opciones:
    * `:suscriptor` – PID opcional al que se reenvían los eventos recibidos `{:evento_receptor, msg}`.
    * `:silencioso` – cuando es `true`, omite la impresión por pantalla (útil en pruebas).
    * `:name` – nombre opcional para registrar el proceso.
  """
  def start_link(opts \\ []) do
    {name, init_opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc """
  Retorna la lista de notificaciones recibidas en orden cronológico.
  """
  def obtener_notificaciones(receptor) do
    GenServer.call(receptor, :obtener_notificaciones)
  end

  @doc """
  Registra o cambia el PID suscriptor que recibe copias de cada notificación.
  """
  def suscribir(receptor, pid) when is_pid(pid) do
    GenServer.call(receptor, {:suscribir, pid})
  end

  # ── Funciones puras de formateo (secciones 4.2, 6.2, 7 y 8.5) ──────

  @doc """
  Formatea una notificación entrante para su presentación en la consola del jugador.
  """
  def formatear_notificacion({:nueva_pregunta, info}) when is_map(info) do
    formatear_pregunta(info)
  end

  def formatear_notificacion({:fin_ronda, info}) when is_map(info) do
    formatear_fin_ronda(info)
  end

  def formatear_notificacion({:fin_partida, info}) when is_map(info) do
    formatear_fin_partida(info)
  end

  def formatear_notificacion({:partida_iniciada, info}) when is_map(info) do
    jugadores = Enum.join(info[:jugadores] || [], ", ")

    """
    ═══ Partida #{info[:partida_id]} iniciada (#{info[:tema]}, nivel #{info[:nivel]}) ═══
    Jugadores: #{jugadores} | Preguntas: #{info[:total]} | Tiempo por pregunta: #{info[:tiempo_limite]}s
    """
    |> String.trim_trailing()
  end

  def formatear_notificacion({:partida_reiniciada, _id, mensaje}) when is_binary(mensaje) do
    mensaje
  end

  def formatear_notificacion({:notificacion, mensaje}) when is_binary(mensaje) do
    mensaje
  end

  def formatear_notificacion({:conexion, {:ok, {:conectado, usuario, :registrado}}}) do
    "Usuario '#{usuario}' registrado y conectado exitosamente."
  end

  def formatear_notificacion({:conexion, {:ok, {:conectado, usuario, :autenticado}}}) do
    "Sesión iniciada como '#{usuario}'."
  end

  def formatear_notificacion({:conexion, {:ok, :desconectado}}) do
    "Sesión cerrada correctamente."
  end

  def formatear_notificacion({:conexion, {:error, motivo}}) do
    "Error de conexión: #{formatear_error(motivo)}"
  end

  def formatear_notificacion({:estado_partida, {:partida_creada, id, nivel}}) do
    "Partida creada: #{id} (nivel #{nivel}). Agrega al menos 2 bots con add_bot " <>
      "(u otros jugadores se unen con join_game #{id}) y ejecuta start_game."
  end

  def formatear_notificacion({:estado_partida, {:unido_partida, info}}) do
    "Te uniste a la partida #{info.id} de #{info.creador} (#{info.tema}, nivel #{info.nivel}). " <>
      "Jugadores: #{Enum.join(info.jugadores, ", ")}. Espera a que #{info.creador} ejecute start_game."
  end

  def formatear_notificacion({:jugador_unido, info}) when is_map(info) do
    "#{info[:jugador]} se unió a la partida #{info[:partida_id]}. " <>
      "Jugadores: #{Enum.join(info[:jugadores] || [], ", ")}."
  end

  def formatear_notificacion({:jugador_salio, info}) when is_map(info) do
    "#{info[:jugador]} salió de la partida #{info[:partida_id]}."
  end

  def formatear_notificacion({:partida_cancelada, info}) when is_map(info) do
    "#{info[:creador]} canceló la partida #{info[:partida_id]}. Ya puedes crear o unirte a otra."
  end

  def formatear_notificacion({:estado_partida, {:bot_agregado, nombre}}) do
    "Bot agregado a la partida: #{nombre}."
  end

  def formatear_notificacion({:estado_partida, :partida_iniciada}) do
    "La partida ha comenzado."
  end

  def formatear_notificacion({:estado_partida, :partida_abandonada}) do
    "Has abandonado la partida."
  end

  def formatear_notificacion({:estado_partida, :respuesta_registrada}) do
    "Respuesta registrada."
  end

  def formatear_notificacion({:servidor_desconectado, nodo}) do
    "Aviso: Se perdió la conexión con el servidor (#{nodo})."
  end

  def formatear_notificacion(otro) do
    inspect(otro)
  end

  @doc """
  Formatea una pregunta siguiendo el formato sugerido en la sección 6.2.
  """
  def formatear_pregunta(info) when is_map(info) do
    numero = info[:numero] || info["numero"]
    total = info[:total] || info["total"]
    tema = info[:tema] || info["tema"]
    nivel = info[:nivel] || info["nivel"]
    enunciado = info[:enunciado] || info["enunciado"]
    opciones = info[:opciones] || info["opciones"] || %{}
    tiempo = info[:tiempo_limite] || info["tiempo_limite"]

    op_a = opciones["A"] || opciones[:A] || ""
    op_b = opciones["B"] || opciones[:B] || ""
    op_c = opciones["C"] || opciones[:C] || ""
    op_d = opciones["D"] || opciones[:D] || ""

    """
    ═══ Pregunta #{numero} de #{total} - #{tema} - Nivel #{nivel} ═══
    #{enunciado}
      A) #{op_a}      B) #{op_b}      C) #{op_c}      D) #{op_d}
    Tiempo: #{tiempo} segundos
    """
    |> String.trim_trailing()
  end

  @doc """
  Formatea el cierre de una ronda siguiendo la sección 6.2.
  """
  def formatear_fin_ronda(info) when is_map(info) do
    correcta = info[:respuesta_correcta] || info["respuesta_correcta"]
    puntos_ronda = info[:puntos_ronda] || info["puntos_ronda"] || %{}
    acumulados = info[:puntajes_acumulados] || info["puntajes_acumulados"] || %{}

    lineas_jugadores =
      acumulados
      |> Enum.sort_by(fn {jugador, total} -> {-total, to_string(jugador)} end)
      |> Enum.map(fn {jugador, total} ->
        delta = Map.get(puntos_ronda, jugador, 0)
        signo = if delta > 0, do: "+#{delta}", else: "#{delta}"

        "  #{String.pad_trailing(to_string(jugador), 10)} #{String.pad_leading(signo, 4)}   (total #{total})"
      end)
      |> Enum.join("\n")

    """
    Respuesta correcta: #{correcta}

    #{lineas_jugadores}
    """
    |> String.trim_trailing()
  end

  @doc """
  Formatea el resultado y ranking final de la partida siguiendo la sección 7.
  """
  def formatear_fin_partida(info) when is_map(info) do
    id = info[:partida_id] || info["partida_id"]
    tema = info[:tema] || info["tema"]
    nivel = info[:nivel] || info["nivel"]
    ganador = info[:ganador] || info["ganador"]
    ranking = info[:ranking] || info["ranking"] || []

    filas =
      Enum.map_join(ranking, "\n", fn entrada ->
        puesto = entrada[:puesto] || entrada["puesto"]
        jugador = to_string(entrada[:jugador] || entrada["jugador"])
        puntaje = entrada[:puntaje] || entrada["puntaje"]

        "#{String.pad_trailing(to_string(puesto), 4)} #{String.pad_trailing(jugador, 10)} #{String.pad_leading(to_string(puntaje), 6)}"
      end)

    """
    ═══ Fin de la partida #{id} (#{tema}, nivel #{nivel}) ═══
    #    Jugador   Puntaje
    #{filas}

    Ganador: #{ganador}
    """
    |> String.trim_trailing()
  end

  @doc """
  Formatea la respuesta del comando `score` según la sección 4.2.
  """
  def formatear_score(stats) when is_map(stats) do
    usuario = stats[:usuario] || stats["usuario"]
    total = stats[:puntaje_total] || stats["puntaje_total"] || 0
    partidas = stats[:partidas_jugadas] || stats["partidas_jugadas"] || 0
    temas = stats[:temas] || stats["temas"] || []

    cuerpo_temas =
      if temas == [] do
        "Sin partidas registradas aún."
      else
        filas =
          Enum.map_join(temas, "\n", fn t ->
            tema = String.pad_trailing(to_string(t[:tema] || t["tema"]), 11)
            pts = String.pad_leading(to_string(t[:puntaje] || t["puntaje"]), 7)
            niv = to_string(t[:nivel] || t["nivel"])
            "#{tema} #{pts}   #{niv}"
          end)

        "Tema        Puntaje   Nivel\n" <> filas
      end

    """
    === #{usuario} ===
    Puntaje acumulado: #{total}
    Partidas jugadas: #{partidas}

    #{cuerpo_temas}
    """
    |> String.trim_trailing()
  end

  @doc """
  Formatea la respuesta del comando `games`: partidas en espera para unirse.
  """
  def formatear_partidas([]),
    do: "No hay partidas en espera. Crea una con create_game."

  def formatear_partidas(partidas) when is_list(partidas) do
    filas =
      Enum.map(partidas, fn p ->
        "  #{p.id}  #{p.tema} (#{p.nivel})  creada por #{p.creador}  " <>
          "jugadores: #{Enum.join(p.jugadores, ", ")}"
      end)

    Enum.join(["Partidas en espera (únete con join_game <id>):" | filas], "\n")
  end

  @doc """
  Formatea la respuesta del comando `ranking [tema]` según la sección 4.2.
  """
  def formatear_ranking(tema, entradas) when is_list(entradas) do
    titulo =
      if tema in [nil, ""] do
        "=== Ranking global ==="
      else
        "=== Ranking (#{tema}) ==="
      end

    if entradas == [] do
      "#{titulo}\nSin resultados registrados."
    else
      filas =
        Enum.map_join(entradas, "\n", fn e ->
          puesto = String.pad_trailing(to_string(e[:puesto] || e["puesto"]), 4)
          jugador = String.pad_trailing(to_string(e[:jugador] || e["jugador"]), 11)
          pts = String.pad_leading(to_string(e[:puntaje] || e["puntaje"]), 7)
          partidas = String.pad_leading(to_string(e[:partidas] || e["partidas"] || 1), 10)
          "#{puesto} #{jugador} #{pts} #{partidas}"
        end)

      """
      #{titulo}
      #    Jugador     Puntaje    Partidas
      #{filas}
      """
      |> String.trim_trailing()
    end
  end

  @doc """
  Traduce códigos de error del servidor a mensajes legibles para el jugador (sección 10).
  """
  def formatear_error(:sesion_no_iniciada),
    do: "Debes iniciar sesión primero con: connect <usuario> <clave>."

  def formatear_error(:clave_incorrecta),
    do: "La clave ingresada no coincide con el usuario registrado."

  def formatear_error(:sesion_activa),
    do: "El usuario ya tiene una sesión abierta en otro cliente."

  def formatear_error(:cliente_ya_conectado),
    do: "Este cliente ya tiene una sesión iniciada. Usa disconnect antes de cambiar de usuario."

  def formatear_error(:usuario_reservado),
    do: "El prefijo 'bot_' está reservado para jugadores automáticos."

  def formatear_error(:usuario_invalido),
    do: "Nombre de usuario inválido (no debe estar vacío ni contener espacios)."

  def formatear_error(:clave_invalida),
    do: "Clave inválida."

  def formatear_error(:servidor_no_disponible),
    do: "El servidor no está disponible."

  def formatear_error(:servicio_no_disponible),
    do: "El servicio del servidor no está disponible en este momento."

  def formatear_error(:jugador_en_partida),
    do: "Ya participas en una partida activa."

  def formatear_error(:tema_inexistente),
    do: "El tema solicitado no existe en el banco de preguntas."

  def formatear_error(:preguntas_insuficientes),
    do: "No hay suficientes preguntas del tema para el reparto por nivel."

  def formatear_error(:parametros_invalidos),
    do: "Parámetros inválidos. Verifica tema, cantidad de preguntas y tiempo."

  def formatear_error(:jugador_sin_partida),
    do: "No estás en ninguna partida activa."

  def formatear_error(:partida_llena),
    do: "La partida ya alcanzó el máximo de 4 jugadores."

  def formatear_error(:partida_en_curso),
    do: "No se pueden agregar bots porque la partida ya está en curso."

  def formatear_error(:partida_ya_iniciada),
    do: "La partida ya fue iniciada."

  def formatear_error(:minimo_dos_bots),
    do:
      "Debes agregar al menos 2 bots antes de iniciar la partida (add_bot <facil|dificil>) " <>
        "o esperar a que otro jugador se una."

  def formatear_error(:solo_creador),
    do: "Solo el creador de la partida puede agregar bots o iniciarla."

  def formatear_error(:partida_inexistente),
    do: "No existe una partida activa con ese id. Usa games para ver las partidas en espera."

  def formatear_error(:dificultad_invalida),
    do: "Dificultad inválida. Usa 'facil' o 'dificil'."

  def formatear_error(:respuesta_invalida),
    do: "Respuesta inválida. La letra debe ser A, B, C o D."

  def formatear_error(:ronda_no_abierta),
    do: "No hay una ronda abierta en este momento."

  def formatear_error(:tiempo_agotado),
    do: "El tiempo de la ronda ya venció."

  def formatear_error(:ya_respondio),
    do: "Ya enviaste tu primera respuesta en esta ronda."

  def formatear_error(:partida_no_iniciada),
    do: "La partida aún no ha sido iniciada."

  def formatear_error(:partida_finalizada),
    do: "La partida ya finalizó."

  def formatear_error(:comando_invalido),
    do: "Comando inválido."

  def formatear_error(otro), do: "Error: #{inspect(otro)}"

  # ── GenServer Callbacks ─────────────────────────────────────────────

  @impl true
  def init(opts) do
    state = %{
      suscriptor: Keyword.get(opts, :suscriptor),
      silencioso: Keyword.get(opts, :silencioso, false),
      notificaciones: []
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:obtener_notificaciones, _from, state) do
    {:reply, Enum.reverse(state.notificaciones), state}
  end

  def handle_call({:suscribir, pid}, _from, state) do
    {:reply, :ok, %{state | suscriptor: pid}}
  end

  @impl true
  def handle_info(mensaje, state) do
    # Defensa adicional: si llega una pregunta, asegurarse de que jamás contenga
    # claves de respuesta antes de reenviarla o mostrarla.
    mensaje_limpio = limpiar_notificacion(mensaje)

    if is_pid(state.suscriptor) do
      send(state.suscriptor, {:notificacion_cliente, mensaje_limpio})
    end

    if not state.silencioso do
      IO.puts("\n" <> formatear_notificacion(mensaje_limpio))
    end

    notificaciones_actualizadas =
      [mensaje_limpio | state.notificaciones]
      |> Enum.take(@max_notificaciones)

    {:noreply, %{state | notificaciones: notificaciones_actualizadas}}
  end

  defp limpiar_notificacion({:nueva_pregunta, info}) when is_map(info) do
    {:nueva_pregunta,
     Map.drop(info, [:respuesta, "respuesta", :respuesta_correcta, "respuesta_correcta"])}
  end

  defp limpiar_notificacion(otro), do: otro
end
