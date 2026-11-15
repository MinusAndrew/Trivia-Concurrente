defmodule Trivia.MultijugadorTest do
  use ExUnit.Case, async: true

  alias Trivia.GestorPartidas
  alias Trivia.Partida
  alias Trivia.Persistencia
  alias Trivia.SupervisorPartidas

  @moduletag :multijugador

  setup do
    unique_id = :erlang.unique_integer([:positive])
    sup_name = :"supervisor_mj_#{unique_id}"
    gestor_name = :"gestor_mj_#{unique_id}"
    pers_name = :"persistencia_mj_#{unique_id}"

    tmp_dir = Path.join(System.tmp_dir!(), "trivia_mj_test_#{unique_id}")
    File.mkdir_p!(tmp_dir)
    File.cp!(Path.expand("data/questions.json"), Path.join(tmp_dir, "questions.json"))

    {:ok, pers_pid} = Persistencia.iniciar_link(data_dir: tmp_dir, name: pers_name)
    {:ok, sup_pid} = SupervisorPartidas.start_link(name: sup_name)

    {:ok, gestor_pid} =
      GestorPartidas.start_link(name: gestor_name, supervisor: sup_name, persistencia: pers_name)

    Process.unlink(sup_pid)
    Process.unlink(gestor_pid)
    Process.unlink(pers_pid)

    on_exit(fn ->
      for pid <- [gestor_pid, sup_pid, pers_pid], Process.alive?(pid) do
        try do
          GenServer.stop(pid, :normal, 1000)
        catch
          :exit, _ -> :ok
        end
      end

      File.rm_rf!(tmp_dir)
    end)

    %{gestor: gestor_name, persistencia: pers_name}
  end

  # Receptor de un jugador unido: reenvía cada notificación al test con su nombre
  defp receptor(nombre) do
    test = self()
    spawn_link(fn -> reenviar(test, nombre) end)
  end

  defp reenviar(test, nombre) do
    receive do
      mensaje ->
        send(test, {nombre, mensaje})
        reenviar(test, nombre)
    end
  end

  # "andres" crea (sus notificaciones llegan al test sin etiqueta) y "profe" se une
  defp partida_con_profe(g, preguntas \\ 1, opts \\ []) do
    {:ok, id, _nivel} =
      GestorPartidas.crear_partida(
        g,
        "andres",
        "ciencias",
        preguntas,
        10,
        Keyword.merge([cliente_pid: self(), pausa_ms: 10], opts)
      )

    {:ok, info} = GestorPartidas.unirse_partida(g, "profe", id, cliente_pid: receptor(:profe))
    {id, info}
  end

  describe "unirse a una partida" do
    test "el jugador unido queda en la partida y el creador recibe el aviso", %{gestor: g} do
      {id, info} = partida_con_profe(g)

      assert %{id: ^id, creador: "andres", tema: "ciencias", jugadores: ["andres", "profe"]} =
               info

      assert_receive {:jugador_unido, %{partida_id: ^id, jugador: "profe"}}, 500
      assert {:ok, ^id} = GestorPartidas.obtener_partida(g, "profe")

      {:ok, estado} = GestorPartidas.obtener_estado_partida(g, id)
      assert estado.humanos == ["andres", "profe"]
      assert estado.puntajes == %{"andres" => 0, "profe" => 0}
    end

    test "rechaza partidas inexistentes, iniciadas o llenas", %{gestor: g} do
      assert {:error, :partida_inexistente} = GestorPartidas.unirse_partida(g, "profe", "P-9999")

      {:ok, id, _} = GestorPartidas.crear_partida(g, "andres", "ciencias", 1, 10)

      for dif <- [:facil, :facil, :dificil],
          do: {:ok, _} = GestorPartidas.agregar_bot(g, "andres", dif)

      assert {:error, :partida_llena} = GestorPartidas.unirse_partida(g, "profe", id)

      {:ok, id2, _} = GestorPartidas.crear_partida(g, "carla", "ciencias", 1, 10)
      for dif <- [:facil, :facil], do: {:ok, _} = GestorPartidas.agregar_bot(g, "carla", dif)
      :ok = GestorPartidas.iniciar_partida(g, "carla")
      assert {:error, :partida_ya_iniciada} = GestorPartidas.unirse_partida(g, "profe", id2)
    end

    test "un jugador no puede estar en dos partidas ni usar un nombre de bot", %{gestor: g} do
      {id, _info} = partida_con_profe(g)

      assert {:error, :jugador_en_partida} = GestorPartidas.unirse_partida(g, "profe", id)
      assert {:error, :jugador_en_partida} = GestorPartidas.unirse_partida(g, "andres", id)

      assert {:error, :jugador_en_partida} =
               GestorPartidas.crear_partida(g, "profe", "ciencias", 1, 10)

      assert {:error, :usuario_reservado} = GestorPartidas.unirse_partida(g, "bot_1", id)
    end

    test "games lista solo las partidas en espera con sus jugadores", %{gestor: g} do
      {id, _info} = partida_con_profe(g)

      {:ok, _id2, _} = GestorPartidas.crear_partida(g, "carla", "ciencias", 1, 10)
      for dif <- [:facil, :facil], do: {:ok, _} = GestorPartidas.agregar_bot(g, "carla", dif)
      :ok = GestorPartidas.iniciar_partida(g, "carla")

      assert [%{id: ^id, creador: "andres", jugadores: ["andres", "profe"]}] =
               GestorPartidas.listar_partidas_abiertas(g)
    end
  end

  describe "reglas con varios humanos" do
    test "solo el creador agrega bots e inicia la partida", %{gestor: g} do
      partida_con_profe(g)

      assert {:error, :solo_creador} = GestorPartidas.agregar_bot(g, "profe", :facil)
      assert {:error, :solo_creador} = GestorPartidas.iniciar_partida(g, "profe")
      assert {:ok, "bot_1"} = GestorPartidas.agregar_bot(g, "andres", :facil)
    end

    test "con dos humanos se puede jugar sin bots; solo sigue exigiendo dos", %{
      gestor: g,
      persistencia: p
    } do
      {id, _info} = partida_con_profe(g)
      assert :ok = GestorPartidas.iniciar_partida(g, "andres")

      assert_receive {:nueva_pregunta, %{numero: 1}}, 1000
      assert_receive {:profe, {:nueva_pregunta, %{numero: 1}}}, 1000

      # La ronda cierra en cuanto responden los dos humanos
      :ok = GestorPartidas.responder(g, "andres", "A")
      :ok = GestorPartidas.responder(g, "profe", "B")
      assert_receive {:fin_ronda, %{numero: 1, detalles_ronda: detalles}}, 1000
      assert Map.keys(detalles) |> Enum.sort() == ["andres", "profe"]

      assert_receive {:profe, {:fin_partida, %{partida_id: ^id}}}, 2000
      assert [%{"id" => ^id, "puntajes" => puntajes}] = Persistencia.obtener_historial(p)
      assert Map.keys(puntajes) |> Enum.sort() == ["andres", "profe"]

      {:ok, _solo, _} = GestorPartidas.crear_partida(g, "carla", "ciencias", 1, 10)
      assert {:error, :minimo_dos_bots} = GestorPartidas.iniciar_partida(g, "carla")
    end
  end

  describe "abandono con varios humanos" do
    test "si el unido sale en espera, la partida sigue y él queda libre", %{gestor: g} do
      {id, _info} = partida_con_profe(g)

      assert :ok = GestorPartidas.abandonar_partida(g, "profe")
      assert_receive {:jugador_salio, %{partida_id: ^id, jugador: "profe"}}, 500
      assert {:error, :partida_no_encontrada} = GestorPartidas.obtener_partida(g, "profe")

      {:ok, estado} = GestorPartidas.obtener_estado_partida(g, id)
      assert estado.jugadores == ["andres"]
      assert {:ok, _} = GestorPartidas.unirse_partida(g, "profe", id)
    end

    test "si el unido sale en curso, conserva sus puntos y deja de recibir preguntas", %{
      gestor: g,
      persistencia: p
    } do
      {id, _info} = partida_con_profe(g, 2)
      :ok = GestorPartidas.iniciar_partida(g, "andres")
      assert_receive {:profe, {:nueva_pregunta, %{numero: 1}}}, 1000

      assert :ok = GestorPartidas.abandonar_partida(g, "profe")
      assert_receive {:jugador_salio, %{jugador: "profe"}}, 500

      # Solo falta el creador: su respuesta cierra la ronda sin esperar el tiempo
      :ok = GestorPartidas.responder(g, "andres", "A")
      assert_receive {:fin_ronda, %{numero: 1}}, 1000
      assert_receive {:nueva_pregunta, %{numero: 2}}, 1000
      :ok = GestorPartidas.responder(g, "andres", "A")
      assert_receive {:fin_partida, %{partida_id: ^id}}, 2000

      refute_received {:profe, {:nueva_pregunta, %{numero: 2}}}
      assert [%{"puntajes" => %{"profe" => _}}] = Persistencia.obtener_historial(p)
    end

    test "si el creador cancela en espera, el unido recibe el aviso y queda libre", %{gestor: g} do
      {id, _info} = partida_con_profe(g)

      assert :ok = GestorPartidas.abandonar_partida(g, "andres")
      assert_receive {:profe, {:partida_cancelada, %{partida_id: ^id, creador: "andres"}}}, 500
      refute_receive {:partida_cancelada, _}, 100
      assert {:error, :partida_no_encontrada} = GestorPartidas.obtener_partida(g, "profe")
    end
  end

  test "si la partida falla y se reinicia, el unido sale y recibe aviso", %{gestor: g} do
    {id, _info} = partida_con_profe(g)
    {:ok, pid} = GestorPartidas.obtener_pid_partida(g, id)

    Process.exit(pid, :kill)

    assert_receive {:profe, {:notificacion, "La partida " <> _}}, 2000
    assert {:error, :partida_no_encontrada} = GestorPartidas.obtener_partida(g, "profe")

    {:ok, nuevo_pid} = GestorPartidas.obtener_pid_partida(g, id)
    assert Partida.obtener_estado(nuevo_pid).jugadores == ["andres"]
  end

  test "la consola entiende games y join_game" do
    assert {:ok, :list_games} = Trivia.Cliente.parsear_comando("games")
    assert {:ok, {:join_game, "P-1001"}} = Trivia.Cliente.parsear_comando("join_game P-1001")
    assert {:error, :comando_invalido} = Trivia.Cliente.parsear_comando("join_game")
  end
end
