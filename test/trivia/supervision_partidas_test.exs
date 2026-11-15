defmodule Trivia.SupervisionPartidasTest do
  use ExUnit.Case, async: true

  alias Trivia.GestorPartidas
  alias Trivia.Persistencia
  alias Trivia.SupervisorPartidas

  @moduletag :supervision
  @moduletag :capture_log

  setup context do
    unique_id = :erlang.unique_integer([:positive])
    sup_name = :"supervisor_sup_#{unique_id}"
    gestor_name = :"gestor_sup_#{unique_id}"
    pers_name = :"persistencia_sup_#{unique_id}"

    tmp_dir = Path.join(System.tmp_dir!(), "trivia_sup_test_#{unique_id}")
    File.mkdir_p!(tmp_dir)

    # Copiar preguntas semilla
    seed_path = Path.expand("data/questions.json")
    File.cp!(seed_path, Path.join(tmp_dir, "questions.json"))

    {:ok, pers_pid} = Persistencia.iniciar_link(data_dir: tmp_dir, name: pers_name)
    {:ok, sup_pid} = SupervisorPartidas.start_link(name: sup_name)

    {:ok, gestor_pid} =
      GestorPartidas.start_link(
        name: gestor_name,
        supervisor: sup_name,
        persistencia: pers_name,
        espera_reinicio_ms: Map.get(context, :espera_reinicio_ms, 50)
      )

    Process.unlink(sup_pid)
    Process.unlink(gestor_pid)
    Process.unlink(pers_pid)

    on_exit(fn ->
      detener(gestor_pid)
      detener(Process.whereis(sup_name))
      detener(pers_pid)
      File.rm_rf!(tmp_dir)
    end)

    %{gestor: gestor_name, supervisor: sup_name, sup_pid: sup_pid, gestor_pid: gestor_pid}
  end

  defp detener(nil), do: :ok

  defp detener(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 1000)
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp crear(gestor, creador) do
    {:ok, id, _} =
      GestorPartidas.crear_partida(gestor, creador, "ciencias", 5, 15, cliente_pid: self())

    {:ok, pid} = GestorPartidas.obtener_pid_partida(gestor, id)
    {id, pid}
  end

  # Mata al DynamicSupervisor (sus partidas mueren con él) y espera a que caigan.
  defp matar_supervisor(sup_pid, pids_partidas) do
    refs = Enum.map(pids_partidas, fn pid -> Process.monitor(pid) end)
    Process.exit(sup_pid, :kill)

    Enum.each(refs, fn ref ->
      assert_receive {:DOWN, ^ref, :process, _, _}, 1000
    end)
  end

  # Simula el reinicio del supervisor por parte del árbol raíz.
  defp reiniciar_supervisor(sup_name) do
    {:ok, nuevo_sup} = SupervisorPartidas.start_link(name: sup_name)
    Process.unlink(nuevo_sup)
    nuevo_sup
  end

  # Reintenta `fun` (hasta ~1 s) mientras retorne nil: el DOWN llega al gestor de
  # forma asíncrona respecto al que recibe el test.
  defp eventualmente(fun, intentos \\ 100) do
    case fun.() do
      nil when intentos > 0 ->
        receive do
        after
          10 -> eventualmente(fun, intentos - 1)
        end

      resultado ->
        resultado
    end
  end

  describe "presupuesto de reinicios del DynamicSupervisor" do
    test "5 partidas que fallan en menos de 1 s no tumban a las partidas sanas", %{
      gestor: g,
      sup_pid: sup_pid
    } do
      {_id_sana, pid_sana} = crear(g, "sana")
      victimas = for i <- 1..5, do: crear(g, "victima_#{i}")

      Enum.each(victimas, fn {_id, pid} -> Process.exit(pid, :kill) end)

      # Cada víctima se reinicia y el gestor notifica a su creador con el nuevo PID
      Enum.each(victimas, fn {id, pid_viejo} ->
        assert_receive {:partida_reiniciada, ^id, _mensaje}, 1000
        assert {:ok, pid_nuevo} = GestorPartidas.obtener_pid_partida(g, id)
        refute pid_nuevo == pid_viejo
      end)

      assert Process.alive?(sup_pid)
      assert Process.alive?(pid_sana)
      assert {:ok, ^pid_sana} = GestorPartidas.obtener_pid_partida(g, "sana")
      assert length(SupervisorPartidas.listar_hijos(sup_pid)) == 6
    end
  end

  describe "partidas que no pueden reiniciarse" do
    # Espera larga: la entrada obsoleta sigue presente cuando llega el leave_game
    @tag espera_reinicio_ms: 60_000
    test "leave_game con la partida muerta no tumba al gestor y retorna un error controlado",
         %{gestor: g, supervisor: sup, sup_pid: sup_pid, gestor_pid: gestor_pid} do
      {_id, pid} = crear(g, "pedro")

      matar_supervisor(sup_pid, [pid])

      assert {:error, :partida_no_encontrada} = GestorPartidas.abandonar_partida(g, "pedro")
      assert Process.alive?(gestor_pid)
      assert {:error, :partida_no_encontrada} = GestorPartidas.obtener_partida(g, "pedro")

      # Con el supervisor restablecido, el jugador puede crear una partida nueva
      reiniciar_supervisor(sup)
      assert {:ok, _nuevo_id, _} = GestorPartidas.crear_partida(g, "pedro", "ciencias", 5, 15)
    end

    test "una partida caída que no se reinicia se descarta y el creador recibe aviso", %{
      gestor: g,
      supervisor: sup,
      sup_pid: sup_pid
    } do
      {id, pid} = crear(g, "pedro")
      matar_supervisor(sup_pid, [pid])

      assert_receive {:notificacion, mensaje}, 1000
      assert mensaje =~ id
      assert mensaje =~ "no pudo reiniciarse"
      assert {:error, :partida_no_encontrada} = GestorPartidas.obtener_partida(g, "pedro")

      reiniciar_supervisor(sup)
      assert {:ok, _nuevo_id, _} = GestorPartidas.crear_partida(g, "pedro", "ciencias", 5, 15)
    end

    test "una partida terminada con {:shutdown, motivo} libera al creador", %{gestor: g} do
      {_id, pid} = crear(g, "pedro")
      ref = Process.monitor(pid)
      GenServer.stop(pid, {:shutdown, :prueba})
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :prueba}}

      assert {:ok, _, _} =
               eventualmente(fn ->
                 case GestorPartidas.crear_partida(g, "pedro", "ciencias", 5, 15) do
                   {:ok, _, _} = ok -> ok
                   {:error, :jugador_en_partida} -> nil
                 end
               end)
    end
  end
end
