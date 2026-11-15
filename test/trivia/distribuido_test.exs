defmodule Trivia.DistribuidoTest do
  use ExUnit.Case, async: false

  alias Trivia.Application, as: TriviaApp
  alias Trivia.Cliente
  alias Trivia.GestorJugadores
  alias Trivia.GestorPartidas
  alias Trivia.Persistencia
  alias Trivia.Receptor
  alias Trivia.Servidor
  alias Trivia.SupervisorPartidas

  setup_all do
    # Asegurar que epmd esté activo y el nodo actual tenga distribución Erlang habilitada
    _ = System.cmd("epmd", ["-daemon"])

    if not Node.alive?() do
      nombre_nodo = :"servidor_test_#{System.unique_integer([:positive])}@127.0.0.1"
      {:ok, _} = Node.start(nombre_nodo, :longnames)
    end

    Node.set_cookie(:trivia_test_cookie)
    :ok
  end

  setup do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "trivia_dist_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(data_dir)
    seed_path = Path.expand("data/questions.json")
    File.cp!(seed_path, Path.join(data_dir, "questions.json"))
    File.write!(Path.join(data_dir, "users.json"), "[]")
    File.write!(Path.join(data_dir, "results.log"), "")

    uid = System.unique_integer([:positive])
    pers_name = :"pers_dist_#{uid}"
    sup_name = :"sup_dist_#{uid}"
    gp_name = :"gp_dist_#{uid}"
    gj_name = :"gj_dist_#{uid}"
    srv_name = :"srv_dist_#{uid}"

    {:ok, pers_pid} = Persistencia.iniciar_link(data_dir: data_dir, name: pers_name)
    {:ok, sup_pid} = SupervisorPartidas.start_link(name: sup_name)

    {:ok, gp_pid} =
      GestorPartidas.start_link(
        name: gp_name,
        supervisor: sup_name,
        persistencia: pers_name
      )

    {:ok, gj_pid} =
      GestorJugadores.start_link(
        name: gj_name,
        persistencia: pers_name,
        gestor_partidas: gp_name
      )

    {:ok, srv_pid} =
      Servidor.start_link(
        name: srv_name,
        gestor_jugadores: gj_name,
        gestor_partidas: gp_name
      )

    for pid <- [pers_pid, sup_pid, gp_pid, gj_pid, srv_pid] do
      Process.unlink(pid)
    end

    on_exit(fn ->
      for pid <- [srv_pid, gj_pid, gp_pid, sup_pid, pers_pid] do
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid, :normal, 1000)
          catch
            :exit, _ -> :ok
          end
        end
      end

      File.rm_rf(data_dir)
    end)

    %{
      data_dir: data_dir,
      pers: pers_name,
      sup: sup_name,
      gp: gp_name,
      gj: gj_name,
      srv: srv_name,
      srv_pid: srv_pid
    }
  end

  # Helper para levantar un nodo Erlang cliente independiente usando :peer
  defp iniciar_nodo_cliente(prefijo) do
    uid = System.unique_integer([:positive])
    nombre = :"#{prefijo}_#{uid}"
    cookie = Atom.to_charlist(Node.get_cookie())

    pa_args =
      :code.get_path()
      |> Enum.flat_map(fn path -> [~c"-pa", path] end)

    args = pa_args ++ [~c"-setcookie", cookie]

    {:ok, peer_pid, client_node} =
      :peer.start_link(%{
        name: nombre,
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        args: args
      })

    Process.unlink(peer_pid)

    # Configurar el nodo remoto en rol :client (sin levantar su propio servidor)
    :ok = :erpc.call(client_node, Application, :put_env, [:trivia, :role, :client])
    {:ok, _} = :erpc.call(client_node, Application, :ensure_all_started, [:trivia])

    # Verificar que el nodo cliente NO tenga un servidor propio corriendo
    assert :erpc.call(client_node, Process, :whereis, [Trivia.Supervisor]) == nil

    {peer_pid, client_node}
  end

  defp detener_nodo_cliente(peer_pid) do
    if Process.alive?(peer_pid) do
      try do
        :peer.stop(peer_pid)
      catch
        _, _ -> :ok
      end
    end
  end

  # Inicia un proceso Trivia.Cliente dentro del nodo remoto `client_node`
  defp iniciar_cliente_remoto(client_node, srv_name, suscriptor \\ self()) do
    server_node = node()

    {:ok, cliente_pid} =
      :erpc.call(client_node, Cliente, :start, [
        [
          nodo_servidor: server_node,
          servidor: srv_name,
          suscriptor: suscriptor,
          silencioso: true
        ]
      ])

    assert node(cliente_pid) == client_node
    cliente_pid
  end

  # ── 1 y 2. Conexión desde nodo remoto y registro/autenticación ──────

  describe "1 y 2. Conexión de cliente remoto y registro/autenticación de usuario" do
    test "un cliente en otro nodo Erlang se conecta con Node.connect y registra su usuario",
         %{srv: srv, pers: pers, gj: gj} do
      {peer, client_node} = iniciar_nodo_cliente("pedro_node")

      try do
        cliente = iniciar_cliente_remoto(client_node, srv)

        # 1. Primera conexión: el usuario no existe, se registra automáticamente
        assert {:ok, {:conectado, "pedro", :registrado}} =
                 Cliente.conectar(cliente, "pedro", "secreto123")

        assert_receive {:notificacion_cliente,
                        {:conexion, {:ok, {:conectado, "pedro", :registrado}}}},
                       1000

        # Verificar que el nodo cliente quedó enlazado al nodo servidor
        assert client_node in Node.list()

        # Verificar que el usuario quedó persistido en users.json del servidor
        usuarios = Persistencia.listar_usuarios(pers)
        assert [%{"usuario" => "pedro", "clave" => "secreto123"}] = usuarios
        assert GestorJugadores.usuarios_conectados(gj) == ["pedro"]

        # 2. Desconectar y reconectar con la clave correcta -> :autenticado
        assert {:ok, :desconectado} = Cliente.desconectar(cliente)
        assert GestorJugadores.usuarios_conectados(gj) == []

        assert {:ok, {:conectado, "pedro", :autenticado}} =
                 Cliente.conectar(cliente, "pedro", "secreto123")

        # 3. Clave incorrecta es rechazada
        assert {:ok, :desconectado} = Cliente.desconectar(cliente)

        assert {:error, :clave_incorrecta} =
                 Cliente.conectar(cliente, "pedro", "clave_erronea")
      after
        detener_nodo_cliente(peer)
      end
    end

    test "rechaza usuarios con prefijo reservado bot_ y sesiones duplicadas",
         %{srv: srv} do
      {peer1, node1} = iniciar_nodo_cliente("c1")
      {peer2, node2} = iniciar_nodo_cliente("c2")

      try do
        c1 = iniciar_cliente_remoto(node1, srv)
        c2 = iniciar_cliente_remoto(node2, srv)

        # Prefijo bot_ rechazado
        assert {:error, :usuario_reservado} = Cliente.conectar(c1, "bot_1", "1234")
        assert {:error, :usuario_reservado} = Cliente.conectar(c1, "bot_pedro", "1234")

        # Usuario válido conecta en c1
        assert {:ok, {:conectado, "ana", :registrado}} = Cliente.conectar(c1, "ana", "clave")

        # Mismo usuario desde otro cliente c2 es rechazado con :sesion_activa
        assert {:error, :sesion_activa} = Cliente.conectar(c2, "ana", "clave")

        # Mismo cliente c1 intentando abrir sesión con otro usuario sin desconectar
        assert {:error, :cliente_ya_conectado} = Cliente.conectar(c1, "otra", "clave")
      after
        detener_nodo_cliente(peer1)
        detener_nodo_cliente(peer2)
      end
    end
  end

  # ── 3 y 4. Emisión de comandos válidos y rechazo de comandos inválidos ──

  describe "3 y 4. Comandos remotos válidos y validación/rechazo en el servidor" do
    test "cliente remoto ejecuta comandos válidos y el servidor rechaza comandos inválidos o no autorizados",
         %{srv: srv} do
      {peer, client_node} = iniciar_nodo_cliente("cmd_node")

      try do
        cliente = iniciar_cliente_remoto(client_node, srv)

        # Sin iniciar sesión, cualquier comando de juego es rechazado
        assert {:error, :sesion_no_iniciada} = Cliente.score(cliente)
        assert {:error, :sesion_no_iniciada} = Cliente.crear_partida(cliente, "ciencias", 5, 15)

        # Conectar mediante comando de texto CLI
        assert {:ok, {:conectado, "pedro", :registrado}} =
                 Cliente.ejecutar_comando(cliente, "connect pedro 1234")

        # Consultar score y ranking iniciales
        assert {:ok, {:score, stats}} = Cliente.ejecutar_comando(cliente, "score")
        assert stats.usuario == "pedro"
        assert stats.puntaje_total == 0
        assert stats.partidas_jugadas == 0

        assert {:ok, {:ranking, nil, []}} = Cliente.ejecutar_comando(cliente, "ranking")

        # Comandos inválidos antes de crear partida
        assert {:error, :jugador_sin_partida} = Cliente.ejecutar_comando(cliente, "add_bot facil")
        assert {:error, :jugador_sin_partida} = Cliente.ejecutar_comando(cliente, "start_game")

        # Crear partida con tema inexistente -> rechazado
        assert {:error, :tema_inexistente} =
                 Cliente.ejecutar_comando(
                   cliente,
                   "create_game tema=astrologia preguntas=5 tiempo=15"
                 )

        # Crear partida válida
        assert {:ok, {:partida_creada, id, :basico}} =
                 Cliente.ejecutar_comando(
                   cliente,
                   "create_game tema=ciencias preguntas=5 tiempo=15"
                 )

        assert String.starts_with?(id, "P-")

        # No puede iniciar con menos de 2 bots
        assert {:error, :minimo_dos_bots} = Cliente.ejecutar_comando(cliente, "start_game")

        # Dificultad inválida de bot es rechazada
        assert {:error, :dificultad_invalida} =
                 Cliente.ejecutar_comando(cliente, "add_bot imposible")

        # Intentar enviar peticiones maliciosas/arbitrarias al servidor (ej. fijar puntaje)
        assert {:error, :comando_invalido} =
                 Cliente.enviar_peticion(cliente, {:actualizar_puntaje, "pedro", 9999})

        assert {:error, :comando_invalido} =
                 Cliente.enviar_peticion(cliente, {:forzar_ganador, "pedro"})

        # Agregar dos bots válidos
        assert {:ok, {:bot_agregado, "bot_1"}} =
                 Cliente.ejecutar_comando(cliente, "add_bot facil")

        assert {:ok, {:bot_agregado, "bot_2"}} =
                 Cliente.ejecutar_comando(cliente, "add_bot dificil")

        # Iniciar partida
        assert {:ok, :partida_iniciada} = Cliente.ejecutar_comando(cliente, "start_game")

        assert_receive {:notificacion_cliente, {:nueva_pregunta, %{numero: 1}}}, 1000

        # Letra inválida rechazada sin consumir turno
        assert {:error, :respuesta_invalida} = Cliente.ejecutar_comando(cliente, "answer Z")

        # Primera respuesta válida aceptada
        assert {:ok, :respuesta_registrada} = Cliente.ejecutar_comando(cliente, "answer A")

        # Segunda respuesta en la misma ronda rechazada
        assert {:error, :ya_respondio} = Cliente.ejecutar_comando(cliente, "answer B")

        # Abandonar partida con leave_game
        assert {:ok, :partida_abandonada} = Cliente.ejecutar_comando(cliente, "leave_game")
      after
        detener_nodo_cliente(peer)
      end
    end
  end

  # ── 5 y 10. Notificaciones asíncronas y seguridad de la respuesta ───

  describe "5 y 10. Notificaciones asíncronas hacia el cliente remoto y ocultamiento de respuesta" do
    test "el cliente recibe todas las notificaciones del ciclo de vida y NUNCA recibe la respuesta correcta en las preguntas",
         %{srv: srv, gp: gp} do
      {peer, client_node} = iniciar_nodo_cliente("notif_node")

      try do
        cliente = iniciar_cliente_remoto(client_node, srv)
        {:ok, _} = Cliente.conectar(cliente, "laura", "1234")

        {:ok, {:partida_creada, id, :basico}} =
          Cliente.crear_partida(cliente, "ciencias", 1, 2)

        # Ajustar pausa corta en la partida para agilidad del test
        {:ok, pid_partida} = GestorPartidas.obtener_pid_partida(gp, id)

        :sys.replace_state(pid_partida, fn st ->
          %{st | pausa_ms: 50, bot_opts: [time_ratio: 0.0]}
        end)

        {:ok, {:bot_agregado, "bot_1"}} = Cliente.agregar_bot(cliente, "dificil")
        {:ok, {:bot_agregado, "bot_2"}} = Cliente.agregar_bot(cliente, "facil")

        {:ok, :partida_iniciada} = Cliente.iniciar_partida(cliente)

        # Notificación de inicio de partida
        assert_receive {:notificacion_cliente, {:partida_iniciada, info_inicio}}, 1000
        assert info_inicio.partida_id == id

        # Notificación de nueva pregunta
        assert_receive {:notificacion_cliente, {:nueva_pregunta, pregunta_cliente}}, 1000
        assert pregunta_cliente.numero == 1
        assert pregunta_cliente.total == 1
        assert is_binary(pregunta_cliente.enunciado)
        assert is_map(pregunta_cliente.opciones)

        # 10. SEGURIDAD: El payload recibido por el cliente humano JAMÁS incluye la respuesta correcta
        refute Map.has_key?(pregunta_cliente, :respuesta)
        refute Map.has_key?(pregunta_cliente, "respuesta")
        refute Map.has_key?(pregunta_cliente, :respuesta_correcta)
        refute Map.has_key?(pregunta_cliente, "respuesta_correcta")

        # Laura responde; los bots responden solos mediante sus procesos en el servidor
        assert {:ok, :respuesta_registrada} = Cliente.responder(cliente, "A")

        # Notificación de cierre de ronda (cuando todos respondieron)
        assert_receive {:notificacion_cliente, {:fin_ronda, resumen_ronda}}, 3000
        assert resumen_ronda.numero == 1
        assert Map.has_key?(resumen_ronda.puntos_ronda, "laura")
        assert Map.has_key?(resumen_ronda.puntos_ronda, "bot_1")
        assert Map.has_key?(resumen_ronda.puntos_ronda, "bot_2")

        # Notificación de fin de partida con ranking final
        assert_receive {:notificacion_cliente, {:fin_partida, resumen_final}}, 2000
        assert resumen_final.partida_id == id
        assert length(resumen_final.ranking) == 3

        # Verificar que score y ranking reflejan la partida terminada (y excluyen bots)
        {:ok, {:score, stats}} = Cliente.score(cliente)
        assert stats.partidas_jugadas == 1
        assert [%{tema: "ciencias"}] = stats.temas

        {:ok, {:ranking, "ciencias", ranking_hist}} = Cliente.ranking(cliente, "ciencias")
        assert [%{jugador: "laura", partidas: 1}] = ranking_hist
      after
        detener_nodo_cliente(peer)
      end
    end
  end

  # ── 6 y 7. Dos clientes simultáneos y dos partidas concurrentes ─────

  describe "6 y 7. Dos nodos clientes conectados jugando partidas independientes sin interferencia" do
    test "dos clientes en nodos distintos juegan partidas simultáneas de distintos temas sin mezclar preguntas ni puntajes",
         %{srv: srv, gp: gp} do
      {peer_pedro, node_pedro} = iniciar_nodo_cliente("pedro")
      {peer_carlos, node_carlos} = iniciar_nodo_cliente("carlos")

      try do
        test_pid = self()

        # Suscriptores diferenciados para distinguir qué llega a cada cliente
        sub_pedro =
          spawn_link(fn ->
            bucle_reenvio(test_pid, :pedro)
          end)

        sub_carlos =
          spawn_link(fn ->
            bucle_reenvio(test_pid, :carlos)
          end)

        c_pedro = iniciar_cliente_remoto(node_pedro, srv, sub_pedro)
        c_carlos = iniciar_cliente_remoto(node_carlos, srv, sub_carlos)

        # 6. Ambos clientes se conectan simultáneamente
        assert {:ok, {:conectado, "pedro", :registrado}} =
                 Cliente.conectar(c_pedro, "pedro", "1111")

        assert {:ok, {:conectado, "carlos", :registrado}} =
                 Cliente.conectar(c_carlos, "carlos", "2222")

        # Pedro crea partida de ciencias (2 preguntas, 1s por pregunta)
        assert {:ok, {:partida_creada, id_pedro, :basico}} =
                 Cliente.crear_partida(c_pedro, "ciencias", 2, 1)

        # Carlos crea partida de historia (2 preguntas, 2s por pregunta)
        assert {:ok, {:partida_creada, id_carlos, :basico}} =
                 Cliente.crear_partida(c_carlos, "historia", 2, 2)

        assert id_pedro != id_carlos

        # Configurar bots rápidos y pausa corta entre rondas en ambas partidas
        {:ok, pid_pedro} = GestorPartidas.obtener_pid_partida(gp, id_pedro)
        {:ok, pid_carlos} = GestorPartidas.obtener_pid_partida(gp, id_carlos)

        :sys.replace_state(pid_pedro, fn st ->
          %{st | bot_opts: [time_ratio: 0.0], pausa_ms: 50}
        end)

        :sys.replace_state(pid_carlos, fn st ->
          %{st | bot_opts: [time_ratio: 0.0], pausa_ms: 50}
        end)

        # Cada uno agrega sus bots e inicia su partida
        assert {:ok, {:bot_agregado, "bot_1"}} = Cliente.agregar_bot(c_pedro, "facil")
        assert {:ok, {:bot_agregado, "bot_2"}} = Cliente.agregar_bot(c_pedro, "dificil")

        assert {:ok, {:bot_agregado, "bot_1"}} = Cliente.agregar_bot(c_carlos, "dificil")
        assert {:ok, {:bot_agregado, "bot_2"}} = Cliente.agregar_bot(c_carlos, "facil")

        assert {:ok, :partida_iniciada} = Cliente.iniciar_partida(c_pedro)
        assert {:ok, :partida_iniciada} = Cliente.iniciar_partida(c_carlos)

        # Ronda 1: Pedro recibe únicamente preguntas de su partida (ciencias, 1s)
        assert_receive {:evento, :pedro, {:nueva_pregunta, %{numero: 1} = preg_pedro}}, 1000
        assert preg_pedro.partida_id == id_pedro
        assert preg_pedro.tema == "ciencias"
        assert preg_pedro.tiempo_limite == 1

        # Ronda 1: Carlos recibe únicamente preguntas de su partida (historia, 2s)
        assert_receive {:evento, :carlos, {:nueva_pregunta, %{numero: 1} = preg_carlos}}, 1000
        assert preg_carlos.partida_id == id_carlos
        assert preg_carlos.tema == "historia"
        assert preg_carlos.tiempo_limite == 2

        # En Ronda 1 ambos responden activamente
        assert {:ok, :respuesta_registrada} = Cliente.responder(c_pedro, "A")
        assert {:ok, :respuesta_registrada} = Cliente.responder(c_carlos, "B")

        assert_receive {:evento, :pedro, {:fin_ronda, %{numero: 1, partida_id: ^id_pedro}}}, 1000

        assert_receive {:evento, :carlos, {:fin_ronda, %{numero: 1, partida_id: ^id_carlos}}},
                       1000

        # Ronda 2: ambos reciben su segunda pregunta pero no responden, dejando que el
        # temporizador independiente de cada partida (1s vs 2s) cierre su propia ronda
        assert_receive {:evento, :pedro, {:nueva_pregunta, %{numero: 2, partida_id: ^id_pedro}}},
                       1000

        assert_receive {:evento, :carlos,
                        {:nueva_pregunta, %{numero: 2, partida_id: ^id_carlos}}},
                       1000

        # La ronda 2 de Pedro (1s) vence primero por temporizador
        assert_receive {:evento, :pedro,
                        {:fin_ronda, %{numero: 2, partida_id: ^id_pedro} = fin_r2_pedro}},
                       1500

        assert fin_r2_pedro.detalles_ronda["pedro"].resultado == :sin_responder

        # En ese instante, la ronda 2 de Carlos (2s) sigue abierta en el servidor
        {:ok, est_carlos} = GestorPartidas.obtener_estado_partida(gp, id_carlos)
        assert est_carlos.estado == :en_curso
        assert est_carlos.pregunta_actual == 2
        assert est_carlos.ronda_abierta == true
        refute_received {:evento, :carlos, {:fin_ronda, %{numero: 2}}}

        # Luego vence independientemente el temporizador de 2s de Carlos
        assert_receive {:evento, :carlos,
                        {:fin_ronda, %{numero: 2, partida_id: ^id_carlos} = fin_r2_carlos}},
                       1800

        assert fin_r2_carlos.detalles_ronda["carlos"].resultado == :sin_responder

        assert_receive {:evento, :pedro, {:fin_partida, fin_pedro}}, 2000
        assert fin_pedro.partida_id == id_pedro
        assert fin_pedro.tema == "ciencias"

        assert_receive {:evento, :carlos, {:fin_partida, fin_carlos}}, 2000
        assert fin_carlos.partida_id == id_carlos
        assert fin_carlos.tema == "historia"

        # Verificar que ninguna notificación de Carlos llegó a Pedro ni viceversa
        notifs_pedro = Cliente.notificaciones(c_pedro)
        notifs_carlos = Cliente.notificaciones(c_carlos)

        assert Enum.all?(notifs_pedro, fn
                 {_, %{partida_id: pid_id}} -> pid_id == id_pedro
                 _ -> true
               end)

        assert Enum.all?(notifs_carlos, fn
                 {_, %{partida_id: pid_id}} -> pid_id == id_carlos
                 _ -> true
               end)
      after
        detener_nodo_cliente(peer_pedro)
        detener_nodo_cliente(peer_carlos)
      end
    end
  end

  # ── 8 y 9. Desconexión, limpieza de sesión y tolerancia a fallas ────

  describe "8 y 9. Limpieza de sesión al desconectar y manejo de caídas de cliente/servidor/partida" do
    test "si un nodo cliente cae con partida en curso, el servidor limpia su sesión, persiste la partida (sección 6.5) y no afecta a otros clientes",
         %{srv: srv, gj: gj, pers: pers} do
      {peer1, node1} = iniciar_nodo_cliente("caida_c1")
      {peer2, node2} = iniciar_nodo_cliente("estable_c2")

      try do
        c1 = iniciar_cliente_remoto(node1, srv)
        c2 = iniciar_cliente_remoto(node2, srv)

        {:ok, _} = Cliente.conectar(c1, "pedro", "1234")
        {:ok, _} = Cliente.conectar(c2, "carlos", "1234")

        {:ok, {:partida_creada, id1, _}} = Cliente.crear_partida(c1, "ciencias", 5, 15)
        {:ok, _} = Cliente.agregar_bot(c1, "facil")
        {:ok, _} = Cliente.agregar_bot(c1, "dificil")
        {:ok, :partida_iniciada} = Cliente.iniciar_partida(c1)

        {:ok, {:partida_creada, id2, _}} = Cliente.crear_partida(c2, "historia", 5, 15)

        assert "pedro" in GestorJugadores.usuarios_conectados(gj)
        assert "carlos" in GestorJugadores.usuarios_conectados(gj)

        # Caída abrupta del nodo de Pedro
        detener_nodo_cliente(peer1)
        Process.sleep(150)

        # La sesión de Pedro fue limpiada automáticamente
        refute "pedro" in GestorJugadores.usuarios_conectados(gj)

        # La partida en curso de Pedro se cerró y persistió en results.log (sección 6.5)
        historial = Persistencia.obtener_historial(pers)
        assert Enum.any?(historial, fn registro -> registro["id"] == id1 end)

        # Carlos y el servidor siguen operando sin ninguna afectación
        assert "carlos" in GestorJugadores.usuarios_conectados(gj)
        assert {:ok, {:bot_agregado, "bot_1"}} = Cliente.agregar_bot(c2, "facil")
        assert {:ok, ^id2} = GestorPartidas.obtener_partida(srv |> obtener_gp(c2, id2), "carlos")
      after
        detener_nodo_cliente(peer1)
        detener_nodo_cliente(peer2)
      end
    end

    test "si una partida sufre una falla anormal, se reinicia y notifica al cliente remoto",
         %{srv: srv, gp: gp} do
      {peer, client_node} = iniciar_nodo_cliente("crash_partida")

      try do
        cliente = iniciar_cliente_remoto(client_node, srv)
        {:ok, _} = Cliente.conectar(cliente, "pedro", "1234")
        {:ok, {:partida_creada, id, _}} = Cliente.crear_partida(cliente, "ciencias", 5, 15)
        {:ok, _} = Cliente.agregar_bot(cliente, "facil")
        {:ok, _} = Cliente.agregar_bot(cliente, "dificil")
        {:ok, :partida_iniciada} = Cliente.iniciar_partida(cliente)

        {:ok, pid_original} = GestorPartidas.obtener_pid_partida(gp, id)

        # Inducir falla anormal en el proceso de la partida
        Process.exit(pid_original, :kill)

        # El cliente remoto recibe la notificación de reinicio (sección 8.5)
        assert_receive {:notificacion_cliente, {:partida_reiniciada, ^id, mensaje}}, 1500
        assert mensaje =~ "se reinició sin su progreso"

        # El cliente puede volver a agregar bots e iniciar la partida reiniciada
        assert {:ok, {:bot_agregado, "bot_1"}} = Cliente.agregar_bot(cliente, "facil")
        assert {:ok, {:bot_agregado, "bot_2"}} = Cliente.agregar_bot(cliente, "dificil")
        assert {:ok, :partida_iniciada} = Cliente.iniciar_partida(cliente)
      after
        detener_nodo_cliente(peer)
      end
    end

    test "el cliente maneja servidor no disponible y caída del servidor sin estrellarse",
         %{srv: srv, srv_pid: srv_pid} do
      {peer, client_node} = iniciar_nodo_cliente("resiliente")

      try do
        # 1. Intentar conectar a un nodo servidor inexistente
        cliente_invalido =
          iniciar_cliente_remoto_a_nodo(
            client_node,
            :"nodo_inexistente_99999@127.0.0.1",
            :servidor_inexistente
          )

        assert {:error, :servidor_no_disponible} =
                 Cliente.conectar(cliente_invalido, "pedro", "1234")

        assert :erpc.call(client_node, Process, :alive?, [cliente_invalido])

        # 2. Conectar a un servidor real y luego detener el proceso del servidor
        cliente = iniciar_cliente_remoto(client_node, srv)

        assert {:ok, {:conectado, "pedro", :registrado}} =
                 Cliente.conectar(cliente, "pedro", "1234")

        GenServer.stop(srv_pid, :normal)

        assert_receive {:notificacion_cliente, {:servidor_desconectado, _nodo}}, 1000

        estado_cliente = Cliente.estado(cliente)
        assert estado_cliente.conectado == false
        assert estado_cliente.usuario == nil

        # Peticiones posteriores informan :servidor_no_disponible sin tumbar el cliente
        assert {:error, :servidor_no_disponible} = Cliente.score(cliente)
      after
        detener_nodo_cliente(peer)
      end
    end

    test "disconnect voluntario durante una partida en curso cierra la sesión y persiste el resultado (sección 6.5)",
         %{srv: srv, gj: gj, pers: pers} do
      {peer, client_node} = iniciar_nodo_cliente("disc_voluntario")

      try do
        cliente = iniciar_cliente_remoto(client_node, srv)
        {:ok, _} = Cliente.conectar(cliente, "marta", "1234")
        {:ok, {:partida_creada, id, _}} = Cliente.crear_partida(cliente, "ciencias", 5, 15)
        {:ok, _} = Cliente.agregar_bot(cliente, "facil")
        {:ok, _} = Cliente.agregar_bot(cliente, "dificil")
        {:ok, :partida_iniciada} = Cliente.iniciar_partida(cliente)

        assert_receive {:notificacion_cliente, {:nueva_pregunta, %{numero: 1}}}, 1000

        # Ejecutar disconnect con la partida en curso
        assert {:ok, :desconectado} = Cliente.desconectar(cliente)

        refute "marta" in GestorJugadores.usuarios_conectados(gj)

        historial = Persistencia.obtener_historial(pers)

        assert Enum.any?(historial, fn registro ->
                 registro["id"] == id and Map.has_key?(registro["puntajes"], "marta")
               end)
      after
        detener_nodo_cliente(peer)
      end
    end

    test "un cliente no puede registrar un receptor de otro nodo ni modificar la sesión de otro jugador",
         %{srv: srv} do
      {peer1, node1} = iniciar_nodo_cliente("seg_c1")
      {peer2, node2} = iniciar_nodo_cliente("seg_c2")

      try do
        c1 = iniciar_cliente_remoto(node1, srv)
        c2 = iniciar_cliente_remoto(node2, srv)

        {:ok, _} = Cliente.conectar(c1, "pedro", "1234")
        {:ok, {:partida_creada, id_pedro, _}} = Cliente.crear_partida(c1, "ciencias", 5, 15)

        # c2 intenta registrar como receptor un PID que vive en node1 (o en el servidor)
        res_suplantar =
          :erpc.call(node2, GenServer, :call, [
            {srv, node()},
            {:peticion, {:connect, "intruso", "1234", self()}}
          ])

        assert {:error, :receptor_invalido} = res_suplantar

        # c2 conecta como carlos; sus comandos solo afectan a carlos, nunca a la partida de pedro
        {:ok, _} = Cliente.conectar(c2, "carlos", "1234")
        assert {:error, :jugador_sin_partida} = Cliente.abandonar_partida(c2)

        # La partida de pedro sigue intacta
        assert {:ok, {:bot_agregado, "bot_1"}} = Cliente.agregar_bot(c1, "facil")
        assert is_binary(id_pedro)
      after
        detener_nodo_cliente(peer1)
        detener_nodo_cliente(peer2)
      end
    end

    test "al caer Trivia.Servidor mientras GestorJugadores sigue vivo, se limpia la sesión obsoleta y el cliente puede reconectar con el mismo usuario",
         %{srv: srv, srv_pid: srv_pid, gj: gj, gp: gp} do
      {peer, client_node} = iniciar_nodo_cliente("recon_mismo")

      try do
        cliente = iniciar_cliente_remoto(client_node, srv)

        assert {:ok, {:conectado, "pedro", :registrado}} =
                 Cliente.conectar(cliente, "pedro", "1234")

        assert GestorJugadores.usuarios_conectados(gj) == ["pedro"]

        # Terminar únicamente el proceso Trivia.Servidor mientras GestorJugadores sigue vivo
        GenServer.stop(srv_pid, :normal)

        assert_receive {:notificacion_cliente, {:servidor_desconectado, _nodo}}, 1000
        assert Cliente.estado(cliente).conectado == false

        # No debe quedar una sesión activa obsoleta en GestorJugadores
        assert GestorJugadores.usuarios_conectados(gj) == []
        assert {:error, :sesion_no_iniciada} = GestorJugadores.sesion(gj, cliente)

        # Levantar de nuevo el proceso Trivia.Servidor y reconectar con el mismo usuario
        {:ok, nuevo_srv_pid} =
          Servidor.start_link(
            name: srv,
            gestor_jugadores: gj,
            gestor_partidas: gp
          )

        Process.unlink(nuevo_srv_pid)

        try do
          assert {:ok, {:conectado, "pedro", :autenticado}} =
                   Cliente.conectar(cliente, "pedro", "1234")

          assert Cliente.estado(cliente).conectado == true
          assert Cliente.estado(cliente).usuario == "pedro"
          assert GestorJugadores.usuarios_conectados(gj) == ["pedro"]
        after
          if Process.alive?(nuevo_srv_pid), do: GenServer.stop(nuevo_srv_pid, :normal, 1000)
        end
      after
        detener_nodo_cliente(peer)
      end
    end

    test "una partida activa sobrevive a la caída y reinicio de Trivia.Servidor y el cliente reconectado continúa jugando en ella",
         %{srv: srv, srv_pid: srv_pid, gj: gj, gp: gp, pers: pers} do
      {peer, client_node} = iniciar_nodo_cliente("partida_sobrevive_srv")

      try do
        cliente = iniciar_cliente_remoto(client_node, srv)

        # 3. Conectar cliente remoto como "pedro"
        assert {:ok, {:conectado, "pedro", :registrado}} =
                 Cliente.conectar(cliente, "pedro", "1234")

        # 4. Crear partida para "pedro" (ventana determinista de 15s por pregunta)
        assert {:ok, {:partida_creada, partida_id, :basico}} =
                 Cliente.crear_partida(cliente, "ciencias", 3, 15)

        # 5. Agregar dos bots con dificultades válidas
        assert {:ok, {:bot_agregado, "bot_1"}} = Cliente.agregar_bot(cliente, "facil")
        assert {:ok, {:bot_agregado, "bot_2"}} = Cliente.agregar_bot(cliente, "dificil")

        # 6. Iniciar la partida
        assert {:ok, :partida_iniciada} = Cliente.iniciar_partida(cliente)

        assert_receive {:notificacion_cliente, {:nueva_pregunta, %{partida_id: ^partida_id}}},
                       1000

        # 7. Capturar el ID y PID de la partida y verificar que está activa (:en_curso)
        assert {:ok, ^partida_id} = GestorPartidas.obtener_partida(gp, "pedro")
        assert {:ok, pid_partida} = GestorPartidas.obtener_pid_partida(gp, partida_id)
        assert Process.alive?(pid_partida)
        assert {:ok, estado_inicial} = GestorPartidas.obtener_estado_partida(gp, partida_id)
        assert estado_inicial.estado == :en_curso
        assert estado_inicial.ronda_abierta == true

        # 8. Terminar únicamente el proceso Trivia.Servidor
        GenServer.stop(srv_pid, :normal)

        assert_receive {:notificacion_cliente, {:servidor_desconectado, _nodo}}, 1000
        assert Cliente.estado(cliente).conectado == false

        # 9. Verificar que GestorJugadores, GestorPartidas y la partida siguen vivos
        #    y que la partida NO fue abandonada ni persistida por la caída de Trivia.Servidor
        assert Process.alive?(Process.whereis(gj))
        assert Process.alive?(Process.whereis(gp))
        assert Process.alive?(pid_partida)
        assert {:ok, ^partida_id} = GestorPartidas.obtener_partida(gp, "pedro")
        assert {:ok, ^pid_partida} = GestorPartidas.obtener_pid_partida(gp, partida_id)

        assert {:ok, estado_tras_caida_srv} =
                 GestorPartidas.obtener_estado_partida(gp, partida_id)

        assert estado_tras_caida_srv.estado == :en_curso
        assert estado_tras_caida_srv.ronda_abierta == true
        assert Persistencia.obtener_historial(pers) == []

        # 10. Reiniciar Trivia.Servidor con las mismas convenciones de supervisión
        {:ok, nuevo_srv_pid} =
          Servidor.start_link(
            name: srv,
            gestor_jugadores: gj,
            gestor_partidas: gp
          )

        Process.unlink(nuevo_srv_pid)

        try do
          # 11. Reconectar el mismo cliente remoto usando el usuario original "pedro"
          assert {:ok, {:conectado, "pedro", :autenticado}} =
                   Cliente.conectar(cliente, "pedro", "1234")

          # 12. Verificar que la reconexión tuvo éxito, el ID de la partida no cambió,
          #     la partida sigue activa y acepta respuestas por la ruta normal cliente-servidor
          assert Cliente.estado(cliente).conectado == true
          assert Cliente.estado(cliente).usuario == "pedro"
          assert {:ok, ^partida_id} = GestorPartidas.obtener_partida(gp, "pedro")

          assert {:ok, estado_reconectado} =
                   GestorPartidas.obtener_estado_partida(gp, partida_id)

          assert estado_reconectado.id == partida_id
          assert estado_reconectado.estado == :en_curso
          assert estado_reconectado.ronda_abierta == true

          # Enviar una respuesta válida a través del flujo normal Cliente -> Servidor -> GestorPartidas -> Partida
          assert {:ok, :respuesta_registrada} = Cliente.responder(cliente, "A")

          assert {:ok, estado_tras_respuesta} =
                   GestorPartidas.obtener_estado_partida(gp, partida_id)

          assert estado_tras_respuesta.respuestas_ronda["pedro"].respuesta == "A"
          assert {:error, :ya_respondio} = Cliente.responder(cliente, "B")

          # Limpiar la partida activa al finalizar la prueba
          assert {:ok, :partida_abandonada} = Cliente.abandonar_partida(cliente)
        after
          if Process.alive?(nuevo_srv_pid), do: GenServer.stop(nuevo_srv_pid, :normal, 1000)
        end
      after
        detener_nodo_cliente(peer)
      end
    end

    test "tras reiniciarse Trivia.Servidor, el mismo cliente puede reconectarse con un nombre de usuario diferente y el usuario anterior queda libre",
         %{srv: srv, srv_pid: srv_pid, gj: gj, gp: gp, pers: pers} do
      {peer1, node1} = iniciar_nodo_cliente("recon_otro_1")
      {peer2, node2} = iniciar_nodo_cliente("recon_otro_2")

      try do
        c1 = iniciar_cliente_remoto(node1, srv)
        c2 = iniciar_cliente_remoto(node2, srv)

        assert {:ok, {:conectado, "pedro", :registrado}} =
                 Cliente.conectar(c1, "pedro", "1234")

        {:ok, {:partida_creada, id_previa, :basico}} =
          Cliente.crear_partida(c1, "ciencias", 5, 15)

        {:ok, _} = Cliente.agregar_bot(c1, "facil")
        {:ok, _} = Cliente.agregar_bot(c1, "dificil")
        {:ok, :partida_iniciada} = Cliente.iniciar_partida(c1)

        # Falla anormal del proceso Trivia.Servidor mientras GestorJugadores sigue vivo
        Process.exit(srv_pid, :kill)

        assert_receive {:notificacion_cliente, {:servidor_desconectado, _nodo}}, 1000
        assert GestorJugadores.usuarios_conectados(gj) == []

        # Reiniciar Trivia.Servidor bajo el mismo nombre registrado
        {:ok, nuevo_srv_pid} =
          Servidor.start_link(
            name: srv,
            gestor_jugadores: gj,
            gestor_partidas: gp
          )

        Process.unlink(nuevo_srv_pid)

        try do
          # El mismo cliente c1 reconecta ahora con un usuario distinto ("carlos")
          assert {:ok, {:conectado, "carlos", :registrado}} =
                   Cliente.conectar(c1, "carlos", "5678")

          assert Cliente.estado(c1).usuario == "carlos"
          assert GestorJugadores.usuarios_conectados(gj) == ["carlos"]

          # La partida previa de "pedro" fue cerrada y persistida según sección 6.5
          historial = Persistencia.obtener_historial(pers)
          assert Enum.any?(historial, fn registro -> registro["id"] == id_previa end)

          # Otro cliente c2 puede conectarse con el usuario original "pedro" y crear partida
          assert {:ok, {:conectado, "pedro", :autenticado}} =
                   Cliente.conectar(c2, "pedro", "1234")

          assert {:ok, {:partida_creada, _nuevo_id, :basico}} =
                   Cliente.crear_partida(c2, "historia", 5, 15)
        after
          if Process.alive?(nuevo_srv_pid), do: GenServer.stop(nuevo_srv_pid, :normal, 1000)
        end
      after
        detener_nodo_cliente(peer1)
        detener_nodo_cliente(peer2)
      end
    end

    test "aislamiento de clientes conectados, partidas no relacionadas e idempotencia en la limpieza de sesiones",
         %{srv: srv, srv_pid: srv_pid, gj: gj, gp: gp} do
      {peer1, node1} = iniciar_nodo_cliente("iso_c1")
      {peer2, node2} = iniciar_nodo_cliente("iso_c2")

      srv2_name = :"srv_aislado_#{System.unique_integer([:positive])}"

      {:ok, srv2_pid} =
        Servidor.start_link(
          name: srv2_name,
          gestor_jugadores: gj,
          gestor_partidas: gp
        )

      Process.unlink(srv2_pid)

      try do
        c1 = iniciar_cliente_remoto(node1, srv)
        c2 = iniciar_cliente_remoto(node2, srv2_name)

        assert {:ok, {:conectado, "pedro", :registrado}} =
                 Cliente.conectar(c1, "pedro", "1111")

        assert {:ok, {:conectado, "carlos", :registrado}} =
                 Cliente.conectar(c2, "carlos", "2222")

        {:ok, {:partida_creada, id_carlos, :basico}} =
          Cliente.crear_partida(c2, "historia", 5, 15)

        {:ok, _} = Cliente.agregar_bot(c2, "facil")
        {:ok, _} = Cliente.agregar_bot(c2, "dificil")
        {:ok, :partida_iniciada} = Cliente.iniciar_partida(c2)

        assert_receive {:notificacion_cliente, {:nueva_pregunta, %{partida_id: ^id_carlos}}},
                       1000

        # Terminar srv_pid (donde estaba c1): solo se libera la sesión de "pedro";
        # "carlos" y su partida en curso permanecen intactos.
        GenServer.stop(srv_pid, :normal)
        Process.sleep(50)

        assert GestorJugadores.usuarios_conectados(gj) == ["carlos"]
        assert {:ok, ^id_carlos} = GestorPartidas.obtener_partida(gp, "carlos")
        assert {:ok, :respuesta_registrada} = Cliente.responder(c2, "A")

        # Limpieza idempotente: desconectar un cliente sin sesión activa no libera a "carlos"
        assert {:error, :sesion_no_iniciada} = GestorJugadores.desconectar(gj, c1)
        assert GestorJugadores.usuarios_conectados(gj) == ["carlos"]

        # Un intento fallido de conexión hacia "carlos" desde otro cliente no tumba el servidor
        # ni libera la sesión activa de "carlos"
        c1_en_srv2 = iniciar_cliente_remoto(node1, srv2_name)
        assert {:error, :sesion_activa} = Cliente.conectar(c1_en_srv2, "carlos", "2222")
        assert {:error, :clave_incorrecta} = Cliente.conectar(c1_en_srv2, "pedro", "mala")
        assert GestorJugadores.usuarios_conectados(gj) == ["carlos"]
        assert {:ok, ^id_carlos} = GestorPartidas.obtener_partida(gp, "carlos")
      after
        if Process.alive?(srv2_pid), do: GenServer.stop(srv2_pid, :normal, 1000)
        detener_nodo_cliente(peer1)
        detener_nodo_cliente(peer2)
      end
    end
  end

  # ── Historial acotado de notificaciones en Trivia.Receptor ──────────

  describe "historial acotado de notificaciones en Trivia.Receptor" do
    test "almacena las notificaciones normalmente antes de alcanzar el límite de 100" do
      {:ok, receptor} = Receptor.start_link(suscriptor: self(), silencioso: true)

      for i <- 1..50 do
        send(receptor, {:notificacion, "msg_#{i}"})
      end

      assert_receive {:notificacion_cliente, {:notificacion, "msg_50"}}, 1000

      notificaciones = Receptor.obtener_notificaciones(receptor)
      assert length(notificaciones) == 50
      assert List.first(notificaciones) == {:notificacion, "msg_1"}
      assert List.last(notificaciones) == {:notificacion, "msg_50"}

      GenServer.stop(receptor)
    end

    test "retiene exactamente las 100 notificaciones más recientes, descarta las más antiguas y mantiene la entrega en vivo" do
      {:ok, receptor} = Receptor.start_link(suscriptor: self(), silencioso: true)

      for i <- 1..125 do
        send(receptor, {:notificacion, "msg_#{i}"})
      end

      assert_receive {:notificacion_cliente, {:notificacion, "msg_125"}}, 1000

      notificaciones = Receptor.obtener_notificaciones(receptor)
      assert length(notificaciones) == 100

      # Las 25 más antiguas (1..25) fueron descartadas; la más antigua retenida es la 26
      refute {:notificacion, "msg_1"} in notificaciones
      refute {:notificacion, "msg_25"} in notificaciones
      assert List.first(notificaciones) == {:notificacion, "msg_26"}

      # La más reciente (125) se conserva al final de la lista cronológica
      assert List.last(notificaciones) == {:notificacion, "msg_125"}

      # La entrega en vivo continúa funcionando normalmente después de alcanzar el límite
      send(receptor, {:notificacion, "msg_126"})
      assert_receive {:notificacion_cliente, {:notificacion, "msg_126"}}, 1000

      notificaciones_post = Receptor.obtener_notificaciones(receptor)
      assert length(notificaciones_post) == 100
      assert List.first(notificaciones_post) == {:notificacion, "msg_27"}
      assert List.last(notificaciones_post) == {:notificacion, "msg_126"}

      GenServer.stop(receptor)
    end
  end

  # ── Pruebas unitarias de rol de nodo, parser y formateo ─────────────

  describe "rol de nodo, intérprete de comandos y formateo de mensajes" do
    test "Cliente.parsear_comando reconoce todos los comandos de la especificación y rechaza entradas malformadas" do
      assert {:ok, {:connect, "pedro", "1234"}} = Cliente.parsear_comando("connect pedro 1234")
      assert {:ok, :disconnect} = Cliente.parsear_comando("disconnect")
      assert {:ok, :score} = Cliente.parsear_comando("score")
      assert {:ok, {:ranking, nil}} = Cliente.parsear_comando("ranking")
      assert {:ok, {:ranking, "ciencia"}} = Cliente.parsear_comando("ranking ciencia")

      assert {:ok, {:create_game, "ciencia", 5, 15}} =
               Cliente.parsear_comando("create_game tema=ciencia preguntas=5 tiempo=15")

      assert {:ok, {:add_bot, "facil"}} = Cliente.parsear_comando("add_bot facil")
      assert {:ok, {:add_bot, "dificil"}} = Cliente.parsear_comando("add_bot dificil")
      assert {:ok, :start_game} = Cliente.parsear_comando("start_game")
      assert {:ok, :leave_game} = Cliente.parsear_comando("leave_game")
      assert {:ok, {:answer, "B"}} = Cliente.parsear_comando("answer B")
      assert {:error, :parametros_invalidos} = Cliente.parsear_comando("create_game tema=ciencia")
      assert {:error, :comando_invalido} = Cliente.parsear_comando("comando_inexistente 1 2 3")
    end

    test "Trivia.Application.resolver_rol distingue nodos servidor y nodos cliente" do
      # El nombre del nodo solo decide cuando hay un rol configurado (en pruebas es :none)
      rol_previo = Application.fetch_env!(:trivia, :role)
      Application.put_env(:trivia, :role, :server)
      on_exit(fn -> Application.put_env(:trivia, :role, rol_previo) end)

      assert TriviaApp.resolver_rol(:servidor@host, nil) == :server
      assert TriviaApp.resolver_rol(:pedro@host, nil) == :client
      assert TriviaApp.resolver_rol(:carlos@host, nil) == :client
      assert TriviaApp.resolver_rol(:cualquier@host, "server") == :server
      assert TriviaApp.resolver_rol(:servidor@host, "client") == :client
    end

    test "Receptor formatea preguntas, rondas, fin de partida, score y ranking correctamente" do
      texto_preg =
        Receptor.formatear_notificacion(
          {:nueva_pregunta,
           %{
             numero: 1,
             total: 5,
             tema: "ciencias",
             nivel: "basico",
             enunciado: "¿Planeta más grande?",
             opciones: %{"A" => "Marte", "B" => "Júpiter", "C" => "Saturno", "D" => "Neptuno"},
             tiempo_limite: 15
           }}
        )

      assert texto_preg =~ "Pregunta 1 de 5"
      assert texto_preg =~ "¿Planeta más grande?"
      assert texto_preg =~ "B) Júpiter"

      texto_score =
        Receptor.formatear_score(%{
          usuario: "Pedro",
          puntaje_total: 85,
          partidas_jugadas: 6,
          temas: [%{tema: "ciencia", puntaje: 72, nivel: :intermedio}]
        })

      assert texto_score =~ "=== Pedro ==="
      assert texto_score =~ "Puntaje acumulado: 85"
      assert texto_score =~ "ciencia"
      assert texto_score =~ "intermedio"

      texto_ranking =
        Receptor.formatear_ranking(nil, [
          %{puesto: 1, jugador: "Ana", puntaje: 120, partidas: 8}
        ])

      assert texto_ranking =~ "=== Ranking global ==="
      assert texto_ranking =~ "Ana"
    end
  end

  # Helpers auxiliares de test

  defp bucle_reenvio(destino, etiqueta) do
    receive do
      {:notificacion_cliente, msg} ->
        send(destino, {:evento, etiqueta, msg})
        bucle_reenvio(destino, etiqueta)
    end
  end

  defp obtener_gp(srv, _cliente, _id) do
    :sys.get_state(srv).gestor_partidas
  end

  defp iniciar_cliente_remoto_a_nodo(client_node, target_node, srv_name) do
    {:ok, pid} =
      :erpc.call(client_node, Cliente, :start, [
        [
          nodo_servidor: target_node,
          servidor: srv_name,
          suscriptor: self(),
          silencioso: true
        ]
      ])

    pid
  end
end
