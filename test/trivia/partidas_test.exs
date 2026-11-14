defmodule Trivia.PartidasTest do
  use ExUnit.Case, async: true

  alias Trivia.GestorPartidas
  alias Trivia.Partida
  alias Trivia.Persistencia
  alias Trivia.SupervisorPartidas

  @moduletag :partidas

  setup do
    unique_id = :erlang.unique_integer([:positive])
    sup_name = :"supervisor_partidas_#{unique_id}"
    gestor_name = :"gestor_partidas_#{unique_id}"
    pers_name = :"persistencia_#{unique_id}"

    tmp_dir = Path.join(System.tmp_dir!(), "trivia_test_#{unique_id}")
    File.mkdir_p!(tmp_dir)

    # Copiar archivo semilla de preguntas al directorio temporal
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

  # ── 1. Creación de una partida independiente ────────────────────────

  describe "creación de partida" do
    test "crea una partida con su estado inicial correcto", %{gestor: g} do
      assert {:ok, id, nivel} = GestorPartidas.crear_partida(g, "pedro", "ciencia", 5, 15)
      assert String.starts_with?(id, "P-")
      assert nivel == :basico

      # Ubicar partida sin exponer el PID
      assert {:ok, ^id} = GestorPartidas.obtener_partida(g, "pedro")

      # Verificar estado interno de la partida
      assert {:ok, estado} = GestorPartidas.obtener_estado_partida(g, "pedro")
      assert estado.id == id
      assert estado.creador == "pedro"
      assert estado.tema == "ciencia"
      assert estado.nivel == :basico
      assert estado.total_preguntas == 5
      assert estado.tiempo_pregunta == 15
      assert estado.jugadores == ["pedro"]
      assert estado.bots == []
      assert estado.estado == :esperando
      assert estado.puntajes == %{"pedro" => 0}
      assert estado.pregunta_actual == 0
    end
  end

  # ── 2. Agregar dos bots exitosamente ────────────────────────────────

  describe "agregar bots" do
    test "agrega dos bots correctamente con nombres automáticos", %{gestor: g} do
      {:ok, _id, _} = GestorPartidas.crear_partida(g, "pedro", "ciencia", 5, 15)

      assert {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      assert {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)

      {:ok, estado} = GestorPartidas.obtener_estado_partida(g, "pedro")
      assert length(estado.bots) == 2
      assert estado.jugadores == ["pedro", "bot_1", "bot_2"]
      assert estado.puntajes == %{"pedro" => 0, "bot_1" => 0, "bot_2" => 0}

      [b1, b2] = estado.bots
      assert b1 == %{nombre: "bot_1", dificultad: :facil}
      assert b2 == %{nombre: "bot_2", dificultad: :dificil}
    end
  end

  # ── 3. Rechazar un cuarto jugador (máximo 4 jugadores = creador + 3 bots)

  describe "límite de jugadores en partida" do
    test "rechaza agregar un cuarto bot cuando la partida alcanza 4 jugadores", %{gestor: g} do
      {:ok, _id, _} = GestorPartidas.crear_partida(g, "pedro", "ciencia", 5, 15)

      assert {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      assert {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      assert {:ok, "bot_3"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)

      # 1 creador + 3 bots = 4 jugadores (máximo permitido)
      assert {:error, :partida_llena} = GestorPartidas.agregar_bot(g, "pedro", :facil)
    end
  end

  # ── 4. Rechazar agregar bots una vez iniciada la partida ────────────

  describe "rechazo de bots en partida iniciada" do
    test "no permite agregar bots una vez que la partida pasó a :en_curso", %{gestor: g} do
      {:ok, _id, _} = GestorPartidas.crear_partida(g, "pedro", "ciencia", 5, 15)
      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :facil)

      assert :ok = GestorPartidas.iniciar_partida(g, "pedro")
      {:ok, estado} = GestorPartidas.obtener_estado_partida(g, "pedro")
      assert estado.estado == :en_curso

      assert {:error, :partida_en_curso} = GestorPartidas.agregar_bot(g, "pedro", :facil)
    end
  end

  # ── 5. Rechazar start_game con menos de dos bots ────────────────────

  describe "requisito mínimo de bots para iniciar" do
    test "rechaza iniciar sin ningún bot", %{gestor: g} do
      {:ok, _id, _} = GestorPartidas.crear_partida(g, "pedro", "ciencia", 5, 15)
      assert {:error, :minimo_dos_bots} = GestorPartidas.iniciar_partida(g, "pedro")
    end

    test "rechaza iniciar con solo un bot agregado", %{gestor: g} do
      {:ok, _id, _} = GestorPartidas.crear_partida(g, "pedro", "ciencia", 5, 15)
      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)

      assert {:error, :minimo_dos_bots} = GestorPartidas.iniciar_partida(g, "pedro")
    end

    test "inicia exitosamente cuando hay al menos dos bots", %{gestor: g} do
      {:ok, _id, _} = GestorPartidas.crear_partida(g, "pedro", "ciencia", 5, 15)
      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :facil)

      assert :ok = GestorPartidas.iniciar_partida(g, "pedro")
      {:ok, estado} = GestorPartidas.obtener_estado_partida(g, "pedro")
      assert estado.estado == :en_curso
    end
  end

  # ── 6. Prevenir que un jugador cree dos partidas activas ────────────

  describe "unicidad de partida por jugador" do
    test "rechaza que un jugador cree una segunda partida si ya tiene una activa", %{gestor: g} do
      assert {:ok, _id1, _} = GestorPartidas.crear_partida(g, "pedro", "ciencia", 5, 15)

      assert {:error, :jugador_en_partida} =
               GestorPartidas.crear_partida(g, "pedro", "historia", 10, 20)
    end
  end

  # ── 7. Ejecución simultánea de dos partidas independientes ──────────

  describe "concurrencia e independencia entre partidas" do
    test "dos partidas corren en procesos separados sin interferir", %{gestor: g} do
      assert {:ok, id1, _} = GestorPartidas.crear_partida(g, "pedro", "ciencia", 5, 15)
      assert {:ok, id2, _} = GestorPartidas.crear_partida(g, "carlos", "historia", 10, 20)

      # Identificadores distintos
      refute id1 == id2

      # Procesos independientes
      assert {:ok, pid1} = GestorPartidas.obtener_pid_partida(g, "pedro")
      assert {:ok, pid2} = GestorPartidas.obtener_pid_partida(g, "carlos")
      refute pid1 == pid2

      # Agregar bots a la partida de Pedro no altera la partida de Carlos
      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)

      {:ok, estado1} = GestorPartidas.obtener_estado_partida(g, "pedro")
      {:ok, estado2} = GestorPartidas.obtener_estado_partida(g, "carlos")

      assert length(estado1.bots) == 2
      assert length(estado2.bots) == 0

      # Iniciar la partida de Pedro no afecta el estado de la de Carlos
      assert :ok = GestorPartidas.iniciar_partida(g, "pedro")

      {:ok, estado1_post} = GestorPartidas.obtener_estado_partida(g, "pedro")
      {:ok, estado2_post} = GestorPartidas.obtener_estado_partida(g, "carlos")

      assert estado1_post.estado == :en_curso
      assert estado2_post.estado == :esperando
    end
  end

  # ── 8. Reinicio de partida caída sin afectar a otras partidas ───────

  describe "reinicio por falla anormal y resiliencia" do
    test "una partida que choca se reinicia a :esperando con aviso al creador y sin afectar a otra partida",
         %{gestor: g} do
      # Pedro crea su partida registrando el proceso actual como receptor de notificaciones
      {:ok, id1, _} =
        GestorPartidas.crear_partida(g, "pedro", "ciencia", 5, 15, cliente_pid: self())

      {:ok, id2, _} =
        GestorPartidas.crear_partida(g, "carlos", "historia", 10, 20)

      # Pedro agrega bots
      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)

      {:ok, pid1_original} = GestorPartidas.obtener_pid_partida(g, id1)
      {:ok, pid2_original} = GestorPartidas.obtener_pid_partida(g, id2)

      # Provocar falla anormal en la partida de Pedro simulando choque
      Process.exit(pid1_original, :kill)

      # La partida de Carlos debe seguir viva y sin alteración
      assert Process.alive?(pid2_original)
      assert {:ok, pid2_actual} = GestorPartidas.obtener_pid_partida(g, id2)
      assert pid2_actual == pid2_original

      # El creador (Pedro) debe recibir la notificación de reinicio
      assert_receive {:partida_reiniciada, ^id1, aviso}, 2000
      assert aviso =~ "La partida #{id1} falló y se reinició sin su progreso"

      # Esperar a que el gestor registre el nuevo PID
      # El gestor debe actualizar el PID de la partida reiniciada
      {:ok, pid1_nuevo} = GestorPartidas.obtener_pid_partida(g, id1)
      refute pid1_nuevo == pid1_original
      assert Process.alive?(pid1_nuevo)

      # Estado reiniciado: debe estar en :esperando, sin bots y solo con el creador
      {:ok, estado_reiniciado} = GestorPartidas.obtener_estado_partida(g, id1)
      assert estado_reiniciado.estado == :esperando
      assert estado_reiniciado.bots == []
      assert estado_reiniciado.jugadores == ["pedro"]
      assert estado_reiniciado.puntajes == %{"pedro" => 0}
      assert estado_reiniciado.pregunta_actual == 0

      # La partida reiniciada permite volver a agregar bots e iniciar
      assert {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      assert {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)
      assert :ok = GestorPartidas.iniciar_partida(g, "pedro")
      {:ok, estado_final} = GestorPartidas.obtener_estado_partida(g, id1)
      assert estado_final.estado == :en_curso
    end
  end

  # ── 9. Cancelación voluntaria por abandono antes de iniciar ─────────

  describe "abandono voluntario antes de iniciar" do
    test "termina la partida normalmente sin reinicio y libera al jugador", %{
      gestor: g,
      supervisor: sup
    } do
      {:ok, id, _} = GestorPartidas.crear_partida(g, "pedro", "ciencia", 5, 15)
      {:ok, pid} = GestorPartidas.obtener_pid_partida(g, id)

      # El creador abandona la partida
      assert :ok = GestorPartidas.abandonar_partida(g, "pedro")

      # El proceso termina
      refute Process.alive?(pid)

      # Al ser terminación normal, NO se reinicia
      # Dar un instante para confirmar que no se genera un nuevo hijo
      Process.sleep(50)
      assert SupervisorPartidas.listar_hijos(sup) == []

      # Pedro queda libre para crear otra partida
      assert {:error, :partida_no_encontrada} = GestorPartidas.obtener_partida(g, "pedro")
      assert {:ok, _nuevo_id, _} = GestorPartidas.crear_partida(g, "pedro", "historia", 5, 15)
    end
  end

  # ── 10. Dificultad Adaptativa ───────────────────────────────────────

  describe "dificultad adaptativa" do
    test "jugador sin historial recibe :basico", %{gestor: g} do
      assert {:ok, _id, :basico} =
               GestorPartidas.crear_partida(g, "nuevo_jugador", "ciencias", 5, 15)
    end

    test "jugador con 0 puntos históricos recibe :basico", %{gestor: g, persistencia: p} do
      Persistencia.registrar_resultado(
        %{"tema" => "ciencias", "puntajes" => %{"ana" => 0}},
        p
      )

      assert {:ok, _id, :basico} = GestorPartidas.crear_partida(g, "ana", "ciencias", 5, 15)
    end

    test "jugador con 59 puntos recibe :basico", %{gestor: g, persistencia: p} do
      Persistencia.registrar_resultado(
        %{"tema" => "ciencias", "puntajes" => %{"ana" => 59}},
        p
      )

      assert {:ok, _id, :basico} = GestorPartidas.crear_partida(g, "ana", "ciencias", 5, 15)
    end

    test "jugador con 60 puntos recibe :intermedio", %{gestor: g, persistencia: p} do
      Persistencia.registrar_resultado(
        %{"tema" => "ciencias", "puntajes" => %{"ana" => 60}},
        p
      )

      assert {:ok, _id, :intermedio} = GestorPartidas.crear_partida(g, "ana", "ciencias", 5, 15)
    end

    test "jugador con 179 puntos recibe :intermedio", %{gestor: g, persistencia: p} do
      Persistencia.registrar_resultado(
        %{"tema" => "ciencias", "puntajes" => %{"ana" => 179}},
        p
      )

      assert {:ok, _id, :intermedio} = GestorPartidas.crear_partida(g, "ana", "ciencias", 5, 15)
    end

    test "jugador con 180 puntos recibe :avanzado", %{gestor: g, persistencia: p} do
      Persistencia.registrar_resultado(
        %{"tema" => "ciencias", "puntajes" => %{"ana" => 180}},
        p
      )

      assert {:ok, _id, :avanzado} = GestorPartidas.crear_partida(g, "ana", "ciencias", 5, 15)
    end

    test "puntajes históricos negativos resultan en :basico", %{gestor: g, persistencia: p} do
      Persistencia.registrar_resultado(
        %{"tema" => "ciencias", "puntajes" => %{"ana" => -40}},
        p
      )

      assert {:ok, _id, :basico} = GestorPartidas.crear_partida(g, "ana", "ciencias", 5, 15)
    end

    test "puntajes de otros temas no influyen en el tema seleccionado", %{
      gestor: g,
      persistencia: p
    } do
      # 300 puntos en historia no afectan a ciencias
      Persistencia.registrar_resultado(
        %{"tema" => "historia", "puntajes" => %{"ana" => 300}},
        p
      )

      assert {:ok, _id, :basico} = GestorPartidas.crear_partida(g, "ana", "ciencias", 5, 15)
    end

    test "errores al obtener el historial impiden la creación de la partida", %{
      gestor: g,
      tmp_dir: dir
    } do
      # Corromper results.log con contenido inválido
      File.write!(Path.join(dir, "results.log"), "{{invalid_ndjson}}")

      assert {:error, :json_invalido} =
               GestorPartidas.crear_partida(g, "ana", "ciencias", 5, 15)
    end
  end

  # ── 11. Persistencia de Resultados al Abandonar ─────────────────────

  describe "persistencia de resultados al abandonar" do
    test "abandonar antes de iniciar no escribe ningún resultado en results.log", %{
      gestor: g,
      persistencia: p
    } do
      {:ok, _id, _} = GestorPartidas.crear_partida(g, "pedro", "ciencias", 5, 15)
      assert :ok = GestorPartidas.abandonar_partida(g, "pedro")
      assert Persistencia.obtener_historial(p) == []
    end

    test "abandonar una partida en curso escribe exactamente un resultado", %{
      gestor: g,
      persistencia: p
    } do
      {:ok, _id, _} = GestorPartidas.crear_partida(g, "pedro", "ciencias", 5, 15)
      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)
      :ok = GestorPartidas.iniciar_partida(g, "pedro")

      assert :ok = GestorPartidas.abandonar_partida(g, "pedro")
      historial = Persistencia.obtener_historial(p)
      assert length(historial) == 1
    end

    test "el resultado contiene id, fecha, tema, nivel, ganador y puntajes correctos", %{
      gestor: g,
      persistencia: p
    } do
      {:ok, id, nivel} = GestorPartidas.crear_partida(g, "pedro", "ciencias", 5, 15)
      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)
      {:ok, pid} = GestorPartidas.obtener_pid_partida(g, "pedro")
      :ok = GestorPartidas.iniciar_partida(g, "pedro")

      # Simular puntajes acumulados antes del abandono
      Partida.actualizar_puntaje(pid, "pedro", 35)
      Partida.actualizar_puntaje(pid, "bot_1", 20)
      Partida.actualizar_puntaje(pid, "bot_2", -5)

      assert :ok = GestorPartidas.abandonar_partida(g, "pedro")

      [resultado] = Persistencia.obtener_historial(p)
      assert resultado["id"] == id
      assert resultado["tema"] == "ciencias"
      assert resultado["nivel"] == to_string(nivel)
      assert resultado["ganador"] == "pedro"
      assert resultado["puntajes"] == %{"pedro" => 35, "bot_1" => 20, "bot_2" => -5}
      assert is_binary(resultado["fecha"])
    end

    test "empate en el puntaje más alto registra ganador compartido", %{
      gestor: g,
      persistencia: p
    } do
      {:ok, _id, _} = GestorPartidas.crear_partida(g, "pedro", "ciencias", 5, 15)
      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)
      {:ok, pid} = GestorPartidas.obtener_pid_partida(g, "pedro")
      :ok = GestorPartidas.iniciar_partida(g, "pedro")

      # Empate entre pedro y bot_1
      Partida.actualizar_puntaje(pid, "pedro", 20)
      Partida.actualizar_puntaje(pid, "bot_1", 20)
      Partida.actualizar_puntaje(pid, "bot_2", 10)

      assert :ok = GestorPartidas.abandonar_partida(g, "pedro")

      [resultado] = Persistencia.obtener_historial(p)
      assert resultado["ganador"] == "bot_1, pedro"
    end

    test "errores de persistencia se manejan explícitamente sin perder la partida", %{
      gestor: g,
      pers_pid: pers_pid
    } do
      {:ok, _id, _} = GestorPartidas.crear_partida(g, "pedro", "ciencias", 5, 15)
      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)
      :ok = GestorPartidas.iniciar_partida(g, "pedro")

      # Detener el proceso de persistencia para inducir un fallo
      Process.exit(pers_pid, :kill)

      # Intentar abandonar la partida: debe retornar un error explícito y no terminar en silencio
      assert {:error, _reason} = GestorPartidas.abandonar_partida(g, "pedro")

      # El jugador sigue asociado a la partida para no perder el estado
      assert {:ok, _partida_id} = GestorPartidas.obtener_partida(g, "pedro")
    end

    test "la cancelación normal libera la asociación del creador", %{gestor: g} do
      {:ok, _id, _} = GestorPartidas.crear_partida(g, "pedro", "ciencias", 5, 15)
      assert :ok = GestorPartidas.abandonar_partida(g, "pedro")
      assert {:error, :partida_no_encontrada} = GestorPartidas.obtener_partida(g, "pedro")
    end
  end

  # ── 12. Validación del Banco de Preguntas ────────────────────────────

  describe "validación de parámetros de creación" do
    test "rechaza total_preguntas igual a cero", %{gestor: g} do
      assert {:error, :parametros_invalidos} =
               GestorPartidas.crear_partida(g, "pedro", "ciencias", 0, 15)
    end

    test "rechaza total_preguntas negativo", %{gestor: g} do
      assert {:error, :parametros_invalidos} =
               GestorPartidas.crear_partida(g, "pedro", "ciencias", -5, 15)
    end

    test "rechaza total_preguntas no entero (float)", %{gestor: g} do
      assert {:error, :parametros_invalidos} =
               GestorPartidas.crear_partida(g, "pedro", "ciencias", 5.5, 15)
    end

    test "rechaza total_preguntas no entero (string)", %{gestor: g} do
      assert {:error, :parametros_invalidos} =
               GestorPartidas.crear_partida(g, "pedro", "ciencias", "cinco", 15)
    end

    test "rechaza tiempo_pregunta igual a cero", %{gestor: g} do
      assert {:error, :parametros_invalidos} =
               GestorPartidas.crear_partida(g, "pedro", "ciencias", 5, 0)
    end

    test "rechaza tiempo_pregunta negativo", %{gestor: g} do
      assert {:error, :parametros_invalidos} =
               GestorPartidas.crear_partida(g, "pedro", "ciencias", 5, -10)
    end

    test "acepta parámetros válidos positivos", %{gestor: g} do
      assert {:ok, _id, _nivel} =
               GestorPartidas.crear_partida(g, "pedro", "ciencias", 5, 15)
    end
  end

  describe "validación del banco de preguntas" do
    test "banco válido permite la creación de la partida", %{gestor: g} do
      assert {:ok, _id, _nivel} = GestorPartidas.crear_partida(g, "pedro", "ciencias", 5, 15)
    end

    test "tema inexistente impide la creación de la partida", %{gestor: g} do
      assert {:error, :tema_inexistente} =
               GestorPartidas.crear_partida(g, "pedro", "tema_invalido", 5, 15)
    end

    test "preguntas insuficientes impiden la creación de la partida", %{gestor: g} do
      # El tema ciencias tiene 24 preguntas; pedir 50 excede la disponibilidad
      assert {:error, :preguntas_insuficientes} =
               GestorPartidas.crear_partida(g, "pedro", "ciencias", 50, 15)
    end

    test "archivo de preguntas faltante impide la creación de la partida", %{
      supervisor: sup,
      tmp_dir: dir
    } do
      File.rm!(Path.join(dir, "questions.json"))
      uid = :erlang.unique_integer([:positive])
      pers_missing = :"pers_missing_#{uid}"
      gestor_missing = :"gestor_missing_#{uid}"

      {:ok, pers_pid} = Persistencia.iniciar_link(data_dir: dir, name: pers_missing)

      {:ok, gestor_pid} =
        GestorPartidas.start_link(
          name: gestor_missing,
          supervisor: sup,
          persistencia: pers_missing
        )

      on_exit(fn ->
        if Process.alive?(gestor_pid), do: GenServer.stop(gestor_pid)
        if Process.alive?(pers_pid), do: GenServer.stop(pers_pid)
      end)

      assert {:error, :archivo_no_encontrado} =
               GestorPartidas.crear_partida(gestor_missing, "pedro", "ciencias", 5, 15)
    end

    test "datos de preguntas malformados impiden la creación de la partida", %{
      supervisor: sup,
      tmp_dir: dir
    } do
      File.write!(Path.join(dir, "questions.json"), "{bad_json")
      uid = :erlang.unique_integer([:positive])
      pers_bad = :"pers_bad_#{uid}"
      gestor_bad = :"gestor_bad_#{uid}"

      {:ok, pers_pid} = Persistencia.iniciar_link(data_dir: dir, name: pers_bad)

      {:ok, gestor_pid} =
        GestorPartidas.start_link(
          name: gestor_bad,
          supervisor: sup,
          persistencia: pers_bad
        )

      on_exit(fn ->
        if Process.alive?(gestor_pid), do: GenServer.stop(gestor_pid)
        if Process.alive?(pers_pid), do: GenServer.stop(pers_pid)
      end)

      assert {:error, :json_invalido} =
               GestorPartidas.crear_partida(gestor_bad, "pedro", "ciencias", 5, 15)
    end

    test "múltiples partidas usan el banco en caché sin releer questions.json en cada creación",
         %{
           gestor: g,
           tmp_dir: dir
         } do
      # Eliminar questions.json después del arranque para demostrar que el banco ya está en memoria
      File.rm!(Path.join(dir, "questions.json"))

      assert {:ok, id1, :basico} = GestorPartidas.crear_partida(g, "pedro", "ciencias", 5, 15)
      assert {:ok, id2, :basico} = GestorPartidas.crear_partida(g, "carlos", "historia", 5, 15)
      assert id1 != id2

      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)
      assert :ok = GestorPartidas.iniciar_partida(g, "pedro")

      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "carlos", :dificil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "carlos", :facil)
      assert :ok = GestorPartidas.iniciar_partida(g, "carlos")

      {:ok, est_pedro} = GestorPartidas.obtener_estado_partida(g, id1)
      {:ok, est_carlos} = GestorPartidas.obtener_estado_partida(g, id2)
      assert length(est_pedro.preguntas) == 5
      assert length(est_carlos.preguntas) == 5
    end

    test "falla en el proceso de persistencia impide la creación de la partida", %{
      gestor: g,
      pers_pid: pers_pid
    } do
      Process.exit(pers_pid, :kill)
      assert {:error, _reason} = GestorPartidas.crear_partida(g, "pedro", "ciencias", 5, 15)
    end
  end

  # ── 13. Validación de actualización de puntajes ─────────────────────

  describe "validación de actualizar_puntaje" do
    setup %{gestor: g} do
      {:ok, _id, _} = GestorPartidas.crear_partida(g, "pedro", "ciencias", 5, 15)
      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "pedro", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g, "pedro", :dificil)
      {:ok, pid} = GestorPartidas.obtener_pid_partida(g, "pedro")
      %{pid: pid}
    end

    test "rechaza actualizar puntaje cuando la partida está en :esperando", %{pid: pid} do
      assert {:error, :partida_no_en_curso} = Partida.actualizar_puntaje(pid, "pedro", 10)
    end

    test "rechaza actualizar puntaje de un jugador no registrado", %{pid: pid} do
      :ok = Partida.iniciar_partida(pid)
      assert {:error, :jugador_no_registrado} = Partida.actualizar_puntaje(pid, "desconocido", 10)
    end

    test "rechaza puntos no enteros (float)", %{pid: pid} do
      :ok = Partida.iniciar_partida(pid)
      assert {:error, :puntos_invalidos} = Partida.actualizar_puntaje(pid, "pedro", 10.5)
    end

    test "rechaza puntos no enteros (string)", %{pid: pid} do
      :ok = Partida.iniciar_partida(pid)
      assert {:error, :puntos_invalidos} = Partida.actualizar_puntaje(pid, "pedro", "diez")
    end

    test "acepta puntos negativos (válido según especificación)", %{pid: pid} do
      :ok = Partida.iniciar_partida(pid)
      assert :ok = Partida.actualizar_puntaje(pid, "pedro", -15)
      estado = Partida.obtener_estado(pid)
      assert estado.puntajes["pedro"] == -15
    end

    test "acepta puntos cero", %{pid: pid} do
      :ok = Partida.iniciar_partida(pid)
      assert :ok = Partida.actualizar_puntaje(pid, "pedro", 0)
      estado = Partida.obtener_estado(pid)
      assert estado.puntajes["pedro"] == 0
    end

    test "actualización válida de un jugador registrado en partida en curso", %{pid: pid} do
      :ok = Partida.iniciar_partida(pid)
      assert :ok = Partida.actualizar_puntaje(pid, "pedro", 35)
      assert :ok = Partida.actualizar_puntaje(pid, "bot_1", 20)
      estado = Partida.obtener_estado(pid)
      assert estado.puntajes["pedro"] == 35
      assert estado.puntajes["bot_1"] == 20
    end
  end
end
