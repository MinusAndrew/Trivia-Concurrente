defmodule Trivia.IdsPartidaTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Trivia.GestorPartidas
  alias Trivia.Partida
  alias Trivia.Persistencia
  alias Trivia.SupervisorPartidas

  @moduletag :ids_partida

  setup do
    unique_id = :erlang.unique_integer([:positive])
    tmp_dir = Path.join(System.tmp_dir!(), "trivia_ids_test_#{unique_id}")
    File.mkdir_p!(tmp_dir)

    # Copiar preguntas semilla
    seed_path = Path.expand("data/questions.json")
    File.cp!(seed_path, Path.join(tmp_dir, "questions.json"))

    sup_name = :"supervisor_ids_#{unique_id}"
    {:ok, sup_pid} = SupervisorPartidas.start_link(name: sup_name)
    Process.unlink(sup_pid)

    on_exit(fn ->
      if Process.alive?(sup_pid) do
        try do
          Supervisor.stop(sup_pid, :normal, 1000)
        catch
          :exit, _ -> :ok
        end
      end

      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir, supervisor: sup_name, uid: unique_id}
  end

  # Arranca Persistencia y luego GestorPartidas (mismo orden que Trivia.Supervisor).
  # `generacion` distingue los nombres de cada "arranque" del servidor simulado.
  defp arrancar(%{tmp_dir: dir, supervisor: sup, uid: uid}, generacion) do
    pers_name = :"persistencia_ids_#{uid}_#{generacion}"
    gestor_name = :"gestor_ids_#{uid}_#{generacion}"

    {:ok, pers_pid} = Persistencia.iniciar_link(data_dir: dir, name: pers_name)

    {:ok, gestor_pid} =
      GestorPartidas.start_link(name: gestor_name, supervisor: sup, persistencia: pers_name)

    Process.unlink(pers_pid)
    Process.unlink(gestor_pid)

    on_exit(fn -> detener([gestor_pid, pers_pid]) end)

    %{gestor: gestor_name, persistencia: pers_name, pids: [gestor_pid, pers_pid]}
  end

  defp detener(pids) do
    Enum.each(pids, fn pid ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid, :normal, 1000)
        catch
          :exit, _ -> :ok
        end
      end
    end)
  end

  defp sembrar_historial(dir, ids) do
    contenido =
      Enum.map_join(ids, fn id ->
        Jason.encode!(%{
          "id" => id,
          "tema" => "historia",
          "nivel" => "basico",
          "ganador" => "otro",
          "puntajes" => %{"otro" => 10}
        }) <> "\n"
      end)

    File.write!(Path.join(dir, "results.log"), contenido)
  end

  defp lineas_resultados(dir) do
    case File.read(Path.join(dir, "results.log")) do
      {:ok, contenido} -> String.split(contenido, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  # Inicia la partida del creador y la termina por abandono, lo que persiste
  # el resultado con los puntajes acumulados (sin depender de temporizadores).
  defp terminar_por_abandono(gestor, creador) do
    {:ok, "bot_1"} = GestorPartidas.agregar_bot(gestor, creador, :facil)
    {:ok, "bot_2"} = GestorPartidas.agregar_bot(gestor, creador, :dificil)
    {:ok, pid} = GestorPartidas.obtener_pid_partida(gestor, creador)
    :ok = Partida.iniciar_partida(pid)
    Partida.actualizar_puntaje(pid, creador, 30)
    :ok = GestorPartidas.abandonar_partida(gestor, creador)
  end

  defp ids_historial(persistencia) do
    persistencia
    |> Persistencia.obtener_historial()
    |> Enum.map(fn registro -> registro["id"] end)
  end

  describe "contador de ids recuperado del historial" do
    test "con P-1001 y P-1002 en el historial, la primera partida es P-1003 y su resultado se guarda",
         ctx do
      sembrar_historial(ctx.tmp_dir, ["P-1001", "P-1002"])
      %{gestor: g, persistencia: p} = arrancar(ctx, 1)

      assert {:ok, "P-1003", _} = GestorPartidas.crear_partida(g, "pedro", "ciencias", 5, 15)
      terminar_por_abandono(g, "pedro")

      assert length(lineas_resultados(ctx.tmp_dir)) == 3
      assert ids_historial(p) == ["P-1001", "P-1002", "P-1003"]
    end

    test "con historial vacío el primer id sigue siendo P-1001", ctx do
      %{gestor: g} = arrancar(ctx, 1)

      assert {:ok, "P-1001", _} = GestorPartidas.crear_partida(g, "pedro", "ciencias", 5, 15)
      assert {:ok, "P-1002", _} = GestorPartidas.crear_partida(g, "ana", "ciencias", 5, 15)
    end

    test "ids con formato extraño se ignoran sin fallar y el nuevo id no colisiona", ctx do
      raros = ["P-abc", "X-5000", "P-12x", "P-", "1500", "p-2000", "P-1004"]
      sembrar_historial(ctx.tmp_dir, raros)

      # Registros sin id o con id no textual tampoco deben romper el arranque
      File.write!(
        Path.join(ctx.tmp_dir, "results.log"),
        ~s({"tema":"ciencias"}\n{"id":7777}\n{"id":null}\n),
        [:append]
      )

      %{gestor: g, persistencia: p} = arrancar(ctx, 1)

      assert {:ok, id, _} = GestorPartidas.crear_partida(g, "pedro", "ciencias", 5, 15)
      assert id == "P-1005"
      refute id in raros

      terminar_por_abandono(g, "pedro")
      assert Enum.count(ids_historial(p), fn registrado -> registrado == id end) == 1
    end

    test "si el historial está malformado no inventa un contador bajo ni toca el archivo", ctx do
      path = Path.join(ctx.tmp_dir, "results.log")
      malformado = ~s({"id":"P-1001"}\n{roto\n)
      File.write!(path, malformado)
      antes = System.os_time(:millisecond)

      log = capture_log(fn -> send(self(), {:arrancado, arrancar(ctx, 1)}) end)
      assert_received {:arrancado, %{gestor: g, persistencia: p}}
      assert log =~ "no se pudo leer el historial"

      # Mientras el archivo siga malformado no se crean partidas y no se toca el archivo
      assert {:error, :json_invalido} =
               GestorPartidas.crear_partida(g, "pedro", "ciencias", 5, 15)

      assert File.read!(path) == malformado

      # Un operador repara el archivo con el servidor en marcha: el id de respaldo
      # no colisiona con los ids que reaparecen en el historial
      File.write!(path, ~s({"id":"P-1001"}\n{"id":"P-1002"}\n))

      assert {:ok, "P-" <> numero = id, _} =
               GestorPartidas.crear_partida(g, "pedro", "ciencias", 5, 15)

      assert String.to_integer(numero) >= antes
      terminar_por_abandono(g, "pedro")
      assert ids_historial(p) == ["P-1001", "P-1002", id]
    end

    test "un reinicio solo del gestor no reutiliza el id de una partida aún viva", ctx do
      %{gestor: g1, pids: pids1} = arrancar(ctx, 1)
      {:ok, "P-1001", _} = GestorPartidas.crear_partida(g1, "pedro", "ciencias", 5, 15)

      # Detener solo el gestor: la partida sigue viva bajo el DynamicSupervisor
      [gestor1_pid, _pers1_pid] = pids1
      detener([gestor1_pid])
      assert length(SupervisorPartidas.listar_hijos(ctx.supervisor)) == 1

      %{gestor: g2} = arrancar(ctx, 2)
      assert {:ok, "P-1002", _} = GestorPartidas.crear_partida(g2, "ana", "ciencias", 5, 15)
    end
  end

  describe "reinicio simulado del servidor" do
    test "crear → terminar → reiniciar → crear: ids distintos y ambos resultados persistidos",
         ctx do
      %{gestor: g1, pids: pids1} = arrancar(ctx, 1)

      {:ok, id1, _} =
        GestorPartidas.crear_partida(g1, "pedro", "ciencias", 2, 10,
          cliente_pid: self(),
          pausa_ms: 20,
          limpieza_ms: 50
        )

      # Primera partida jugada completa hasta :fin_partida
      {:ok, "bot_1"} = GestorPartidas.agregar_bot(g1, "pedro", :facil)
      {:ok, "bot_2"} = GestorPartidas.agregar_bot(g1, "pedro", :dificil)
      {:ok, pid} = GestorPartidas.obtener_pid_partida(g1, "pedro")
      ref = Process.monitor(pid)
      :ok = Partida.iniciar_partida(pid)

      for numero <- 1..2 do
        assert_receive {:nueva_pregunta, %{numero: ^numero}}, 1000
        correcta = Partida.obtener_estado(pid).pregunta_actual_data["respuesta"]
        :ok = Partida.responder(pid, "pedro", correcta)
        :ok = Partida.responder(pid, "bot_1", correcta)
        :ok = Partida.responder(pid, "bot_2", correcta)
        assert_receive {:fin_ronda, %{numero: ^numero}}, 500
      end

      assert_receive {:fin_partida, %{partida_id: ^id1}}, 1000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000

      # "Reinicio" del servidor: se detienen y vuelven a arrancar Persistencia y gestor
      detener(pids1)
      %{gestor: g2, persistencia: p2} = arrancar(ctx, 2)

      {:ok, id2, _} = GestorPartidas.crear_partida(g2, "pedro", "ciencias", 5, 15)
      terminar_por_abandono(g2, "pedro")

      assert id1 == "P-1001"
      assert id2 == "P-1002"
      assert ids_historial(p2) == [id1, id2]
      assert length(lineas_resultados(ctx.tmp_dir)) == 2
    end
  end

  describe "registrar_resultado_unico/2 ya no descarta en silencio" do
    test "registra un error si un resultado distinto llega con un id existente", ctx do
      %{persistencia: p} = arrancar(ctx, 1)
      original = %{"id" => "P-1001", "ganador" => "ana", "puntajes" => %{"ana" => 10}}
      :ok = Persistencia.registrar_resultado_unico(original, p)

      # Reintento idéntico: idempotente y sin ruido en el log
      assert capture_log(fn ->
               assert {:ok, :ya_registrado} = Persistencia.registrar_resultado_unico(original, p)
             end) == ""

      # Resultado distinto con el mismo id: se descarta, pero queda registrado el error
      distinto = %{id: "P-1001", ganador: "pedro", puntajes: %{"pedro" => 40}}

      log =
        capture_log(fn ->
          assert {:ok, :ya_registrado} = Persistencia.registrar_resultado_unico(distinto, p)
        end)

      assert log =~ "resultado descartado"
      assert log =~ "P-1001"
      assert length(lineas_resultados(ctx.tmp_dir)) == 1
    end
  end
end
