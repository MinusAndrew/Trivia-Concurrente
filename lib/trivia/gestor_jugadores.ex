defmodule Trivia.GestorJugadores do
  @moduledoc """
  GenServer del SERVIDOR responsable del registro de jugadores, las sesiones de
  los clientes conectados y las consultas de estadísticas (`score` y `ranking`).

  ## Sesiones

  Una sesión asocia un nombre de usuario con dos procesos del nodo del cliente:

    * `cliente` – el proceso que envía las peticiones (`Trivia.Cliente`). Es la
      identidad de la sesión: el servidor la obtiene del `from` de
      `GenServer.call/3`, que fija el runtime y que el cliente no puede falsificar.
    * `receptor` – el proceso que recibe las notificaciones (`Trivia.Receptor`).

  El gestor monitorea el proceso `cliente`. Si desaparece (cierre del cliente,
  caída del proceso o caída del nodo, que llega como `:noconnection`), la sesión
  se cierra y se aplica la sección 6.5: la partida del jugador se abandona a
  través de `Trivia.GestorPartidas`, que conserva la persistencia y reintentos
  existentes. Así no quedan sesiones obsoletas registradas.

  ## Reglas de conexión (sección 4.1)

    * Si el usuario no existe, se registra automáticamente en `users.json`
      (a través de `Trivia.Persistencia`, único proceso que escribe archivos).
    * Si existe y la clave no coincide, se rechaza (`:clave_incorrecta`).
    * Un usuario no puede tener dos sesiones desde clientes distintos (`:sesion_activa`).
    * Un mismo cliente no puede abrir sesión con dos usuarios (`:cliente_ya_conectado`).
    * El prefijo `bot_` está reservado (`:usuario_reservado`).
  """
  use GenServer

  alias Trivia.GestorPartidas
  alias Trivia.Nivel
  alias Trivia.Persistencia

  # ── Public API (uso interno del servidor) ───────────────────────────

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Abre (o restablece) la sesión de `usuario` para el proceso `cliente_pid`.

  Retorna `{:ok, :registrado}` si el usuario se creó, `{:ok, :autenticado}` si ya
  existía, o `{:error, motivo}`.
  """
  def conectar(gestor, usuario, clave, cliente_pid, receptor_pid, servidor_pid \\ nil) do
    GenServer.call(
      gestor,
      {:conectar, usuario, clave, cliente_pid, receptor_pid, servidor_pid}
    )
  end

  @doc """
  Cierra la sesión asociada a `cliente_pid` y abandona su partida (sección 6.5).
  """
  def desconectar(gestor, cliente_pid) do
    GenServer.call(gestor, {:desconectar, cliente_pid}, 15_000)
  end

  @doc """
  Retorna la sesión asociada a `cliente_pid`: `{:ok, %{usuario: ..., receptor: ...}}`
  o `{:error, :sesion_no_iniciada}`.
  """
  def sesion(gestor, cliente_pid) do
    GenServer.call(gestor, {:sesion, cliente_pid})
  end

  @doc """
  Lista los usuarios con sesión activa (diagnóstico y pruebas; no se expone a clientes).
  """
  def usuarios_conectados(gestor \\ __MODULE__) do
    GenServer.call(gestor, :usuarios_conectados)
  end

  @doc """
  Estadísticas del jugador calculadas desde el historial (comando `score`).
  """
  def score(gestor, usuario) do
    GenServer.call(gestor, {:score, usuario})
  end

  @doc """
  Ranking histórico global o filtrado por tema (comando `ranking [tema]`).
  """
  def ranking(gestor, tema \\ nil) do
    GenServer.call(gestor, {:ranking, tema})
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────

  @impl true
  def init(opts) do
    state = %{
      persistencia: Keyword.get(opts, :persistencia, Persistencia),
      gestor_partidas: Keyword.get(opts, :gestor_partidas, GestorPartidas),
      # usuario => %{
      #   cliente: pid,
      #   receptor: pid,
      #   servidor: pid | nil,
      #   ref_cliente: reference,
      #   ref_servidor: reference | nil
      # }
      sesiones: %{},
      # cliente_pid => usuario (sesiones activas)
      clientes: %{},
      # monitor_ref =>
      #   {:cliente, usuario, cliente_pid}
      #   | {:servidor, usuario, servidor_pid}
      #   | {:cliente_desconectado, usuario, cliente_pid}
      monitores: %{},
      # cliente_pid => %{usuario: usuario, ref: reference}
      clientes_desconectados: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:conectar, usuario, clave, cliente_pid, receptor_pid}, from, state) do
    handle_call({:conectar, usuario, clave, cliente_pid, receptor_pid, nil}, from, state)
  end

  def handle_call(
        {:conectar, usuario, clave, cliente_pid, receptor_pid, servidor_pid},
        _from,
        state
      ) do
    state = limpiar_sesiones_obsoletas(state, cliente_pid, servidor_pid)

    cond do
      not usuario_valido?(usuario) ->
        {:reply, {:error, :usuario_invalido}, state}

      Nivel.es_bot?(usuario) ->
        {:reply, {:error, :usuario_reservado}, state}

      not clave_valida?(clave) ->
        {:reply, {:error, :clave_invalida}, state}

      not is_pid(cliente_pid) or not is_pid(receptor_pid) ->
        {:reply, {:error, :comando_invalido}, state}

      Map.get(state.clientes, cliente_pid, usuario) != usuario ->
        {:reply, {:error, :cliente_ya_conectado}, state}

      sesion_de_otro_cliente?(state, usuario, cliente_pid) ->
        {:reply, {:error, :sesion_activa}, state}

      true ->
        case autenticar_o_registrar(state.persistencia, usuario, clave) do
          {:ok, tipo} ->
            nuevo_state =
              abrir_sesion(state, usuario, cliente_pid, receptor_pid, servidor_pid)

            {:reply, {:ok, tipo}, nuevo_state}

          {:error, _motivo} = error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:desconectar, cliente_pid}, _from, state) do
    state = limpiar_sesiones_obsoletas(state)

    case Map.fetch(state.clientes, cliente_pid) do
      {:ok, usuario} -> {:reply, :ok, cerrar_sesion_cliente(state, usuario, cliente_pid)}
      :error -> {:reply, {:error, :sesion_no_iniciada}, state}
    end
  end

  def handle_call({:sesion, cliente_pid}, _from, state) do
    state = limpiar_sesiones_obsoletas(state)

    with {:ok, usuario} <- Map.fetch(state.clientes, cliente_pid),
         {:ok, %{cliente: ^cliente_pid} = sesion} <- Map.fetch(state.sesiones, usuario) do
      {:reply, {:ok, %{usuario: usuario, receptor: sesion.receptor}}, state}
    else
      _ -> {:reply, {:error, :sesion_no_iniciada}, state}
    end
  end

  def handle_call(:usuarios_conectados, _from, state) do
    state = limpiar_sesiones_obsoletas(state)
    {:reply, state.sesiones |> Map.keys() |> Enum.sort(), state}
  end

  def handle_call({:score, usuario}, _from, state) do
    respuesta =
      with {:ok, historial} <- obtener_historial(state.persistencia) do
        {:ok, Nivel.estadisticas_jugador(historial, usuario)}
      end

    {:reply, respuesta, state}
  end

  def handle_call({:ranking, tema}, _from, state) do
    respuesta =
      with {:ok, historial} <- obtener_historial(state.persistencia) do
        {:ok, Nivel.ranking_historico(historial, tema)}
      end

    {:reply, respuesta, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.fetch(state.monitores, ref) do
      {:ok, {:cliente, usuario, ^pid}} ->
        # El proceso del cliente desapareció (cierre, caída o desconexión de red
        # del nodo cliente): cerrar su sesión y aplicar la sección 6.5 sobre su partida.
        {:noreply, cerrar_sesion_cliente(state, usuario, pid)}

      {:ok, {:servidor, usuario, ^pid}} ->
        # El proceso Trivia.Servidor terminó mientras el gestor de sesiones sigue vivo:
        # liberar la sesión asociada a ese servidor para no retener sesiones obsoletas,
        # sin abortar partidas activas ni afectar a otros clientes.
        {:noreply, liberar_sesion_por_caida_servidor(state, usuario, pid)}

      {:ok, {:cliente_desconectado, _usuario, ^pid}} ->
        # Un cliente cuya sesión había quedado liberada por caída del servidor
        # terminó definitivamente sin reconectarse: limpiar y aplicar sección 6.5.
        {:noreply, limpiar_cliente_desconectado(state, pid, true)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_otro, state), do: {:noreply, state}

  # ── Helpers privados ────────────────────────────────────────────────

  defp usuario_valido?(usuario) when is_binary(usuario) do
    usuario != "" and not String.match?(usuario, ~r/\s/u) and String.valid?(usuario)
  end

  defp usuario_valido?(_), do: false

  defp clave_valida?(clave) when is_binary(clave), do: clave != "" and String.valid?(clave)
  defp clave_valida?(_), do: false

  defp sesion_de_otro_cliente?(state, usuario, cliente_pid) do
    case Map.fetch(state.sesiones, usuario) do
      {:ok, %{cliente: ^cliente_pid}} -> false
      {:ok, _otra} -> true
      :error -> false
    end
  end

  defp autenticar_o_registrar(persistencia, usuario, clave) do
    try do
      case Persistencia.listar_usuarios(persistencia) do
        usuarios when is_list(usuarios) ->
          case Enum.find(usuarios, fn u -> to_string(u["usuario"] || u["nombre"]) == usuario end) do
            nil -> registrar(persistencia, usuario, clave)
            %{"clave" => guardada} -> verificar_clave(to_string(guardada), clave)
            _sin_clave -> {:error, :clave_incorrecta}
          end

        {:error, motivo} ->
          {:error, {:persistencia, motivo}}
      end
    catch
      :exit, _motivo -> {:error, :persistencia_no_disponible}
    end
  end

  defp verificar_clave(clave, clave), do: {:ok, :autenticado}
  defp verificar_clave(_guardada, _recibida), do: {:error, :clave_incorrecta}

  defp registrar(persistencia, usuario, clave) do
    case Persistencia.registrar_usuario(usuario, clave, persistencia) do
      :ok -> {:ok, :registrado}
      {:error, motivo} -> {:error, motivo}
    end
  end

  # Purga de forma idempotente cualquier sesión cuyo proceso servidor haya
  # terminado (o haya sido reemplazado para el mismo cliente) antes de que el
  # mensaje :DOWN haya sido procesado, o cuyo proceso cliente local haya muerto.
  defp limpiar_sesiones_obsoletas(state, cliente_pid \\ nil, servidor_pid \\ nil) do
    Enum.reduce(Map.to_list(state.sesiones), state, fn {usuario, sesion}, acc ->
      cond do
        is_pid(sesion.servidor) and not Process.alive?(sesion.servidor) ->
          liberar_sesion_por_caida_servidor(acc, usuario, sesion.servidor)

        is_pid(cliente_pid) and sesion.cliente == cliente_pid and is_pid(servidor_pid) and
          is_pid(sesion.servidor) and sesion.servidor != servidor_pid ->
          liberar_sesion_por_caida_servidor(acc, usuario, sesion.servidor)

        node(sesion.cliente) == node() and not Process.alive?(sesion.cliente) ->
          cerrar_sesion_cliente(acc, usuario, sesion.cliente)

        true ->
          acc
      end
    end)
  end

  defp abrir_sesion(state, usuario, cliente_pid, receptor_pid, servidor_pid) do
    # 1. Si este cliente tenía una sesión previa liberada tras caída del servidor:
    #    - Si reconecta con un usuario distinto, abandonar la partida del usuario anterior.
    #    - Si reconecta con el mismo usuario, conservar su partida activa.
    state =
      case Map.fetch(state.clientes_desconectados, cliente_pid) do
        {:ok, %{usuario: usuario_previo}} ->
          abandonar_previo? =
            usuario_previo != usuario and not Map.has_key?(state.sesiones, usuario_previo)

          limpiar_cliente_desconectado(state, cliente_pid, abandonar_previo?)

        :error ->
          state
      end

    # 2. Si otro cliente desconectado tenía reservado este mismo usuario tras caída
    #    del servidor, limpiar ese registro obsoleto y cerrar su partida anterior
    #    para que el nuevo cliente inicie limpio.
    state =
      Enum.reduce(Map.to_list(state.clientes_desconectados), state, fn
        {otro_pid, %{usuario: ^usuario}}, acc when otro_pid != cliente_pid ->
          limpiar_cliente_desconectado(acc, otro_pid, true)

        _, acc ->
          acc
      end)

    # 3. Registrar o actualizar la sesión activa para {usuario, cliente_pid}.
    case Map.fetch(state.sesiones, usuario) do
      {:ok, %{cliente: ^cliente_pid} = sesion} ->
        monitores =
          if sesion.ref_servidor do
            Process.demonitor(sesion.ref_servidor, [:flush])
            Map.delete(state.monitores, sesion.ref_servidor)
          else
            state.monitores
          end

        {ref_servidor, monitores} =
          if is_pid(servidor_pid) do
            ref_srv = Process.monitor(servidor_pid)
            {ref_srv, Map.put(monitores, ref_srv, {:servidor, usuario, servidor_pid})}
          else
            {nil, monitores}
          end

        sesion_actualizada = %{
          sesion
          | receptor: receptor_pid,
            servidor: servidor_pid,
            ref_servidor: ref_servidor
        }

        %{
          state
          | sesiones: Map.put(state.sesiones, usuario, sesion_actualizada),
            monitores: monitores
        }

      :error ->
        ref_cliente = Process.monitor(cliente_pid)

        monitores =
          Map.put(state.monitores, ref_cliente, {:cliente, usuario, cliente_pid})

        {ref_servidor, monitores} =
          if is_pid(servidor_pid) do
            ref_srv = Process.monitor(servidor_pid)
            {ref_srv, Map.put(monitores, ref_srv, {:servidor, usuario, servidor_pid})}
          else
            {nil, monitores}
          end

        %{
          state
          | sesiones:
              Map.put(state.sesiones, usuario, %{
                cliente: cliente_pid,
                receptor: receptor_pid,
                servidor: servidor_pid,
                ref_cliente: ref_cliente,
                ref_servidor: ref_servidor
              }),
            clientes: Map.put(state.clientes, cliente_pid, usuario),
            monitores: monitores
        }
    end
  end

  # Cierra de forma idempotente la sesión perteneciente exclusivamente a
  # `{usuario, cliente_pid}` y aplica la sección 6.5 sobre su partida.
  defp cerrar_sesion_cliente(state, usuario, cliente_pid) do
    case Map.fetch(state.sesiones, usuario) do
      {:ok, %{cliente: ^cliente_pid} = sesion} ->
        Process.demonitor(sesion.ref_cliente, [:flush])

        if sesion.ref_servidor do
          Process.demonitor(sesion.ref_servidor, [:flush])
        end

        monitores =
          state.monitores
          |> Map.delete(sesion.ref_cliente)
          |> Map.delete(sesion.ref_servidor)

        state =
          %{
            state
            | sesiones: Map.delete(state.sesiones, usuario),
              clientes: Map.delete(state.clientes, cliente_pid),
              monitores: monitores
          }
          |> limpiar_cliente_desconectado(cliente_pid, false)

        abandonar_partida(state.gestor_partidas, usuario)
        state

      _ ->
        # La sesión ya fue liberada o pertenece a otro cliente: no tocarla.
        state
    end
  end

  # Libera de forma idempotente una sesión cuyo proceso `Trivia.Servidor` terminó
  # mientras el proceso del cliente sigue vivo. No aborta partidas en curso para
  # permitir que el cliente se reconecte o que partidas no relacionadas continúen.
  defp liberar_sesion_por_caida_servidor(state, usuario, servidor_pid) do
    case Map.fetch(state.sesiones, usuario) do
      {:ok, %{servidor: ^servidor_pid, cliente: cliente_pid} = sesion} ->
        Process.demonitor(sesion.ref_cliente, [:flush])

        if sesion.ref_servidor do
          Process.demonitor(sesion.ref_servidor, [:flush])
        end

        monitores =
          state.monitores
          |> Map.delete(sesion.ref_cliente)
          |> Map.delete(sesion.ref_servidor)

        state =
          %{
            state
            | sesiones: Map.delete(state.sesiones, usuario),
              clientes: Map.delete(state.clientes, cliente_pid),
              monitores: monitores
          }
          |> limpiar_cliente_desconectado(cliente_pid, false)

        ref_desc = Process.monitor(cliente_pid)

        %{
          state
          | clientes_desconectados:
              Map.put(state.clientes_desconectados, cliente_pid, %{
                usuario: usuario,
                ref: ref_desc
              }),
            monitores:
              Map.put(state.monitores, ref_desc, {:cliente_desconectado, usuario, cliente_pid})
        }

      _ ->
        state
    end
  end

  defp limpiar_cliente_desconectado(state, cliente_pid, abandonar?) do
    case Map.pop(state.clientes_desconectados, cliente_pid) do
      {%{usuario: usuario, ref: ref}, restantes} ->
        Process.demonitor(ref, [:flush])

        state = %{
          state
          | clientes_desconectados: restantes,
            monitores: Map.delete(state.monitores, ref)
        }

        if abandonar? and not Map.has_key?(state.sesiones, usuario) do
          abandonar_partida(state.gestor_partidas, usuario)
        end

        state

      {nil, _} ->
        state
    end
  end

  # Sección 6.5: al desconectarse con una partida activa, esta termina y su
  # resultado se registra con los puntajes obtenidos hasta ese momento. Se
  # reutiliza la ruta de abandono existente (incluye la persistencia con
  # reintentos). Si el jugador no tiene partida no hay nada que hacer.
  defp abandonar_partida(gestor_partidas, usuario) do
    try do
      GestorPartidas.abandonar_partida(gestor_partidas, usuario)
    catch
      :exit, _motivo -> {:error, :gestor_partidas_no_disponible}
    end
  end

  defp obtener_historial(persistencia) do
    try do
      case Persistencia.obtener_historial(persistencia) do
        historial when is_list(historial) -> {:ok, historial}
        {:error, motivo} -> {:error, {:persistencia, motivo}}
      end
    catch
      :exit, _motivo -> {:error, :persistencia_no_disponible}
    end
  end
end
