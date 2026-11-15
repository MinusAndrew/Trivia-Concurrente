defmodule Trivia.NivelTest do
  use ExUnit.Case, async: true

  @moduletag :nivel

  # ── calcular/1 ──────────────────────────────────────────────────────

  describe "calcular/1 (umbrales de nivel)" do
    test "puntajes negativos devuelven :basico" do
      assert Trivia.Nivel.calcular(-100) == :basico
      assert Trivia.Nivel.calcular(-1) == :basico
    end

    test "puntaje cero devuelve :basico" do
      assert Trivia.Nivel.calcular(0) == :basico
    end

    test "umbral 59 (límite superior de básico) devuelve :basico" do
      assert Trivia.Nivel.calcular(59) == :basico
    end

    test "umbral 60 (límite inferior de intermedio) devuelve :intermedio" do
      assert Trivia.Nivel.calcular(60) == :intermedio
    end

    test "puntaje intermedio devuelve :intermedio" do
      assert Trivia.Nivel.calcular(120) == :intermedio
    end

    test "umbral 179 (límite superior de intermedio) devuelve :intermedio" do
      assert Trivia.Nivel.calcular(179) == :intermedio
    end

    test "umbral 180 (límite inferior de avanzado) devuelve :avanzado" do
      assert Trivia.Nivel.calcular(180) == :avanzado
    end

    test "puntaje alto devuelve :avanzado" do
      assert Trivia.Nivel.calcular(500) == :avanzado
    end
  end

  # ── reparto/2 ───────────────────────────────────────────────────────

  describe "reparto/2 (distribución por porcentajes)" do
    test "nivel :basico con 10 preguntas: 7 básicas, 3 intermedias, 0 avanzadas" do
      result = Trivia.Nivel.reparto(:basico, 10)
      assert result == %{basico: 7, intermedio: 3, avanzado: 0}
    end

    test "nivel :intermedio con 10 preguntas: 2 básicas, 6 intermedias, 2 avanzadas" do
      result = Trivia.Nivel.reparto(:intermedio, 10)
      assert result == %{basico: 2, intermedio: 6, avanzado: 2}
    end

    test "nivel :avanzado con 10 preguntas: 0 básicas, 3 intermedias, 7 avanzadas" do
      result = Trivia.Nivel.reparto(:avanzado, 10)
      assert result == %{basico: 0, intermedio: 3, avanzado: 7}
    end

    test "acepta nivel como string" do
      assert Trivia.Nivel.reparto("basico", 10) == %{basico: 7, intermedio: 3, avanzado: 0}
      assert Trivia.Nivel.reparto("intermedio", 10) == %{basico: 2, intermedio: 6, avanzado: 2}
      assert Trivia.Nivel.reparto("avanzado", 10) == %{basico: 0, intermedio: 3, avanzado: 7}
    end

    test "solo acepta el orden (nivel, total)" do
      assert_raise FunctionClauseError, fn -> Trivia.Nivel.reparto(10, :basico) end
    end
  end

  describe "reparto/2 (manejo de restos y preservación del total)" do
    test "nivel :basico con 5 preguntas: trunc(1.5)=1 intermedia, 4 básicas" do
      # 5 * 0.3 = 1.5 -> trunc 1 intermedia; 0 avanzadas; 5 - 1 = 4 básicas
      assert Trivia.Nivel.reparto(:basico, 5) == %{basico: 4, intermedio: 1, avanzado: 0}
    end

    test "nivel :intermedio con 7 preguntas: trunc(1.4)=1 básica, 1 avanzada, 5 intermedias" do
      # 7 * 0.2 = 1.4 -> trunc 1 basica, 1 avanzada; 7 - 2 = 5 intermedias
      assert Trivia.Nivel.reparto(:intermedio, 7) == %{basico: 1, intermedio: 5, avanzado: 1}
    end

    test "nivel :avanzado con 5 preguntas: 0 básicas, trunc(1.5)=1 intermedia, 4 avanzadas" do
      assert Trivia.Nivel.reparto(:avanzado, 5) == %{basico: 0, intermedio: 1, avanzado: 4}
    end

    test "el total siempre se preserva para distintos valores de n" do
      for nivel <- [:basico, :intermedio, :avanzado],
          total <- [1, 2, 3, 5, 7, 8, 10, 13, 20] do
        rep = Trivia.Nivel.reparto(nivel, total)
        suma = rep.basico + rep.intermedio + rep.avanzado
        assert suma == total, "Fallo en nivel #{nivel} con total #{total}: #{inspect(rep)}"
      end
    end

    test "total <= 0 devuelve ceros" do
      assert Trivia.Nivel.reparto(:basico, 0) == %{basico: 0, intermedio: 0, avanzado: 0}
      assert Trivia.Nivel.reparto(:intermedio, -3) == %{basico: 0, intermedio: 0, avanzado: 0}
    end
  end

  # ── puntaje_por_tema/3 ──────────────────────────────────────────────

  describe "puntaje_por_tema/3 (puntos acumulados desde historial)" do
    setup do
      historial = [
        %{
          "id" => "P-1",
          "tema" => "ciencia",
          "puntajes" => %{"Pedro" => 40, "bot_1" => 20, "bot_2" => -5}
        },
        %{
          "id" => "P-2",
          "tema" => "ciencia",
          "puntajes" => %{"Pedro" => 25, "Carlos" => 15}
        },
        %{
          "id" => "P-3",
          "tema" => "historia",
          "puntajes" => %{"Pedro" => 30}
        },
        %{
          "id" => "P-4",
          "tema" => "ciencia",
          "puntajes" => %{"Pedro" => -15}
        }
      ]

      %{historial: historial}
    end

    test "calcula puntaje acumulado sumando partidas del tema", %{historial: h} do
      # Pedro en ciencia: 40 + 25 + (-15) = 50
      assert Trivia.Nivel.puntaje_por_tema(h, "Pedro", "ciencia") == 50
    end

    test "ignora partidas de otros temas", %{historial: h} do
      # Pedro en historia: 30
      assert Trivia.Nivel.puntaje_por_tema(h, "Pedro", "historia") == 30
    end

    test "ignora puntajes de bots u otros jugadores", %{historial: h} do
      # Carlos en ciencia solo tiene 15
      assert Trivia.Nivel.puntaje_por_tema(h, "Carlos", "ciencia") == 15
    end

    test "retorna 0 si el jugador nunca ha jugado el tema", %{historial: h} do
      assert Trivia.Nivel.puntaje_por_tema(h, "Pedro", "matematicas") == 0
      assert Trivia.Nivel.puntaje_por_tema(h, "Desconocido", "ciencia") == 0
    end

    test "retorna 0 si el historial está vacío" do
      assert Trivia.Nivel.puntaje_por_tema([], "Pedro", "ciencia") == 0
    end

    test "admite puntajes negativos acumulados" do
      h = [
        %{"tema" => "ciencia", "puntajes" => %{"Pedro" => -10}},
        %{"tema" => "ciencia", "puntajes" => %{"Pedro" => -5}}
      ]

      assert Trivia.Nivel.puntaje_por_tema(h, "Pedro", "ciencia") == -15
    end

    test "soporta historial en formato de líneas NDJSON (strings)" do
      lineas = [
        Jason.encode!(%{"tema" => "ciencia", "puntajes" => %{"Ana" => 35}}),
        Jason.encode!(%{"tema" => "ciencia", "puntajes" => %{"Ana" => 25}})
      ]

      assert Trivia.Nivel.puntaje_por_tema(lineas, "Ana", "ciencia") == 60
    end

    test "un jugador con el nombre de un tema no intercambia usuario y tema" do
      # "historia" es a la vez un tema del historial y el nombre de un jugador
      h = [
        %{"tema" => "historia", "puntajes" => %{"ana" => 10}},
        %{"tema" => "geografia", "puntajes" => %{"historia" => 70}}
      ]

      assert Trivia.Nivel.puntaje_por_tema(h, "historia", "Geografía") == 70
      assert Trivia.Nivel.puntaje_por_tema(h, "historia", "historia") == 0
    end
  end

  # ── normalizar/1 (seguridad de átomos) ──────────────────────────────

  describe "normalizar/1 y Bot.normalizar_dificultad/1" do
    test "convierte niveles en texto o átomo a su átomo" do
      for nivel <- [:basico, :intermedio, :avanzado] do
        assert Trivia.Nivel.normalizar(nivel) == nivel
        assert Trivia.Nivel.normalizar(Atom.to_string(nivel)) == nivel
      end

      assert_raise ArgumentError, fn -> Trivia.Nivel.normalizar("experto") end
    end

    test "convierte dificultades de bot en texto o átomo a su átomo" do
      assert Trivia.Bot.normalizar_dificultad("facil") == :facil
      assert Trivia.Bot.normalizar_dificultad(:dificil) == :dificil
      assert_raise ArgumentError, fn -> Trivia.Bot.normalizar_dificultad("imposible") end
    end
  end

  describe "reparto/2 con niveles inválidos (seguridad de átomos)" do
    test "nivel desconocido como string lanza ArgumentError" do
      assert_raise ArgumentError, fn ->
        Trivia.Nivel.reparto("experto", 10)
      end
    end

    test "nivel desconocido como átomo lanza ArgumentError" do
      assert_raise ArgumentError, fn ->
        Trivia.Nivel.reparto(:maestro, 10)
      end
    end

    test "nil como nivel lanza ArgumentError" do
      assert_raise ArgumentError, fn ->
        Trivia.Nivel.reparto(nil, 10)
      end
    end

    test "niveles válidos como strings siguen funcionando" do
      assert Trivia.Nivel.reparto("basico", 10) == %{basico: 7, intermedio: 3, avanzado: 0}
      assert Trivia.Nivel.reparto("intermedio", 10) == %{basico: 2, intermedio: 6, avanzado: 2}
      assert Trivia.Nivel.reparto("avanzado", 10) == %{basico: 0, intermedio: 3, avanzado: 7}
    end

    test "niveles válidos como átomos siguen funcionando" do
      assert Trivia.Nivel.reparto(:basico, 10) == %{basico: 7, intermedio: 3, avanzado: 0}
      assert Trivia.Nivel.reparto(:intermedio, 10) == %{basico: 2, intermedio: 6, avanzado: 2}
      assert Trivia.Nivel.reparto(:avanzado, 10) == %{basico: 0, intermedio: 3, avanzado: 7}
    end
  end

  # ── estadisticas_jugador/2 (comando score) ──────────────────────────

  describe "estadisticas_jugador/2" do
    setup do
      historial = [
        %{"tema" => "ciencia", "puntajes" => %{"ana" => 50, "bot_1" => 20}},
        %{"tema" => "historia", "puntajes" => %{"ana" => -10, "beto" => 30}},
        %{"tema" => "ciencia", "puntajes" => %{"ana" => 30}},
        %{"tema" => "historia", "puntajes" => %{"beto" => 15}},
        %{"tema" => "geografia", "puntajes" => %{"ana" => 200}}
      ]

      %{historial: historial}
    end

    test "suma puntaje total, partidas jugadas y nivel por tema", %{historial: h} do
      assert Trivia.Nivel.estadisticas_jugador(h, "ana") == %{
               usuario: "ana",
               puntaje_total: 270,
               partidas_jugadas: 4,
               temas: [
                 %{tema: "ciencia", puntaje: 80, nivel: :intermedio},
                 %{tema: "geografia", puntaje: 200, nivel: :avanzado},
                 %{tema: "historia", puntaje: -10, nivel: :basico}
               ]
             }
    end

    test "solo cuenta las partidas en las que aparece el jugador", %{historial: h} do
      stats = Trivia.Nivel.estadisticas_jugador(h, "beto")
      assert stats.partidas_jugadas == 2
      assert stats.puntaje_total == 45
      assert stats.temas == [%{tema: "historia", puntaje: 45, nivel: :basico}]
    end

    test "un jugador sin partidas y un bot no tienen estadísticas", %{historial: h} do
      vacio = %{puntaje_total: 0, partidas_jugadas: 0, temas: []}

      assert Map.drop(Trivia.Nivel.estadisticas_jugador(h, "nadie"), [:usuario]) == vacio
      assert Map.drop(Trivia.Nivel.estadisticas_jugador(h, "bot_1"), [:usuario]) == vacio
      assert Map.drop(Trivia.Nivel.estadisticas_jugador([], "ana"), [:usuario]) == vacio
    end

    test "acepta líneas NDJSON, ignora puntajes no numéricos y agrupa registros sin tema" do
      h = [
        Jason.encode!(%{"tema" => "ciencia", "puntajes" => %{"ana" => 25}}),
        %{"tema" => "ciencia", "puntajes" => %{"ana" => "muchos"}},
        %{"puntajes" => %{"ana" => 5}},
        "linea que no es JSON"
      ]

      stats = Trivia.Nivel.estadisticas_jugador(h, "ana")
      assert stats.partidas_jugadas == 2
      assert stats.puntaje_total == 30

      assert stats.temas == [
               %{tema: "ciencia", puntaje: 25, nivel: :basico},
               %{tema: "desconocido", puntaje: 5, nivel: :basico}
             ]
    end
  end
end
