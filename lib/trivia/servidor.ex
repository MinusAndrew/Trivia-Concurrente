defmodule Trivia.Servidor do
  @moduledoc """
  Punto de entrada del SERVIDOR para los clientes remotos (sección 8).

  Es el único proceso con el que habla un cliente. Se registra con un nombre
  (`Trivia.Servidor` por defecto), así que el cliente lo ubica con
  `{Trivia.Servidor, nodo_servidor}` sin conocer su PID.

  ## Protocolo

  Toda petición es `GenServer.call(servidor, {:peticion, peticion})`. Las formas
  aceptadas son:

      {:connect, usuario, clave, receptor_pid}
      :disconnect
      :score
      {:ranking, nil | tema}
      {:create_game, tema, preguntas, tiempo}
      {:add_bot, "facil" | "dificil"}
      :start_game
      :leave_game
      {:answer, letra}

  Cualquier otra forma se rechaza con `{:error, :comando_invalido}`.

  Las respuestas son autodescriptivas: `{:ok, {:conectado, usuario, :registrado | :autenticado}}`,
  `{:ok, :desconectado}`, `{:ok, {:score, estadisticas}}`, `{:ok, {:ranking, tema, entradas}}`,
  `{:ok, {:partida_creada, id, nivel}}`, `{:ok, {:bot_agregado, nombre}}`,
  `{:ok, :partida_iniciada}`, `{:ok, :partida_abandonada}`, `{:ok, :respuesta_registrada}`
  o `{:error, motivo}`.

  ## Seguridad

    * La identidad del jugador es el proceso que hace la llamada (el `from` de
      `GenServer.call/3`), que fija el runtime. Las peticiones posteriores a
      `connect` no llevan nombre de usuario, así que un cliente no puede actuar
      sobre la sesión de otro.
    * El cliente no puede enviar puntajes ni opciones internas de partida: solo
      los valores del comando, que se validan aquí y en `Trivia.GestorPartidas`
      / `Trivia.Partida`, que siguen siendo la autoridad del juego.
    * Nunca se devuelve estado interno ni PIDs de partidas.

  El servidor no contiene lógica de juego: valida la forma de la petición, ubica
  la sesión y enruta a `Trivia.GestorJugadores` o `Trivia.GestorPartidas`.
  """
  use GenServer

  alias Trivia.GestorJugadores
  alias Trivia.GestorPartidas

  @dificultades %{"facil" => :facil, "dificil" => :dificil}

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────

  @impl true
  def init(opts) do
    {:ok,
     %{
       gestor_jugadores: Keyword.get(opts, :gestor_jugadores, GestorJugadores),
       gestor_partidas: Keyword.get(opts, :gestor_partidas, GestorPartidas)
     }}
  end

  @impl true
  def handle_call({:peticion, peticion}, {cliente_pid, _tag}, state) do
    respuesta =
      case validar(peticion) do
        {:ok, {:connect, usuario, clave, receptor}} ->
          conectar(state, usuario, clave, cliente_pid, receptor)

        {:ok, comando} ->
          case protegido(fn -> GestorJugadores.sesion(state.gestor_jugadores, cliente_pid) end) do
            {:ok, %{usuario: usuario, receptor: receptor}} ->
              ejecutar(comando, usuario, receptor, cliente_pid, state)

            {:error, _motivo} = error ->
              error
          end

        {:error, _motivo} = error ->
          error
      end

    {:reply, respuesta, state}
  end

  def handle_call(_desconocida, _from, state) do
    {:reply, {:error, :comando_invalido}, state}
  end

  @impl true
  def handle_cast(_mensaje, state), do: {:noreply, state}

  @impl true
  def handle_info(_mensaje, state), do: {:noreply, state}

  # ── Validación de la forma de las peticiones ────────────────────────

  defp validar({:connect, usuario, clave, receptor})
       when is_binary(usuario) and is_binary(clave) and is_pid(receptor),
       do: {:ok, {:connect, usuario, clave, receptor}}

  defp validar(comando) when comando in [:disconnect, :score, :start_game, :leave_game],
    do: {:ok, comando}

  defp validar({:ranking, nil}), do: {:ok, {:ranking, nil}}

  defp validar({:ranking, tema}) when is_binary(tema) and tema != "",
    do: {:ok, {:ranking, tema}}

  defp validar({:create_game, tema, preguntas, tiempo}) when is_binary(tema) and tema != "",
    do: {:ok, {:create_game, tema, preguntas, tiempo}}

  defp validar({:add_bot, dificultad}) when is_binary(dificultad) do
    # La conversión a átomo se hace solo desde una lista cerrada (sin String.to_atom).
    case Map.fetch(@dificultades, String.downcase(dificultad)) do
      {:ok, atomo} -> {:ok, {:add_bot, atomo}}
      :error -> {:error, :dificultad_invalida}
    end
  end

  defp validar({:answer, letra}) when is_binary(letra), do: {:ok, {:answer, letra}}

  defp validar(_otra), do: {:error, :comando_invalido}

  # ── Enrutamiento ────────────────────────────────────────────────────

  defp conectar(state, usuario, clave, cliente_pid, receptor) do
    # El receptor debe vivir en el mismo nodo que el cliente: un cliente no
    # puede registrar como destino de notificaciones un proceso ajeno.
    if node(receptor) == node(cliente_pid) do
      servidor_pid = self()

      case protegido(fn ->
             GestorJugadores.conectar(
               state.gestor_jugadores,
               usuario,
               clave,
               cliente_pid,
               receptor,
               servidor_pid
             )
           end) do
        {:ok, tipo} -> {:ok, {:conectado, usuario, tipo}}
        {:error, _} = error -> error
      end
    else
      {:error, :receptor_invalido}
    end
  end

  defp ejecutar(:disconnect, _usuario, _receptor, cliente_pid, state) do
    case protegido(fn -> GestorJugadores.desconectar(state.gestor_jugadores, cliente_pid) end) do
      :ok -> {:ok, :desconectado}
      {:error, _} = error -> error
    end
  end

  defp ejecutar(:score, usuario, _receptor, _cliente, state) do
    case protegido(fn -> GestorJugadores.score(state.gestor_jugadores, usuario) end) do
      {:ok, estadisticas} -> {:ok, {:score, estadisticas}}
      {:error, _} = error -> error
    end
  end

  defp ejecutar({:ranking, tema}, _usuario, _receptor, _cliente, state) do
    case protegido(fn -> GestorJugadores.ranking(state.gestor_jugadores, tema) end) do
      {:ok, entradas} -> {:ok, {:ranking, tema, entradas}}
      {:error, _} = error -> error
    end
  end

  defp ejecutar({:create_game, tema, preguntas, tiempo}, usuario, receptor, _cliente, state) do
    # El PID del receptor del cliente queda registrado como oyente de la partida
    # (sección 8.3). El cliente no puede pasar ninguna otra opción de partida.
    resultado =
      protegido(fn ->
        GestorPartidas.crear_partida(
          state.gestor_partidas,
          usuario,
          tema,
          preguntas,
          tiempo,
          cliente_pid: receptor
        )
      end)

    case resultado do
      {:ok, id, nivel} -> {:ok, {:partida_creada, id, nivel}}
      {:error, motivo} -> {:error, normalizar_error(motivo)}
    end
  end

  defp ejecutar({:add_bot, dificultad}, usuario, _receptor, _cliente, state) do
    case protegido(fn ->
           GestorPartidas.agregar_bot(state.gestor_partidas, usuario, dificultad)
         end) do
      {:ok, nombre} -> {:ok, {:bot_agregado, nombre}}
      {:error, motivo} -> {:error, normalizar_error(motivo)}
    end
  end

  defp ejecutar(:start_game, usuario, _receptor, _cliente, state) do
    case protegido(fn -> GestorPartidas.iniciar_partida(state.gestor_partidas, usuario) end) do
      :ok -> {:ok, :partida_iniciada}
      {:error, motivo} -> {:error, normalizar_error(motivo)}
    end
  end

  defp ejecutar(:leave_game, usuario, _receptor, _cliente, state) do
    case protegido(fn -> GestorPartidas.abandonar_partida(state.gestor_partidas, usuario) end) do
      :ok -> {:ok, :partida_abandonada}
      {:error, motivo} -> {:error, normalizar_error(motivo)}
    end
  end

  defp ejecutar({:answer, letra}, usuario, _receptor, _cliente, state) do
    case protegido(fn -> GestorPartidas.responder(state.gestor_partidas, usuario, letra) end) do
      :ok -> {:ok, :respuesta_registrada}
      {:error, motivo} -> {:error, normalizar_error(motivo)}
    end
  end

  # Una partida o gestor que falla durante la llamada no debe tumbar el servidor.
  defp protegido(fun) do
    try do
      fun.()
    catch
      :exit, _motivo -> {:error, :servicio_no_disponible}
    end
  end

  defp normalizar_error(:partida_no_encontrada), do: :jugador_sin_partida
  defp normalizar_error({:persistencia_pendiente, _detalle}), do: :persistencia_pendiente
  defp normalizar_error({:fallo_iniciar_bot, _detalle}), do: :fallo_iniciar_bot
  defp normalizar_error({:persistencia_no_disponible, _detalle}), do: :persistencia_no_disponible
  defp normalizar_error(motivo) when is_atom(motivo), do: motivo
  defp normalizar_error(_otro), do: :error_interno
end
