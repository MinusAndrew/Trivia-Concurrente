defmodule Trivia.Puntaje do
  @moduledoc """
  Módulo puro para el cálculo de puntajes, bonificaciones por rapidez,
  validación de respuestas y determinación del ranking de una partida.

  No realiza acceso a procesos ni al sistema de archivos.
  """

  alias Trivia.Nivel

  @opciones_validas ["A", "B", "C", "D"]

  @doc """
  Retorna los puntos base otorgados según el nivel de la pregunta y el resultado.

    * `:basico`: correcta +10, incorrecta -5, sin responder 0.
    * `:intermedio`: correcta +15, incorrecta -8, sin responder 0.
    * `:avanzado`: correcta +20, incorrecta -10, sin responder 0.
  """
  @spec puntos_base(term(), term()) :: integer()
  def puntos_base(nivel, resultado) do
    case {Nivel.normalizar(nivel), resultado} do
      {:basico, :correcta} -> 10
      {:basico, :incorrecta} -> -5
      {:basico, :sin_responder} -> 0
      {:intermedio, :correcta} -> 15
      {:intermedio, :incorrecta} -> -8
      {:intermedio, :sin_responder} -> 0
      {:avanzado, :correcta} -> 20
      {:avanzado, :incorrecta} -> -10
      {:avanzado, :sin_responder} -> 0
    end
  end

  @doc """
  Calcula la bonificación por rapidez para una respuesta correcta:

      bonificacion = trunc(5 * segundos_restantes / tiempo_pregunta)

  La bonificación va de 0 a 5 puntos. Si `segundos_restantes <= 0`, devuelve 0.
  """
  @spec bonificacion_rapidez(number(), number()) :: non_neg_integer()
  def bonificacion_rapidez(segundos_restantes, tiempo_pregunta)
      when is_number(segundos_restantes) and is_number(tiempo_pregunta) and tiempo_pregunta > 0 do
    if segundos_restantes <= 0 do
      0
    else
      calc = trunc(5 * segundos_restantes / tiempo_pregunta)
      min(5, max(0, calc))
    end
  end

  def bonificacion_rapidez(_segundos_restantes, _tiempo_pregunta), do: 0

  @doc """
  Calcula los puntos totales obtenidos por un jugador en una ronda.

  Solo las respuestas correctas reciben bonificación por rapidez.
  Las respuestas incorrectas no reciben bonificación y restan puntos base.
  Las preguntas sin responder otorgan 0 puntos.
  """
  @spec calcular_puntos_ronda(
          atom() | String.t(),
          :correcta | :incorrecta | :sin_responder,
          number(),
          number()
        ) :: integer()
  def calcular_puntos_ronda(nivel, resultado, segundos_restantes \\ 0, tiempo_pregunta \\ 1) do
    case resultado do
      :correcta ->
        base = puntos_base(nivel, :correcta)
        bonif = bonificacion_rapidez(segundos_restantes, tiempo_pregunta)
        base + bonif

      :incorrecta ->
        puntos_base(nivel, :incorrecta)

      :sin_responder ->
        0
    end
  end

  @doc """
  Valida si un término representa una respuesta válida ('A', 'B', 'C' o 'D',
  independientemente de si es mayúscula, minúscula o átomo).
  """
  @spec respuesta_valida?(any()) :: boolean()
  def respuesta_valida?(r) when is_binary(r) do
    String.upcase(r) in @opciones_validas
  end

  def respuesta_valida?(r) when is_atom(r) and not is_nil(r) do
    respuesta_valida?(Atom.to_string(r))
  end

  def respuesta_valida?(_), do: false

  @doc """
  Normaliza una respuesta a string en mayúscula ("A", "B", "C" o "D").
  Lanza `ArgumentError` si la respuesta no es válida.
  """
  @spec normalizar_respuesta(any()) :: String.t()
  def normalizar_respuesta(r) do
    if respuesta_valida?(r) do
      r |> to_string() |> String.upcase()
    else
      raise ArgumentError, "Respuesta inválida: #{inspect(r)}. Debe ser A, B, C o D"
    end
  end

  @doc """
  Calcula el ranking final a partir del mapa de puntajes de la partida.

  Ordena por puntaje descendente y en caso de empate por nombre alfabéticamente.
  Preserva puestos compartidos en caso de empate.
  """
  @spec calcular_ranking(%{optional(String.t()) => integer()}) :: [map()]
  def calcular_ranking(puntajes) when is_map(puntajes) do
    sorted =
      puntajes
      |> Enum.sort_by(fn {jugador, pts} -> {-pts, to_string(jugador)} end)

    {ranking, _pos} =
      Enum.reduce(sorted, {[], 1}, fn {jugador, pts}, {acc, pos} ->
        puesto =
          case acc do
            [%{puntaje: ^pts, puesto: p} | _] -> p
            _ -> pos
          end

        entry = %{puesto: puesto, jugador: to_string(jugador), puntaje: pts}
        {[entry | acc], pos + 1}
      end)

    Enum.reverse(ranking)
  end

  @doc """
  Determina el o los ganadores con base en el puntaje más alto.
  Si hay empate, devuelve los nombres ordenados y separados por coma.
  """
  @spec determinar_ganador(%{optional(String.t()) => integer()}) :: String.t()
  def determinar_ganador(puntajes) when is_map(puntajes) do
    if map_size(puntajes) == 0 do
      "nadie"
    else
      max_pts = puntajes |> Map.values() |> Enum.max()

      ganadores =
        puntajes
        |> Enum.filter(fn {_jugador, pts} -> pts == max_pts end)
        |> Enum.map(fn {jugador, _pts} -> to_string(jugador) end)
        |> Enum.sort()

      case ganadores do
        [unico] -> unico
        multiples -> Enum.join(multiples, ", ")
      end
    end
  end
end
