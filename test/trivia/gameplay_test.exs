defmodule Trivia.GameplayTest do
  use ExUnit.Case, async: true

  alias Trivia.GestorPartidas
  alias Trivia.Partida
  alias Trivia.Persistencia
  alias Trivia.SupervisorPartidas

  @moduletag :gameplay

  setup do
    unique_id = :erlang.unique_integer([:positive])
    sup_name = :"supervisor_gp_#{unique_id}"
    gestor_name = :"gestor_gp_#{unique_id}"
    pers_name = :"persistencia_gp_#{unique_id}"

    tmp_dir = Path.join(System.tmp_dir!(), "trivia_gp_test_#{unique_id}")
    File.mkdir_p!(tmp_dir)

    # Copiar preguntas semilla
    seed_path = Path.expand("data/questions.json")
    File.cp!(seed_path, Path.join(tmp_dir, "questions.json"))

    {:ok, pers_pid} = Trivia.Persistencia.iniciar_link(data_dir: tmp_dir, name: pers_name)
    {:ok, sup_pid} = SupervisorPartidas.start_link(name: sup_name)

    {:ok, gestor_pid} =
      GestorPartidas.start_link(
        name: gestor_name,
        supervisor: sup_name,
        persistencia: pers_name
      )

    Process.unlink(sup_pid)
    Process.unlink(gestor_pid)
    Process.unlink(pers_pid)

    on_exit(fn ->
      if Process.alive?(gestor_pid) do
        try do
          GenServer.stop(gestor_pid, :normal, 1000)
        catch
          :exit, _ -> :ok
        end
      end

      if Process.alive?(sup_pid) do
        try do
          Supervisor.stop(sup_pid, :normal, 1000)
        catch
          :exit, _ -> :ok
        end
      end

      if Process.alive?(pers_pid) do
        try do
          GenServer.stop(pers_pid, :normal, 1000)
        catch
          :exit, _ -> :ok
        end
      end

      File.rm_rf!(tmp_dir)
    end)

    %{
      gestor: gestor_name,
      supervisor: sup_name,
      persistencia: pers_name,
      sup_pid: sup_pid,
      gestor_pid: gestor_pid,
      pers_pid: pers_pid,
      tmp_dir: tmp_dir
    }
  end

  # ── 1. Sorteo y ordenamiento de preguntas ───────────────────────────

  describe "sorteo y selección de preguntas al iniciar partida" do
    test "selecciona total_preguntas, del tema pedido, sin duplicados y ordenadas por nivel", %{
      gestor: g
    } do
      {:ok, _id, _} = GestorPartidas.crear_partida(g, "pedro", "ciencias", 5, 15)
      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)
      {:ok, pid} = GestorPartidas.obtener_pid_partida(g, "pedro")

      assert :ok = Partida.iniciar_partida(pid)

      estado = Partida.obtener_estado(pid)
      assert length(estado.preguntas) == 5

      # Todos los temas corresponden a ciencias
      assert Enum.all?(estado.preguntas, fn pregunta ->
               pregunta["tema"] in ["ciencias", "ciencia"]
             end)

      # Sin preguntas duplicadas
      enunciados = Enum.map(estado.preguntas, fn pregunta -> pregunta["enunciado"] end)
      assert length(Enum.uniq(enunciados)) == 5

      # Orden de menor a mayor dificultad (4 básicas y 1 intermedia para basico con 5)
      niveles = Enum.map(estado.preguntas, fn pregunta -> pregunta["nivel"] end)
      assert niveles == ["basico", "basico", "basico", "basico", "intermedio"]
    end
  end

  # ── 2. Inicialización de ronda y seguridad de respuesta ─────────────

  describe "inicialización de ronda y notificaciones seguras" do
    test "la pregunta enviada al cliente oculta la clave de respuesta correcta", %{gestor: g} do
      {:ok, _id, _} =
        GestorPartidas.crear_partida(g, "pedro", "ciencias", 5, 15, cliente_pid: self())

      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)
      {:ok, pid} = GestorPartidas.obtener_pid_partida(g, "pedro")

      :ok = Partida.iniciar_partida(pid)

      assert_receive {:nueva_pregunta, info}, 1000
      assert info.numero == 1
      assert info.total == 5
      assert is_binary(info.enunciado)
      assert is_map(info.opciones)
      assert info.tiempo_limite == 15

      # Seguridad: La respuesta correcta NUNCA debe estar en el payload para el cliente
      refute Map.has_key?(info, :respuesta)
      refute Map.has_key?(info, "respuesta")
    end
  end

  # ── 3. Reglas de respuesta ──────────────────────────────────────────

  describe "reglas de envío de respuestas" do
    test "primera respuesta válida se acepta; la segunda se rechaza con :ya_respondio", %{
      gestor: g
    } do
      {:ok, _id, _} = GestorPartidas.crear_partida(g, "pedro", "ciencias", 5, 15)
      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)
      {:ok, pid} = GestorPartidas.obtener_pid_partida(g, "pedro")
      :ok = Partida.iniciar_partida(pid)

      # Primera respuesta válida
      assert :ok = Partida.responder(pid, "pedro", "A")

      # Segunda respuesta en la misma ronda es rechazada
      assert {:error, :ya_respondio} = Partida.responder(pid, "pedro", "B")
    end

    test "respuesta inválida no consume la oportunidad del jugador", %{gestor: g} do
      {:ok, _id, _} = GestorPartidas.crear_partida(g, "pedro", "ciencias", 5, 15)
      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)
      {:ok, pid} = GestorPartidas.obtener_pid_partida(g, "pedro")
      :ok = Partida.iniciar_partida(pid)

      # Letra inválida 'X' rechazada
      assert {:error, :respuesta_invalida} = Partida.responder(pid, "pedro", "X")

      # El jugador aún puede responder con una letra válida
      assert :ok = Partida.responder(pid, "pedro", "a")
    end

    test "rechaza respuestas enviadas antes de iniciar la partida", %{gestor: g} do
      {:ok, _id, _} = GestorPartidas.crear_partida(g, "pedro", "ciencias", 5, 15)
      {:ok, pid} = GestorPartidas.obtener_pid_partida(g, "pedro")

      assert {:error, :partida_no_iniciada} = Partida.responder(pid, "pedro", "A")
    end

    test "rechaza respuestas de jugadores desconocidos", %{gestor: g} do
      {:ok, _id, _} = GestorPartidas.crear_partida(g, "pedro", "ciencias", 5, 15)
      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)
      {:ok, pid} = GestorPartidas.obtener_pid_partida(g, "pedro")
      :ok = Partida.iniciar_partida(pid)

      assert {:error, :jugador_no_registrado} = Partida.responder(pid, "intruso", "A")
    end
  end

  # ── 4. Carrera entre respuestas y temporizadores ────────────────────

  describe "carrera entre respuestas y temporizadores (cierre estricto en el servidor)" do
    test "rechaza respuestas cuando el plazo del servidor ya expiró aunque el temporizador esté pendiente",
         %{gestor: g} do
      # Usar reloj inyectable para controlar el tiempo con precisión
      tiempo_ref = :atomics.new(1, [])
      :atomics.put(tiempo_ref, 1, 10_000)
      reloj = fn -> :atomics.get(tiempo_ref, 1) end

      {:ok, _id, _} =
        GestorPartidas.crear_partida(g, "pedro", "ciencias", 3, 10,
          cliente_pid: self(),
          reloj_fun: reloj
        )

      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)
      {:ok, pid} = GestorPartidas.obtener_pid_partida(g, "pedro")
      :ok = Partida.iniciar_partida(pid)

      assert_receive {:nueva_pregunta, %{numero: 1}}, 1000

      # Avanzar el reloj del servidor más allá del límite de 10s (10_000 ms)
      # Sin que el mensaje {:timer_ronda, ...} haya llegado todavía
      :atomics.put(tiempo_ref, 1, 20_001)

      # Pedro intenta responder tras vencer el plazo
      assert {:error, :tiempo_agotado} = Partida.responder(pid, "pedro", "A")

      # La ronda debe cerrarse de inmediato exactamente una vez
      assert_receive {:fin_ronda, resumen}, 500
      assert resumen.numero == 1
      assert resumen.detalles_ronda["pedro"].resultado == :sin_responder

      # Respuestas posteriores en la pausa son rechazadas con :ronda_no_abierta
      assert {:error, :ronda_no_abierta} = Partida.responder(pid, "bot_1", "B")
    end

    test "respuesta justo antes del límite es aceptada", %{gestor: g} do
      tiempo_ref = :atomics.new(1, [])
      :atomics.put(tiempo_ref, 1, 10_000)
      reloj = fn -> :atomics.get(tiempo_ref, 1) end

      {:ok, _id, _} =
        GestorPartidas.crear_partida(g, "pedro", "ciencias", 3, 10,
          cliente_pid: self(),
          reloj_fun: reloj
        )

      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)
      {:ok, pid} = GestorPartidas.obtener_pid_partida(g, "pedro")
      :ok = Partida.iniciar_partida(pid)

      assert_receive {:nueva_pregunta, %{numero: 1}}, 1000

      # Avanzar el reloj a 9.99 segundos (dentro del límite de 10s)
      :atomics.put(tiempo_ref, 1, 19_990)

      assert :ok = Partida.responder(pid, "pedro", "A")
    end

    test "garantiza que la ronda nunca se cierra ni puntúa dos veces", %{gestor: g} do
      {:ok, _id, _} =
        GestorPartidas.crear_partida(g, "pedro", "ciencias", 2, 10,
          cliente_pid: self(),
          pausa_ms: 50
        )

      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)
      {:ok, pid} = GestorPartidas.obtener_pid_partida(g, "pedro")
      :ok = Partida.iniciar_partida(pid)

      assert_receive {:nueva_pregunta, %{numero: 1}}, 1000

      # Los tres responden para cerrar la ronda 1 anticipadamente
      :ok = Partida.responder(pid, "pedro", "A")
      :ok = Partida.responder(pid, "bot_1", "A")
      :ok = Partida.responder(pid, "bot_2", "A")

      assert_receive {:fin_ronda, %{numero: 1}}, 500

      # Enviar mensaje falso de temporizador de la ronda 1
      send(pid, {:timer_ronda, 1, make_ref()})

      # No debe haber una segunda notificación de fin de ronda para la ronda 1
      refute_receive {:fin_ronda, %{numero: 1}}, 200
    end
  end

  # ── 5. Protección de bonificación contra manipulación ────────────────

  describe "protección de la bonificación por rapidez" do
    test "la bonificación se calcula estrictamente por el reloj del servidor e ignora valores externos",
         %{gestor: g} do
      tiempo_ref = :atomics.new(1, [])
      :atomics.put(tiempo_ref, 1, 10_000)
      reloj = fn -> :atomics.get(tiempo_ref, 1) end

      {:ok, _id, _} =
        GestorPartidas.crear_partida(g, "pedro", "ciencias", 1, 15,
          cliente_pid: self(),
          reloj_fun: reloj
        )

      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)
      {:ok, pid} = GestorPartidas.obtener_pid_partida(g, "pedro")
      :ok = Partida.iniciar_partida(pid)

      assert_receive {:nueva_pregunta, %{numero: 1}}, 1000

      estado = Partida.obtener_estado(pid)
      correcta = estado.pregunta_actual_data["respuesta"]

      # Simular que transcurrieron 9 segundos reales (tiempo_actual = 19_000, inicio = 10_000)
      # Quedan 6 segundos reales -> bonificación calculada = trunc(5 * 6 / 15) = 2
      :atomics.put(tiempo_ref, 1, 19_000)

      # El jugador intenta inyectar segundos_restantes = 14 a través de la llamada GenServer
      # para intentar obtener 4 puntos de bonificación en lugar de 2
      GenServer.call(pid, {:responder, "pedro", correcta, [segundos_restantes: 14]})
      :ok = Partida.responder(pid, "bot_1", "A")
      :ok = Partida.responder(pid, "bot_2", "A")

      assert_receive {:fin_ronda, resumen}, 500

      # La bonificación debe ser exactamente 2 (calculada por el servidor), NO 4
      assert resumen.detalles_ronda["pedro"].bonificacion == 2
      # Base 10 + bonificación 2 = 12 puntos
      assert resumen.detalles_ronda["pedro"].puntos == 12
    end
  end

  # ── 6. Cierre anticipado y cierre por temporizador ──────────────────

  describe "cierre de ronda anticipado" do
    test "la ronda se cierra de inmediato cuando todos los jugadores han respondido", %{
      gestor: g
    } do
      {:ok, _id, _} =
        GestorPartidas.crear_partida(g, "pedro", "ciencias", 5, 15, cliente_pid: self())

      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)
      {:ok, pid} = GestorPartidas.obtener_pid_partida(g, "pedro")
      :ok = Partida.iniciar_partida(pid)

      assert_receive {:nueva_pregunta, _}, 1000

      # Responden los tres jugadores
      assert :ok = Partida.responder(pid, "pedro", "A")
      assert :ok = Partida.responder(pid, "bot_1", "B")
      assert :ok = Partida.responder(pid, "bot_2", "C")

      assert_receive {:fin_ronda, resumen}, 500
      assert resumen.numero == 1
      assert Map.has_key?(resumen.puntos_ronda, "pedro")
      assert Map.has_key?(resumen.puntos_ronda, "bot_1")
      assert Map.has_key?(resumen.puntos_ronda, "bot_2")
    end
  end

  describe "cierre por temporizador" do
    test "cierra automáticamente la ronda al expirar el tiempo y puntúa como sin responder", %{
      gestor: g
    } do
      {:ok, _id, _} =
        GestorPartidas.crear_partida(g, "pedro", "ciencias", 3, 1,
          cliente_pid: self(),
          pausa_ms: 100
        )

      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)
      {:ok, pid} = GestorPartidas.obtener_pid_partida(g, "pedro")
      :ok = Partida.iniciar_partida(pid)

      assert_receive {:nueva_pregunta, _}, 1000

      # Pedro no responde para comprobar que la expiración del temporizador penaliza como sin responder
      # Esperar a que venza el temporizador de 1 segundo
      assert_receive {:fin_ronda, resumen}, 2000
      assert resumen.numero == 1

      assert resumen.detalles_ronda["pedro"].resultado == :sin_responder
      assert resumen.detalles_ronda["pedro"].puntos == 0
    end
  end

  # ── 7. Pausa entre rondas y temporizadores obsoletos ────────────────

  describe "pausa entre rondas" do
    test "rechaza respuestas enviadas durante la pausa entre rondas", %{gestor: g} do
      {:ok, _id, _} =
        GestorPartidas.crear_partida(g, "pedro", "ciencias", 3, 10,
          cliente_pid: self(),
          pausa_ms: 300
        )

      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)
      {:ok, pid} = GestorPartidas.obtener_pid_partida(g, "pedro")
      :ok = Partida.iniciar_partida(pid)

      assert_receive {:nueva_pregunta, %{numero: 1}}, 1000

      :ok = Partida.responder(pid, "pedro", "A")
      :ok = Partida.responder(pid, "bot_1", "A")
      :ok = Partida.responder(pid, "bot_2", "A")

      assert_receive {:fin_ronda, %{numero: 1}}, 500

      # Durante la pausa (ronda no abierta), cualquier respuesta es rechazada
      assert {:error, :ronda_no_abierta} = Partida.responder(pid, "pedro", "A")

      # Después de la pausa de 300ms, se abre la ronda 2
      assert_receive {:nueva_pregunta, %{numero: 2}}, 1000
      assert :ok = Partida.responder(pid, "pedro", "B")
    end

    test "temporizadores obsoletos de rondas previas se ignoran sin afectar la ronda actual", %{
      gestor: g
    } do
      {:ok, _id, _} =
        GestorPartidas.crear_partida(g, "pedro", "ciencias", 3, 15, cliente_pid: self())

      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)
      {:ok, pid} = GestorPartidas.obtener_pid_partida(g, "pedro")
      :ok = Partida.iniciar_partida(pid)

      assert_receive {:nueva_pregunta, %{numero: 1}}, 1000

      send(pid, {:timer_ronda, 0, make_ref()})
      send(pid, {:timer_ronda, 1, make_ref()})

      estado = Partida.obtener_estado(pid)
      assert estado.ronda_abierta == true
      assert estado.pregunta_actual == 1

      assert :ok = Partida.responder(pid, "pedro", "A")
    end
  end

  # ── 8. Finalización, persistencia e idempotencia ─────────────────────

  describe "finalización de partida y ciclo de vida" do
    test "completa todas las rondas, persiste resultado, libera al creador y limpia el proceso",
         %{
           gestor: g,
           persistencia: p,
           supervisor: sup
         } do
      {:ok, id, _} =
        GestorPartidas.crear_partida(g, "pedro", "ciencias", 2, 10,
          cliente_pid: self(),
          pausa_ms: 20,
          limpieza_ms: 50
        )

      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)
      {:ok, pid} = GestorPartidas.obtener_pid_partida(g, "pedro")
      ref = Process.monitor(pid)
      :ok = Partida.iniciar_partida(pid)

      # Ronda 1
      assert_receive {:nueva_pregunta, %{numero: 1}}, 1000
      estado1 = Partida.obtener_estado(pid)
      correcta1 = estado1.pregunta_actual_data["respuesta"]

      :ok = Partida.responder(pid, "pedro", correcta1)
      :ok = Partida.responder(pid, "bot_1", correcta1)
      :ok = Partida.responder(pid, "bot_2", if(correcta1 == "A", do: "B", else: "A"))

      assert_receive {:fin_ronda, %{numero: 1}}, 500

      # Ronda 2
      assert_receive {:nueva_pregunta, %{numero: 2}}, 1000
      estado2 = Partida.obtener_estado(pid)
      correcta2 = estado2.pregunta_actual_data["respuesta"]

      :ok = Partida.responder(pid, "pedro", correcta2)
      :ok = Partida.responder(pid, "bot_1", if(correcta2 == "A", do: "B", else: "A"))
      :ok = Partida.responder(pid, "bot_2", correcta2)

      assert_receive {:fin_ronda, %{numero: 2}}, 500

      # Fin de la partida
      assert_receive {:fin_partida, fin_info}, 1000
      assert fin_info.partida_id == id
      assert fin_info.tema == "ciencias"
      assert is_list(fin_info.ranking)
      assert length(fin_info.ranking) == 3

      # Verificar que se persistió exactamente UNA vez en el historial
      historial = Persistencia.obtener_historial(p)
      partidas_persistidas = Enum.filter(historial, fn registro -> registro["id"] == id end)
      assert length(partidas_persistidas) == 1

      # El creador queda liberado en el gestor para crear otra partida
      assert {:error, :partida_no_encontrada} = GestorPartidas.obtener_partida(g, "pedro")

      # El proceso de partida termina normalmente tras limpieza_ms
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000

      # DynamicSupervisor ya no tiene este proceso
      assert SupervisorPartidas.listar_hijos(sup) == []

      # GestorPartidas ya no tiene la partida en su índice
      assert {:error, :partida_no_encontrada} = GestorPartidas.obtener_pid_partida(g, id)

      # El creador puede crear una nueva partida sin problemas
      assert {:ok, _nuevo_id, _} = GestorPartidas.crear_partida(g, "pedro", "historia", 5, 15)
    end

    test "persistencia no se duplica si se intenta registrar una partida ya existente", %{
      gestor: g,
      persistencia: p
    } do
      {:ok, id, _} =
        GestorPartidas.crear_partida(g, "pedro", "ciencias", 1, 10,
          cliente_pid: self(),
          pausa_ms: 10,
          limpieza_ms: 200
        )

      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)
      {:ok, pid} = GestorPartidas.obtener_pid_partida(g, "pedro")
      :ok = Partida.iniciar_partida(pid)

      assert_receive {:nueva_pregunta, _}, 1000
      :ok = Partida.responder(pid, "pedro", "A")
      :ok = Partida.responder(pid, "bot_1", "B")
      :ok = Partida.responder(pid, "bot_2", "C")

      assert_receive {:fin_partida, _}, 1000

      # Intentar abandonar cuando ya está finalizada
      assert :ok = Partida.abandonar_partida(pid, "pedro")

      historial = Persistencia.obtener_historial(p)
      partidas_persistidas = Enum.filter(historial, fn registro -> registro["id"] == id end)
      assert length(partidas_persistidas) == 1
    end

    test "un intento repetido tras la finalización no emite una segunda notificación de fin_partida",
         %{
           gestor: g
         } do
      {:ok, _id, _} =
        GestorPartidas.crear_partida(g, "pedro", "ciencias", 1, 10,
          cliente_pid: self(),
          pausa_ms: 10,
          limpieza_ms: 500
        )

      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)
      {:ok, pid} = GestorPartidas.obtener_pid_partida(g, "pedro")
      :ok = Partida.iniciar_partida(pid)

      assert_receive {:nueva_pregunta, _}, 1000
      :ok = Partida.responder(pid, "pedro", "A")
      :ok = Partida.responder(pid, "bot_1", "B")
      :ok = Partida.responder(pid, "bot_2", "C")

      assert_receive {:fin_partida, _}, 1000

      # Simular mensaje espurio de reintento o abandono
      send(pid, {:reintentar_persistencia, make_ref()})

      # No debe haber una segunda notificación de fin_partida
      refute_receive {:fin_partida, _}, 300
    end
  end

  # ── 9. Manejo de fallos de persistencia y recuperación ──────────────

  describe "resiliencia ante fallos de persistencia y reintento exitoso" do
    test "conserva estado :pendiente_persistencia, no libera creador y se recupera con reintento",
         %{
           gestor: g,
           persistencia: pers_name,
           pers_pid: pers_pid,
           tmp_dir: tmp_dir
         } do
      # Partida de 1 pregunta con reintento rápido (50ms)
      {:ok, id, _} =
        GestorPartidas.crear_partida(g, "pedro", "ciencias", 1, 10,
          cliente_pid: self(),
          reintento_ms: 50,
          limpieza_ms: 50
        )

      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)
      {:ok, pid} = GestorPartidas.obtener_pid_partida(g, "pedro")
      :ok = Partida.iniciar_partida(pid)

      assert_receive {:nueva_pregunta, _}, 1000

      # Detener el proceso de persistencia antes de terminar la partida
      Process.exit(pers_pid, :kill)

      # Responden los jugadores para finalizar la ronda
      :ok = Partida.responder(pid, "pedro", "A")
      :ok = Partida.responder(pid, "bot_1", "B")
      :ok = Partida.responder(pid, "bot_2", "C")

      assert_receive {:fin_ronda, _}, 500

      # 1. NO debe emitirse la notificación de fin de partida exitoso
      refute_receive {:fin_partida, _}, 300

      # 2. El proceso de la partida permanece VIVO y recuperable
      assert Process.alive?(pid)

      # 3. El estado de la partida es :pendiente_persistencia y conserva el resultado
      estado = Partida.obtener_estado(pid)
      assert estado.estado == :pendiente_persistencia
      assert estado.resultado_persistido == false
      assert is_map(estado.resultado_final)
      assert estado.resultado_final["id"] == id

      # 4. El creador sigue bloqueado en GestorPartidas (no puede crear otra partida)
      assert {:error, :jugador_en_partida} =
               GestorPartidas.crear_partida(g, "pedro", "historia", 5, 15)

      # 5. Restablecer el servicio de persistencia con el mismo nombre y ruta
      {:ok, new_pers_pid} = Persistencia.iniciar_link(data_dir: tmp_dir, name: pers_name)

      on_exit(fn ->
        if Process.alive?(new_pers_pid), do: GenServer.stop(new_pers_pid, :normal, 1000)
      end)

      # 6. El temporizador de reintento debe persistir el resultado exitosamente
      assert_receive {:fin_partida, fin_info}, 1500
      assert fin_info.partida_id == id

      # 7. El historial contiene exactamente UNA entrada (idempotente)
      historial = Persistencia.obtener_historial(pers_name)
      partidas_persistidas = Enum.filter(historial, fn registro -> registro["id"] == id end)
      assert length(partidas_persistidas) == 1

      # 8. El creador queda liberado
      assert {:error, :partida_no_encontrada} = GestorPartidas.obtener_partida(g, "pedro")
      assert {:ok, _nuevo_id, _} = GestorPartidas.crear_partida(g, "pedro", "historia", 5, 15)
    end
  end

  # ── 10. Abandono con mecanismo unificado de persistencia ─────────────

  describe "abandono unificado con persistencia y recuperación" do
    test "abandono en curso con persistencia exitosa persiste resultado y libera al creador", %{
      gestor: g,
      persistencia: p
    } do
      {:ok, id, _} = GestorPartidas.crear_partida(g, "pedro", "ciencias", 5, 15)
      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)
      {:ok, pid} = GestorPartidas.obtener_pid_partida(g, "pedro")
      :ok = Partida.iniciar_partida(pid)

      Partida.actualizar_puntaje(pid, "pedro", 30)
      Partida.actualizar_puntaje(pid, "bot_1", 15)

      # El creador abandona la partida en curso
      assert :ok = GestorPartidas.abandonar_partida(g, "pedro")

      # El resultado fue persistido
      historial = Persistencia.obtener_historial(p)
      partidas_persistidas = Enum.filter(historial, fn registro -> registro["id"] == id end)
      assert length(partidas_persistidas) == 1

      [reg] = partidas_persistidas
      assert reg["puntajes"]["pedro"] == 30
      assert reg["ganador"] == "pedro"

      # Creador queda liberado
      assert {:error, :partida_no_encontrada} = GestorPartidas.obtener_partida(g, "pedro")
      assert {:ok, _nuevo_id, _} = GestorPartidas.crear_partida(g, "pedro", "historia", 5, 15)
    end

    test "abandono con fallo de persistencia pasa a :pendiente_persistencia y se recupera con reintento",
         %{
           gestor: g,
           persistencia: pers_name,
           pers_pid: pers_pid,
           tmp_dir: tmp_dir
         } do
      {:ok, id, _} =
        GestorPartidas.crear_partida(g, "pedro", "ciencias", 5, 15,
          reintento_ms: 50,
          limpieza_ms: 50
        )

      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)
      {:ok, pid} = GestorPartidas.obtener_pid_partida(g, "pedro")
      :ok = Partida.iniciar_partida(pid)

      Partida.actualizar_puntaje(pid, "pedro", 25)

      # Provocar fallo en el proceso de persistencia
      Process.exit(pers_pid, :kill)

      # Pedro intenta abandonar la partida mientras persistencia está caída
      assert {:error, _} = GestorPartidas.abandonar_partida(g, "pedro")

      # 1. El proceso sigue VIVO (no se autodestruye con datos no guardados)
      assert Process.alive?(pid)

      # 2. El estado ya NO es :en_curso, sino :pendiente_persistencia
      estado = Partida.obtener_estado(pid)
      assert estado.estado == :pendiente_persistencia
      assert estado.resultado_persistido == false
      assert estado.resultado_final["id"] == id
      assert estado.resultado_final["puntajes"]["pedro"] == 25

      # 3. El creador sigue bloqueado en GestorPartidas mientras esté pendiente
      assert {:error, :jugador_en_partida} =
               GestorPartidas.crear_partida(g, "pedro", "historia", 5, 15)

      # 4. Restablecer el servicio de persistencia
      {:ok, new_pers_pid} = Persistencia.iniciar_link(data_dir: tmp_dir, name: pers_name)

      on_exit(fn ->
        if Process.alive?(new_pers_pid), do: GenServer.stop(new_pers_pid, :normal, 1000)
      end)

      # 5. Esperar a que el reintento automático persista el resultado
      Process.sleep(200)

      # 6. Historial contiene exactamente UNA entrada
      historial = Persistencia.obtener_historial(pers_name)
      partidas_persistidas = Enum.filter(historial, fn registro -> registro["id"] == id end)
      assert length(partidas_persistidas) == 1

      # 7. El creador queda finalmente liberado
      assert {:error, :partida_no_encontrada} = GestorPartidas.obtener_partida(g, "pedro")
      assert {:ok, _nuevo_id, _} = GestorPartidas.crear_partida(g, "pedro", "historia", 5, 15)
    end
  end
end
