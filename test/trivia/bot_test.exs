defmodule Trivia.BotTest do
  use ExUnit.Case, async: false

  alias Trivia.Bot
  alias Trivia.GestorPartidas
  alias Trivia.Nivel
  alias Trivia.Partida
  alias Trivia.Persistencia
  alias Trivia.SupervisorPartidas

  setup do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "trivia_bot_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(data_dir)

    seed_path = Path.expand("data/questions.json")
    File.cp!(seed_path, Path.join(data_dir, "questions.json"))
    File.write!(Path.join(data_dir, "users.json"), "[]")
    File.write!(Path.join(data_dir, "results.log"), "")

    pers_name = :"pers_#{System.unique_integer([:positive])}"
    {:ok, pers_pid} = Persistencia.iniciar_link(data_dir: data_dir, name: pers_name)
    sup_name = :"sup_#{System.unique_integer([:positive])}"
    {:ok, sup_pid} = SupervisorPartidas.start_link(name: sup_name)

    gestor_name = :"gestor_#{System.unique_integer([:positive])}"

    {:ok, gestor_pid} =
      GestorPartidas.start_link(
        name: gestor_name,
        supervisor: sup_name,
        persistencia: pers_pid
      )

    Process.unlink(sup_pid)
    Process.unlink(gestor_pid)
    Process.unlink(pers_pid)

    on_exit(fn ->
      File.rm_rf(data_dir)
    end)

    %{
      data_dir: data_dir,
      pers_pid: pers_pid,
      sup_pid: sup_pid,
      gestor: gestor_name,
      gestor_pid: gestor_pid
    }
  end

  # ── 1. Lógica pura de decisión: Opciones A, B, C o D ───────────────

  describe "1. La función de decisión siempre retorna A, B, C o D" do
    test "retorna una opción válida en múltiples evaluaciones aleatorias y deterministas" do
      opciones_validas = ["A", "B", "C", "D"]
      dificultades = [:facil, :dificil, "facil", "dificil"]
      niveles = [:basico, :intermedio, :avanzado]
      correctas = ["A", "B", "C", "D"]

      for dif <- dificultades, niv <- niveles, corr <- correctas do
        # Evaluación pura
        decision = Bot.decidir(dif, niv, corr, 15)
        assert decision.respuesta in opciones_validas
        assert decision["respuesta"] in opciones_validas
        assert is_integer(decision.delay_ms)

        # Helper directo
        letra = Bot.decidir_respuesta(dif, niv, corr)
        assert letra in opciones_validas
      end
    end

    test "funciona consistentemente en 500 iteraciones aleatorias" do
      opciones_validas = ["A", "B", "C", "D"]

      for _i <- 1..500 do
        dif = Enum.random([:facil, :dificil])
        niv = Enum.random([:basico, :intermedio, :avanzado])
        corr = Enum.random(["A", "B", "C", "D"])

        decision = Bot.decidir(dif, niv, corr, 15)
        assert decision.respuesta in opciones_validas
      end
    end
  end

  # ── 2. Decisiones incorrectas nunca eligen la respuesta correcta ────

  describe "2. Las decisiones incorrectas nunca seleccionan la respuesta correcta" do
    test "opciones_incorrectas/1 excluye siempre la respuesta correcta" do
      for correcta <- ["A", "B", "C", "D"] do
        incorrectas = Bot.opciones_incorrectas(correcta)
        assert length(incorrectas) == 3
        refute correcta in incorrectas
      end
    end

    test "cuando la decisión es incorrecta, la opción elegida es estrictamente diferente a la correcta" do
      for correcta <- ["A", "B", "C", "D"] do
        for _i <- 1..100 do
          dif = Enum.random([:facil, :dificil])
          niv = Enum.random([:basico, :intermedio, :avanzado])

          # Forzar decisión incorrecta mediante acierto?: false
          decision = Bot.decidir(dif, niv, correcta, 15, acierto?: false)
          assert decision.respuesta != correcta
          assert decision.acerto? == false
          assert decision.respuesta in Bot.opciones_incorrectas(correcta)

          # Forzar mediante prob: 1.0 (siempre mayor a cualquier probabilidad de acierto)
          decision_prob = Bot.decidir(dif, niv, correcta, 15, prob: 1.0)
          assert decision_prob.respuesta != correcta
          assert decision_prob.acerto? == false
        end
      end
    end
  end

  # ── 3. Retardos dentro de los rangos de dificultad ──────────────────

  describe "3. Los retardos de respuesta se mantienen dentro de los rangos requeridos" do
    test "bot fácil responde entre el 40% y el 90% del tiempo_pregunta" do
      {min_r, max_r} = Bot.rango_tiempo(:facil)
      assert min_r == 0.40
      assert max_r == 0.90

      # Para tiempo = 15 s: 6.0 s (6000 ms) a 13.5 s (13500 ms)
      for _i <- 1..100 do
        decision = Bot.decidir(:facil, :basico, "A", 15)
        assert decision.delay_ms >= 6000
        assert decision.delay_ms <= 13500
      end

      # Para tiempo = 10 s: 4000 ms a 9000 ms
      for _i <- 1..50 do
        delay = Bot.decidir_delay(:facil, 10)
        assert delay >= 4000
        assert delay <= 9000
      end

      # Casos límite con time_ratio explícito
      assert Bot.decidir_delay(:facil, 15, time_ratio: 0.0) == 6000
      assert Bot.decidir_delay(:facil, 15, time_ratio: 1.0) == 13500
    end

    test "bot difícil responde entre el 10% y el 40% del tiempo_pregunta" do
      {min_r, max_r} = Bot.rango_tiempo(:dificil)
      assert min_r == 0.10
      assert max_r == 0.40

      # Para tiempo = 15 s: 1.5 s (1500 ms) a 6.0 s (6000 ms)
      for _i <- 1..100 do
        decision = Bot.decidir(:dificil, :basico, "A", 15)
        assert decision.delay_ms >= 1500
        assert decision.delay_ms <= 6000
      end

      # Para tiempo = 10 s: 1000 ms a 4000 ms
      for _i <- 1..50 do
        delay = Bot.decidir_delay(:dificil, 10)
        assert delay >= 1000
        assert delay <= 4000
      end

      # Casos límite con time_ratio explícito
      assert Bot.decidir_delay(:dificil, 15, time_ratio: 0.0) == 1500
      assert Bot.decidir_delay(:dificil, 15, time_ratio: 1.0) == 6000
    end
  end

  # ── 4. Configuración de acierto según especificación ────────────────

  describe "4. Probabilidades de acierto coinciden exactamente con la especificación 6.6" do
    test "probabilidades exactas por dificultad y nivel" do
      # Fácil: 40% básica, 30% intermedia, 20% avanzada
      assert Bot.probabilidad_acierto(:facil, :basico) == 0.40
      assert Bot.probabilidad_acierto(:facil, :intermedio) == 0.30
      assert Bot.probabilidad_acierto(:facil, :avanzado) == 0.20

      # Difícil: 80% básica, 70% intermedia, 60% avanzada
      assert Bot.probabilidad_acierto(:dificil, :basico) == 0.80
      assert Bot.probabilidad_acierto(:dificil, :intermedio) == 0.70
      assert Bot.probabilidad_acierto(:dificil, :avanzado) == 0.60
    end

    test "comportamiento determinista con respecto al umbral de probabilidad" do
      # Difícil básica: umbral 0.80
      assert Bot.decidir(:dificil, :basico, "A", 15, prob: 0.79).acerto? == true
      assert Bot.decidir(:dificil, :basico, "A", 15, prob: 0.80).acerto? == false
      assert Bot.decidir(:dificil, :basico, "A", 15, prob: 0.81).acerto? == false

      # Fácil básica: umbral 0.40
      assert Bot.decidir(:facil, :basico, "B", 15, prob: 0.39).acerto? == true
      assert Bot.decidir(:facil, :basico, "B", 15, prob: 0.40).acerto? == false
      assert Bot.decidir(:facil, :basico, "B", 15, prob: 0.41).acerto? == false
    end
  end

  # ── 5. Proceso Bot recibe notificación y programa respuesta ─────────

  describe "5. Proceso de bot recibe pregunta y programa respuesta de forma asíncrona" do
    test "el bot programa el temporizador y envía la respuesta mediante Trivia.Partida.responder" do
      caller = self()

      # Creamos un proceso falso que simula a la partida
      fake_partida =
        spawn_link(fn ->
          receive do
            {:"$gen_cast", {:registrar_bot, "bot_test", pid}} ->
              send(caller, {:bot_registrado, pid})
          end

          receive do
            {:"$gen_call", from, {:responder, "bot_test", respuesta}} ->
              send(caller, {:respuesta_recibida, respuesta})
              GenServer.reply(from, :ok)
          end
        end)

      # Iniciar bot con tiempo corto para prueba rápida
      {:ok, bot_pid} =
        Bot.start_link(
          nombre: "bot_test",
          dificultad: :dificil,
          partida: fake_partida,
          time_ratio: 0.1
        )

      assert_receive {:bot_registrado, ^bot_pid}, 1000

      # Enviar notificación de nueva pregunta con respuesta correcta
      send(
        bot_pid,
        {:nueva_pregunta,
         %{
           partida_id: "P-TEST",
           numero: 1,
           total: 3,
           nivel: :basico,
           respuesta_correcta: "B",
           tiempo_limite: 1
         }}
      )

      # El bot debe tener su temporizador activo
      estado = Bot.obtener_estado(bot_pid)
      assert estado.ronda_actual == 1
      assert estado.timer_ref != nil

      # La respuesta debe llegar a la partida mediante responder/3
      assert_receive {:respuesta_recibida, resp}, 1500
      assert resp in ["A", "B", "C", "D"]
    end
  end

  # ── 6. Participación de bots en puntuación normal ───────────────────

  describe "6. Bots participan en la puntuación normal de la partida" do
    test "los bots reciben puntos base y bonificación por rapidez en una partida real", %{
      gestor: g
    } do
      {:ok, _id, _} =
        GestorPartidas.crear_partida(g, "pedro", "ciencias", 1, 15,
          cliente_pid: self(),
          bot_opts: [acierto?: true, time_ratio: 0.1]
        )

      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      {:ok, pid} = GestorPartidas.obtener_pid_partida(g, "pedro")

      :ok = Partida.iniciar_partida(pid)

      assert_receive {:nueva_pregunta, %{numero: 1}}, 1000
      estado = Partida.obtener_estado(pid)
      correcta = estado.pregunta_actual_data["respuesta"]

      # Pedro responde inmediatamente
      assert :ok = Partida.responder(pid, "pedro", correcta)

      # Esperar a que la ronda cierre (todos responden o vence)
      assert_receive {:fin_ronda, resumen}, 7000
      assert resumen.numero == 1

      # Los bots deben tener registro de puntos en el resumen
      assert Map.has_key?(resumen.puntos_ronda, "bot_1")
      assert Map.has_key?(resumen.puntos_ronda, "bot_2")
      assert is_integer(resumen.puntos_ronda["bot_1"])
      assert is_integer(resumen.puntos_ronda["bot_2"])

      # Detalles de ronda para los bots
      det_b1 = resumen.detalles_ronda["bot_1"]
      assert det_b1.resultado in [:correcta, :incorrecta]
      assert is_integer(det_b1.puntos)
    end
  end

  # ── 7. Inclusión de bots en el ranking final de la partida ──────────

  describe "7. Bots están incluidos en el ranking final de la partida" do
    test "el ranking final contiene las posiciones de todos los jugadores (humano y bots)", %{
      gestor: g
    } do
      {:ok, _id, _} =
        GestorPartidas.crear_partida(g, "pedro", "ciencias", 1, 10,
          cliente_pid: self(),
          bot_opts: [time_ratio: 0.1]
        )

      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)
      {:ok, pid} = GestorPartidas.obtener_pid_partida(g, "pedro")

      :ok = Partida.iniciar_partida(pid)

      assert_receive {:nueva_pregunta, _}, 1000

      # Simular respuestas inmediatas para cerrar ronda
      :ok = Partida.responder(pid, "pedro", "A")
      :ok = Partida.responder(pid, "bot_1", "A")
      :ok = Partida.responder(pid, "bot_2", "A")

      assert_receive {:fin_partida, resumen_fin}, 2000

      ranking = resumen_fin.ranking
      assert is_list(ranking)
      assert length(ranking) == 3

      jugadores_ranking = Enum.map(ranking, & &1.jugador)
      assert "pedro" in jugadores_ranking
      assert "bot_1" in jugadores_ranking
      assert "bot_2" in jugadores_ranking

      # Puestos están asignados de 1 a 3
      puestos = Enum.map(ranking, & &1.puesto)
      assert 1 in puestos
    end
  end

  # ── 8. Exclusión de bots de estadísticas históricas ─────────────────

  describe "8. Bots están excluidos de estadísticas de jugadores y users.json" do
    test "rechaza registrar usuarios con el prefijo bot_ en users.json", %{pers_pid: p} do
      assert {:error, :usuario_reservado} = Persistencia.registrar_usuario("bot_1", "clave123", p)

      assert {:error, :usuario_reservado} =
               Persistencia.registrar_usuario("bot_carlos", "clave123", p)

      usuarios = Persistencia.listar_usuarios(p)
      assert usuarios == []
    end

    test "rechaza crear partidas con creadores con prefijo bot_", %{gestor: g} do
      assert {:error, :usuario_reservado} =
               GestorPartidas.crear_partida(g, "bot_1", "ciencias", 5, 15)
    end

    test "puntaje_por_tema retorna 0 para bots aunque existan en el historial", %{
      pers_pid: p
    } do
      resultado = %{
        "id" => "P-1001",
        "tema" => "ciencias",
        "nivel" => "basico",
        "ganador" => "bot_1",
        "puntajes" => %{
          "pedro" => 40,
          "bot_1" => 80,
          "bot_2" => 20
        }
      }

      :ok = Persistencia.registrar_resultado(resultado, p)
      historial = Persistencia.obtener_historial(p)

      # El humano acumula sus puntos normalmente
      assert Nivel.puntaje_por_tema(historial, "pedro", "ciencias") == 40

      # Los bots son ignorados en las estadísticas históricas
      assert Nivel.puntaje_por_tema(historial, "bot_1", "ciencias") == 0
      assert Nivel.puntaje_por_tema(historial, "bot_2", "ciencias") == 0
    end

    test "ranking_historico excluye a los bots del ranking global acumulado" do
      historial = [
        %{
          "tema" => "ciencias",
          "puntajes" => %{
            "pedro" => 40,
            "bot_1" => 90,
            "carlos" => 25
          }
        }
      ]

      ranking = Nivel.ranking_historico(historial)
      jugadores = Enum.map(ranking, & &1.jugador)

      assert "pedro" in jugadores
      assert "carlos" in jugadores
      refute "bot_1" in jugadores
    end
  end

  # ── 9. Terminación de bots al finalizar la partida ──────────────────

  describe "9. Bots terminan apropiadamente cuando su partida termina" do
    test "los procesos de los bots mueren cuando la partida finaliza", %{gestor: g} do
      {:ok, _id, _} =
        GestorPartidas.crear_partida(g, "pedro", "ciencias", 1, 10,
          cliente_pid: self(),
          limpieza_ms: 50
        )

      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)
      {:ok, pid} = GestorPartidas.obtener_pid_partida(g, "pedro")

      estado = Partida.obtener_estado(pid)
      bot_pids = Map.values(estado.bot_pids)
      assert length(bot_pids) == 2
      assert Enum.all?(bot_pids, &Process.alive?/1)

      # Iniciar y responder para terminar la partida
      :ok = Partida.iniciar_partida(pid)
      assert_receive {:nueva_pregunta, _}, 1000

      :ok = Partida.responder(pid, "pedro", "A")
      :ok = Partida.responder(pid, "bot_1", "A")
      :ok = Partida.responder(pid, "bot_2", "A")

      assert_receive {:fin_partida, _}, 2000

      # Esperar a que la limpieza de la partida termine el proceso
      Process.sleep(150)

      # Los procesos de los bots deben haber terminado
      assert Enum.all?(bot_pids, fn b_pid -> not Process.alive?(b_pid) end)
    end

    test "los procesos de los bots mueren cuando la partida se abandona", %{gestor: g} do
      {:ok, _id, _} = GestorPartidas.crear_partida(g, "pedro", "ciencias", 5, 15)
      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)
      {:ok, pid} = GestorPartidas.obtener_pid_partida(g, "pedro")

      estado = Partida.obtener_estado(pid)
      bot_pids = Map.values(estado.bot_pids)
      assert Enum.all?(bot_pids, &Process.alive?/1)

      assert :ok = GestorPartidas.abandonar_partida(g, "pedro")
      Process.sleep(50)

      assert Enum.all?(bot_pids, fn b_pid -> not Process.alive?(b_pid) end)
    end
  end

  # ── 10. Aislamiento ante fallas de bots ──────────────────────────────

  describe "10. La falla de un bot no afecta a partidas no relacionadas" do
    test "la caída anormal de un bot en una partida no afecta a otra partida activa", %{
      gestor: g
    } do
      # Partida 1 de Pedro
      {:ok, id1, _} = GestorPartidas.crear_partida(g, "pedro", "ciencias", 5, 15)
      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)
      {:ok, pid1} = GestorPartidas.obtener_pid_partida(g, "pedro")

      # Partida 2 de Carlos
      {:ok, id2, _} = GestorPartidas.crear_partida(g, "carlos", "ciencias", 5, 15)
      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "carlos", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "carlos", :dificil)
      {:ok, pid2} = GestorPartidas.obtener_pid_partida(g, "carlos")

      # Obtener el PID de un bot en la Partida 1 y terminarlo anormalmente
      estado1 = Partida.obtener_estado(pid1)
      [bot1_pid | _] = Map.values(estado1.bot_pids)

      Process.exit(bot1_pid, :kill)
      Process.sleep(50)

      # La Partida 2 de Carlos sigue completamente viva y operativa
      assert Process.alive?(pid2)
      estado2 = Partida.obtener_estado(pid2)
      assert estado2.id == id2
      assert length(estado2.jugadores) == 3
      assert Enum.all?(Map.values(estado2.bot_pids), &Process.alive?/1)

      # El GestorPartidas sigue perfectamente operativo
      assert {:ok, ^id2} = GestorPartidas.obtener_partida(g, "carlos")
      assert {:ok, ^id1} = GestorPartidas.obtener_partida(g, "pedro")
    end
  end
end
