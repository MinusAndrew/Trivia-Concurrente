defmodule Trivia.ServidorConcurrenciaTest do
  use ExUnit.Case, async: true

  alias Trivia.GestorJugadores
  alias Trivia.GestorPartidas
  alias Trivia.Persistencia
  alias Trivia.Servidor
  alias Trivia.SupervisorPartidas

  @moduletag :servidor

  setup do
    unique_id = :erlang.unique_integer([:positive])
    tmp_dir = Path.join(System.tmp_dir!(), "trivia_srv_test_#{unique_id}")
    File.mkdir_p!(tmp_dir)
    File.cp!(Path.expand("data/questions.json"), Path.join(tmp_dir, "questions.json"))

    pers = :"persistencia_srv_#{unique_id}"
    sup = :"supervisor_srv_#{unique_id}"
    gp = :"gestor_partidas_srv_#{unique_id}"
    gj = :"gestor_jugadores_srv_#{unique_id}"
    srv = :"servidor_srv_#{unique_id}"

    {:ok, pers_pid} = Persistencia.iniciar_link(data_dir: tmp_dir, name: pers)
    {:ok, sup_pid} = SupervisorPartidas.start_link(name: sup)
    {:ok, gp_pid} = GestorPartidas.start_link(name: gp, supervisor: sup, persistencia: pers)
    {:ok, gj_pid} = GestorJugadores.start_link(name: gj, persistencia: pers)
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

    %{servidor: srv, gestor_partidas_pid: gp_pid}
  end

  # Un cliente es un proceso propio: el servidor lo identifica por su PID.
  # Se conecta y luego ejecuta cada petición que reciba, reportando la respuesta.
  defp cliente(servidor, usuario) do
    test_pid = self()

    pid =
      spawn_link(fn ->
        receptor = spawn_link(fn -> Process.sleep(:infinity) end)
        conexion = GenServer.call(servidor, {:peticion, {:connect, usuario, "clave", receptor}})
        send(test_pid, {:conectado, self(), conexion})
        atender_pedidos(servidor, test_pid)
      end)

    assert_receive {:conectado, ^pid, {:ok, {:conectado, ^usuario, _}}}, 1000
    pid
  end

  defp atender_pedidos(servidor, test_pid) do
    receive do
      {:pedir, peticion} ->
        send(test_pid, {:respuesta, self(), GenServer.call(servidor, {:peticion, peticion})})
        atender_pedidos(servidor, test_pid)
    end
  end

  defp pedir(cliente, peticion), do: send(cliente, {:pedir, peticion})

  test "una petición bloqueada en un gestor no demora la petición de otro cliente", %{
    servidor: srv,
    gestor_partidas_pid: gp
  } do
    ana = cliente(srv, "ana")
    beto = cliente(srv, "beto")

    # GestorPartidas detenido: el create_game de ana queda esperando
    :ok = :sys.suspend(gp)
    pedir(ana, {:create_game, "ciencias", 5, 15})

    # El score de beto no pasa por GestorPartidas y responde de inmediato
    pedir(beto, :score)
    assert_receive {:respuesta, ^beto, {:ok, {:score, %{usuario: "beto"}}}}, 500
    refute_received {:respuesta, ^ana, _}

    # Al reanudar el gestor, ana recibe su respuesta
    :ok = :sys.resume(gp)
    assert_receive {:respuesta, ^ana, {:ok, {:partida_creada, "P-1001", :basico}}}, 1000
  end

  test "cada cliente sigue actuando solo sobre su propia sesión", %{servidor: srv} do
    ana = cliente(srv, "ana")
    beto = cliente(srv, "beto")

    pedir(ana, :score)
    pedir(beto, :score)
    assert_receive {:respuesta, ^ana, {:ok, {:score, %{usuario: "ana"}}}}, 1000
    assert_receive {:respuesta, ^beto, {:ok, {:score, %{usuario: "beto"}}}}, 1000

    # Un proceso sin sesión no puede ejecutar comandos aunque otros estén conectados
    assert {:error, :sesion_no_iniciada} = GenServer.call(srv, {:peticion, :score})
  end

  test "la sesión sigue abierta después de que termina la tarea que atendió el connect", %{
    servidor: srv
  } do
    ana = cliente(srv, "ana")

    # Varias peticiones más tarde (cada una en otra tarea) la sesión sigue vigente
    for _ <- 1..3 do
      pedir(ana, :score)
      assert_receive {:respuesta, ^ana, {:ok, {:score, %{usuario: "ana"}}}}, 1000
    end
  end

  test "las peticiones inválidas se siguen rechazando", %{servidor: srv} do
    assert {:error, :comando_invalido} = GenServer.call(srv, {:peticion, {:inventado, 1}})
    assert {:error, :comando_invalido} = GenServer.call(srv, :otra_cosa)
  end
end
