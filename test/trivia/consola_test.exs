defmodule Trivia.ConsolaTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Trivia.Cliente
  alias Trivia.GestorJugadores
  alias Trivia.GestorPartidas
  alias Trivia.Persistencia
  alias Trivia.Servidor
  alias Trivia.SupervisorPartidas

  @moduletag :consola

  setup do
    unique_id = :erlang.unique_integer([:positive])
    tmp_dir = Path.join(System.tmp_dir!(), "trivia_consola_test_#{unique_id}")
    File.mkdir_p!(tmp_dir)
    File.cp!(Path.expand("data/questions.json"), Path.join(tmp_dir, "questions.json"))

    pers = :"persistencia_consola_#{unique_id}"
    sup = :"supervisor_consola_#{unique_id}"
    gp = :"gestor_partidas_consola_#{unique_id}"
    gj = :"gestor_jugadores_consola_#{unique_id}"
    srv = :"servidor_consola_#{unique_id}"

    {:ok, pers_pid} = Persistencia.iniciar_link(data_dir: tmp_dir, name: pers)
    {:ok, sup_pid} = SupervisorPartidas.start_link(name: sup)
    {:ok, gp_pid} = GestorPartidas.start_link(name: gp, supervisor: sup, persistencia: pers)

    {:ok, gj_pid} =
      GestorJugadores.start_link(name: gj, persistencia: pers, gestor_partidas: gp)

    {:ok, srv_pid} = Servidor.start_link(name: srv, gestor_jugadores: gj, gestor_partidas: gp)

    pids = [srv_pid, gj_pid, gp_pid, sup_pid, pers_pid]
    Enum.each(pids, fn pid -> Process.unlink(pid) end)

    on_exit(fn ->
      Enum.each(pids, fn pid ->
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid, :normal, 1000)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      File.rm_rf!(tmp_dir)
    end)

    %{servidor: srv, gestor_jugadores: gj}
  end

  # Ejecuta el ciclo de consola real con `entrada` como teclado y retorna lo impreso.
  # El receptor va en modo silencioso: solo se ve la salida del propio ciclo.
  defp consola(srv, entrada) do
    capture_io(entrada, fn ->
      assert :ok = Cliente.iniciar(node(), servidor: srv, silencioso: true)
    end)
  end

  test "ayuda, errores, comandos inválidos y exit cierran la sesión", %{
    servidor: srv,
    gestor_jugadores: gj
  } do
    salida =
      consola(srv, """
      help

      score
      connect ana 1234
      add_bot facil
      comando_raro
      score
      exit
      """)

    assert salida =~ "TRIVIA CONCURRENTE — CLIENTE"
    assert salida =~ "Comandos disponibles:"
    # score antes de connect
    assert salida =~ "Debes iniciar sesión primero"
    # add_bot sin partida
    assert salida =~ "No estás en ninguna partida activa."
    assert salida =~ "Comando inválido."
    # score después de connect
    assert salida =~ "=== ana ==="
    assert salida =~ "Hasta pronto."

    # exit desconecta al jugador
    assert GestorJugadores.usuarios_conectados(gj) == []
  end

  test "start_game repetido muestra que la partida ya fue iniciada", %{servidor: srv} do
    salida =
      consola(srv, """
      connect ana 1234
      create_game tema=ciencias preguntas=3 tiempo=10
      add_bot facil
      add_bot dificil
      start_game
      start_game
      leave_game
      exit
      """)

    assert salida =~ "La partida ya fue iniciada."
    refute salida =~ "No estás en ninguna partida activa."
    assert salida =~ "Hasta pronto."
  end

  test "fin de la entrada (Ctrl-D) termina el ciclo sin error", %{servidor: srv} do
    salida = consola(srv, "help\n")

    assert salida =~ "Comandos disponibles:"
    refute salida =~ "Hasta pronto."
  end
end
