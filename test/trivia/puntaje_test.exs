defmodule Trivia.PuntajeTest do
  use ExUnit.Case, async: true

  alias Trivia.Puntaje

  @moduletag :puntaje

  # ── 1. Puntos Base por Nivel y Situación ───────────────────────────

  describe "puntos_base/2" do
    test "nivel básico: correcta +10, incorrecta -5, sin responder 0" do
      assert Puntaje.puntos_base(:basico, :correcta) == 10
      assert Puntaje.puntos_base(:basico, :incorrecta) == -5
      assert Puntaje.puntos_base(:basico, :sin_responder) == 0
    end

    test "nivel intermedio: correcta +15, incorrecta -8, sin responder 0" do
      assert Puntaje.puntos_base(:intermedio, :correcta) == 15
      assert Puntaje.puntos_base(:intermedio, :incorrecta) == -8
      assert Puntaje.puntos_base(:intermedio, :sin_responder) == 0
    end

    test "nivel avanzado: correcta +20, incorrecta -10, sin responder 0" do
      assert Puntaje.puntos_base(:avanzado, :correcta) == 20
      assert Puntaje.puntos_base(:avanzado, :incorrecta) == -10
      assert Puntaje.puntos_base(:avanzado, :sin_responder) == 0
    end

    test "acepta nivel como string" do
      assert Puntaje.puntos_base("basico", :correcta) == 10
      assert Puntaje.puntos_base("intermedio", :incorrecta) == -8
      assert Puntaje.puntos_base("avanzado", :correcta) == 20
    end

    test "lanza ArgumentError para nivel inválido" do
      assert_raise ArgumentError, fn ->
        apply(Puntaje, :puntos_base, [:experto, :correcta])
      end

      assert_raise ArgumentError, fn ->
        Puntaje.puntos_base("invalido", :correcta)
      end
    end
  end

  # ── 2. Bonificación por Rapidez ─────────────────────────────────────

  describe "bonificacion_rapidez/2 con tiempo_pregunta = 15 (tabla oficial)" do
    test "momento 1s (14s restantes) otorga bonificación de 4 puntos" do
      # trunc(5 * 14 / 15) = trunc(4.666...) = 4
      assert Puntaje.bonificacion_rapidez(14, 15) == 4
    end

    test "momento 4s (11s restantes) otorga bonificación de 3 puntos" do
      # trunc(5 * 11 / 15) = trunc(3.666...) = 3
      assert Puntaje.bonificacion_rapidez(11, 15) == 3
    end

    test "momento 9s (6s restantes) otorga bonificación de 2 puntos" do
      # trunc(5 * 6 / 15) = trunc(2.0) = 2
      assert Puntaje.bonificacion_rapidez(6, 15) == 2
    end

    test "momento 14s (1s restante) otorga bonificación de 0 puntos" do
      # trunc(5 * 1 / 15) = trunc(0.333...) = 0
      assert Puntaje.bonificacion_rapidez(1, 15) == 0
    end

    test "momento 15s (0s restantes) otorga bonificación de 0 puntos" do
      assert Puntaje.bonificacion_rapidez(0, 15) == 0
    end

    test "tiempo restante negativo o cero devuelve 0" do
      assert Puntaje.bonificacion_rapidez(-1, 15) == 0
      assert Puntaje.bonificacion_rapidez(-5.5, 15) == 0
    end

    test "bonificación máxima está acotada a 5 puntos" do
      assert Puntaje.bonificacion_rapidez(15, 15) == 5
      assert Puntaje.bonificacion_rapidez(20, 15) == 5
    end
  end

  describe "bonificacion_rapidez/2 con segundo valor de tiempo_pregunta = 20" do
    test "con tiempo_pregunta = 20 distribuye proporcionalmente" do
      # 18s restantes: trunc(5 * 18 / 20) = trunc(4.5) = 4
      assert Puntaje.bonificacion_rapidez(18, 20) == 4

      # 10s restantes: trunc(5 * 10 / 20) = trunc(2.5) = 2
      assert Puntaje.bonificacion_rapidez(10, 20) == 2

      # 2s restantes: trunc(5 * 2 / 20) = trunc(0.5) = 0
      assert Puntaje.bonificacion_rapidez(2, 20) == 0
    end

    test "con tiempo_pregunta = 30 distribuye proporcionalmente" do
      # 24s restantes: trunc(5 * 24 / 30) = trunc(4.0) = 4
      assert Puntaje.bonificacion_rapidez(24, 30) == 4

      # 15s restantes: trunc(5 * 15 / 30) = trunc(2.5) = 2
      assert Puntaje.bonificacion_rapidez(15, 30) == 2
    end
  end

  # ── 3. Cálculo Total de Ronda (Base + Bonificación) ──────────────────

  describe "calcular_puntos_ronda/4" do
    test "correcta básica suma base 10 + bonificación (10 a 15 puntos)" do
      # 1s de respuesta (14s restantes sobre 15) -> 10 + 4 = 14
      assert Puntaje.calcular_puntos_ronda(:basico, :correcta, 14, 15) == 14

      # 4s de respuesta (11s restantes sobre 15) -> 10 + 3 = 13
      assert Puntaje.calcular_puntos_ronda(:basico, :correcta, 11, 15) == 13

      # 9s de respuesta (6s restantes sobre 15) -> 10 + 2 = 12
      assert Puntaje.calcular_puntos_ronda(:basico, :correcta, 6, 15) == 12

      # 14s de respuesta (1s restante sobre 15) -> 10 + 0 = 10
      assert Puntaje.calcular_puntos_ronda(:basico, :correcta, 1, 15) == 10
    end

    test "correcta avanzada suma base 20 + bonificación (20 a 25 puntos)" do
      # 1s de respuesta -> 20 + 4 = 24
      assert Puntaje.calcular_puntos_ronda(:avanzado, :correcta, 14, 15) == 24

      # 4s de respuesta -> 20 + 3 = 23
      assert Puntaje.calcular_puntos_ronda(:avanzado, :correcta, 11, 15) == 23

      # 14s de respuesta -> 20 + 0 = 20
      assert Puntaje.calcular_puntos_ronda(:avanzado, :correcta, 1, 15) == 20
    end

    test "incorrecta NO recibe bonificación por rapidez sin importar el tiempo restante" do
      assert Puntaje.calcular_puntos_ronda(:basico, :incorrecta, 14, 15) == -5
      assert Puntaje.calcular_puntos_ronda(:intermedio, :incorrecta, 14, 15) == -8
      assert Puntaje.calcular_puntos_ronda(:avanzado, :incorrecta, 14, 15) == -10
    end

    test "sin responder siempre otorga exactamente 0 puntos" do
      assert Puntaje.calcular_puntos_ronda(:basico, :sin_responder, 0, 15) == 0
      assert Puntaje.calcular_puntos_ronda(:intermedio, :sin_responder, 0, 15) == 0
      assert Puntaje.calcular_puntos_ronda(:avanzado, :sin_responder, 0, 15) == 0
    end
  end

  # ── 4. Validación y Normalización de Respuestas ──────────────────────

  describe "validación de respuestas" do
    test "acepta letras mayúsculas válidas A, B, C, D" do
      for l <- ["A", "B", "C", "D"] do
        assert Puntaje.respuesta_valida?(l)
        assert Puntaje.normalizar_respuesta(l) == l
      end
    end

    test "acepta letras minúsculas válidas y las normaliza a mayúsculas" do
      assert Puntaje.respuesta_valida?("a")
      assert Puntaje.normalizar_respuesta("a") == "A"
      assert Puntaje.normalizar_respuesta("b") == "B"
      assert Puntaje.normalizar_respuesta("c") == "C"
      assert Puntaje.normalizar_respuesta("d") == "D"
    end

    test "acepta átomos y los normaliza" do
      assert Puntaje.respuesta_valida?(:A)
      assert Puntaje.normalizar_respuesta(:a) == "A"
      assert Puntaje.normalizar_respuesta(:b) == "B"
    end

    test "rechaza letras distintas de A, B, C, D" do
      refute Puntaje.respuesta_valida?("E")
      refute Puntaje.respuesta_valida?("X")
      refute Puntaje.respuesta_valida?("1")
      refute Puntaje.respuesta_valida?("")
    end

    test "rechaza tipos no válidos sin lanzar excepción" do
      refute Puntaje.respuesta_valida?(nil)
      refute Puntaje.respuesta_valida?(42)
      refute Puntaje.respuesta_valida?(%{})
      refute Puntaje.respuesta_valida?([:A])
    end
  end

  # ── 5. Ranking y Determinación de Ganadores ─────────────────────────

  describe "calcular_ranking/1 y determinar_ganador/1" do
    test "ordena jugadores de mayor a menor puntaje" do
      puntajes = %{"Pedro" => 48, "bot_1" => 22, "bot_2" => -11}
      ranking = Puntaje.calcular_ranking(puntajes)

      assert ranking == [
               %{puesto: 1, jugador: "Pedro", puntaje: 48},
               %{puesto: 2, jugador: "bot_1", puntaje: 22},
               %{puesto: 3, jugador: "bot_2", puntaje: -11}
             ]

      assert Puntaje.determinar_ganador(puntajes) == "Pedro"
    end

    test "maneja empates en el puntaje más alto y ranking compartido" do
      puntajes = %{"Pedro" => 35, "bot_1" => 35, "bot_2" => 10}
      ranking = Puntaje.calcular_ranking(puntajes)

      assert ranking == [
               %{puesto: 1, jugador: "Pedro", puntaje: 35},
               %{puesto: 1, jugador: "bot_1", puntaje: 35},
               %{puesto: 3, jugador: "bot_2", puntaje: 10}
             ]

      assert Puntaje.determinar_ganador(puntajes) == "Pedro, bot_1"
    end

    test "ganador puede ser un bot" do
      puntajes = %{"Pedro" => 10, "bot_1" => 25, "bot_2" => 15}
      assert Puntaje.determinar_ganador(puntajes) == "bot_1"
    end

    test "admite puntajes negativos en el ranking" do
      puntajes = %{"Pedro" => -5, "bot_1" => -10, "bot_2" => -2}
      ranking = Puntaje.calcular_ranking(puntajes)

      assert ranking == [
               %{puesto: 1, jugador: "bot_2", puntaje: -2},
               %{puesto: 2, jugador: "Pedro", puntaje: -5},
               %{puesto: 3, jugador: "bot_1", puntaje: -10}
             ]

      assert Puntaje.determinar_ganador(puntajes) == "bot_2"
    end
  end
end
