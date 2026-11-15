defmodule Trivia.TemaTest do
  use ExUnit.Case, async: true

  alias Trivia.BancoPreguntas
  alias Trivia.GestorPartidas
  alias Trivia.Nivel
  alias Trivia.Persistencia
  alias Trivia.SupervisorPartidas
  alias Trivia.Tema

  @moduletag :tema

  # Historial con el mismo tema escrito de tres formas: 90 puntos → :intermedio
  @historial [
    %{"id" => "P-1", "tema" => "ciencia", "puntajes" => %{"pedro" => 30, "ana" => 10}},
    %{"id" => "P-2", "tema" => "Ciencias", "puntajes" => %{"pedro" => 30, "ana" => 10}},
    %{"id" => "P-3", "tema" => "ciencias", "puntajes" => %{"pedro" => 30}},
    %{"id" => "P-4", "tema" => "historia", "puntajes" => %{"pedro" => 5}}
  ]

  describe "normalizar/1" do
    test "ignora mayúsculas, espacios, acentos y una s final" do
      assert Tema.normalizar("ciencia") == "ciencia"
      assert Tema.normalizar("Ciencias") == "ciencia"
      assert Tema.normalizar("  CIENCIAS  ") == "ciencia"
      assert Tema.normalizar("Geografía") == "geografia"
      assert Tema.normalizar("MATEMÁTICAS") == "matematica"
      assert Tema.normalizar(:historia) == "historia"
    end

    test "solo elimina una s final" do
      assert Tema.normalizar("Ciencias") == Tema.normalizar("ciencia")
      refute Tema.normalizar("cienciass") == Tema.normalizar("ciencia")
    end

    test "iguales?/2 compara por la forma normalizada" do
      assert Tema.iguales?("Geografía", "geografias")
      refute Tema.iguales?("ciencia", "historia")
    end
  end

  describe "score, ranking y nivel coinciden para variantes del mismo tema" do
    test "score agrupa ciencia/Ciencias/ciencias en una sola entrada con su nivel real" do
      stats = Nivel.estadisticas_jugador(@historial, "pedro")

      assert stats.temas == [
               %{tema: "ciencia", puntaje: 90, nivel: :intermedio},
               %{tema: "historia", puntaje: 5, nivel: :basico}
             ]

      assert stats.puntaje_total == 95
      assert stats.partidas_jugadas == 4
    end

    test "ranking por tema suma las tres variantes con cualquier forma del filtro" do
      for filtro <- ["ciencia", "Ciencias", "  CIENCIAS "] do
        assert [
                 %{puesto: 1, jugador: "pedro", puntaje: 90, partidas: 3},
                 %{puesto: 2, jugador: "ana", puntaje: 20, partidas: 2}
               ] = Nivel.ranking_historico(@historial, filtro)
      end
    end

    test "el nivel por tema coincide con el que muestra score" do
      assert Nivel.puntaje_por_tema(@historial, "pedro", "Ciencias") == 90
      assert Nivel.calcular(90) == :intermedio
    end

    test "acentos y mayúsculas también se agrupan" do
      historial = [
        %{"id" => "P-1", "tema" => "Geografía", "puntajes" => %{"pedro" => 40}},
        %{"id" => "P-2", "tema" => "geografia", "puntajes" => %{"pedro" => 40}}
      ]

      assert [%{tema: "Geografía", puntaje: 80, nivel: :intermedio}] =
               Nivel.estadisticas_jugador(historial, "pedro").temas

      assert Nivel.puntaje_por_tema(historial, "pedro", "GEOGRAFIA") == 80
    end
  end

  describe "banco de preguntas" do
    test "filtrar_por_tema encuentra el mismo tema con acentos, mayúsculas o plural" do
      preguntas = [
        %{"tema" => "geografia", "id" => 1},
        %{"tema" => "Ciencias", "id" => 2},
        %{"tema" => "historia", "id" => 3}
      ]

      for consulta <- ["Geografía", "GEOGRAFIAS", " geografia "] do
        assert [%{"id" => 1}] = BancoPreguntas.filtrar_por_tema(preguntas, consulta)
      end

      assert [%{"id" => 2}] = BancoPreguntas.filtrar_por_tema(preguntas, "ciencia")
    end

    test "listar_temas no repite variantes del mismo tema" do
      preguntas = [%{"tema" => "ciencias"}, %{"tema" => "Ciencia"}, %{"tema" => "historia"}]
      assert BancoPreguntas.listar_temas(preguntas) == ["ciencias", "historia"]
    end
  end

  describe "create_game" do
    setup do
      unique_id = :erlang.unique_integer([:positive])
      tmp_dir = Path.join(System.tmp_dir!(), "trivia_tema_test_#{unique_id}")
      File.mkdir_p!(tmp_dir)
      File.cp!(Path.expand("data/questions.json"), Path.join(tmp_dir, "questions.json"))

      File.write!(
        Path.join(tmp_dir, "results.log"),
        Enum.map_join(@historial, fn r -> Jason.encode!(r) <> "\n" end)
      )

      pers_name = :"persistencia_tema_#{unique_id}"
      sup_name = :"supervisor_tema_#{unique_id}"
      gestor_name = :"gestor_tema_#{unique_id}"

      {:ok, pers_pid} = Persistencia.iniciar_link(data_dir: tmp_dir, name: pers_name)
      {:ok, sup_pid} = SupervisorPartidas.start_link(name: sup_name)

      {:ok, gestor_pid} =
        GestorPartidas.start_link(
          name: gestor_name,
          supervisor: sup_name,
          persistencia: pers_name
        )

      Enum.each([pers_pid, sup_pid, gestor_pid], fn pid -> Process.unlink(pid) end)

      on_exit(fn ->
        Enum.each([gestor_pid, sup_pid, pers_pid], fn pid ->
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

      %{gestor: gestor_name, persistencia: pers_name}
    end

    test "create_game calcula el mismo nivel que score para cualquier variante del tema", %{
      gestor: g,
      persistencia: p
    } do
      historial = Persistencia.obtener_historial(p)
      [%{nivel: nivel_score}, _] = Nivel.estadisticas_jugador(historial, "pedro").temas

      assert {:ok, _id, ^nivel_score} =
               GestorPartidas.crear_partida(g, "pedro", "Ciencias", 5, 15)

      assert nivel_score == :intermedio

      # El tema se guarda tal como lo escribió el usuario
      assert {:ok, %{tema: "Ciencias"}} = GestorPartidas.obtener_estado_partida(g, "pedro")
    end
  end
end
