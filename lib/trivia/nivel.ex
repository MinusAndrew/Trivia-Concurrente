defmodule Trivia.Nivel do
  @moduledoc """
  Módulo puro para cálculo del nivel de un jugador, distribución de preguntas
  por dificultad y cálculo acumulado de puntaje por tema a partir del historial.

  No realiza acceso a procesos ni al sistema de archivos.
  """

  alias Trivia.Tema

  @doc """
  Calcula el nivel de un jugador a partir de su puntaje acumulado en un tema.

    * puntaje < 60  → `:basico`
    * 60 ≤ puntaje < 180 → `:intermedio`
    * puntaje ≥ 180 → `:avanzado`

  Los puntajes negativos devuelven `:basico`.
  """
  @spec calcular(number()) :: :basico | :intermedio | :avanzado
  def calcular(puntaje) when is_number(puntaje) do
    cond do
      puntaje < 60 -> :basico
      puntaje < 180 -> :intermedio
      true -> :avanzado
    end
  end

  @doc """
  Distribuye `total` preguntas según el nivel del jugador:

    * `:basico`: 70% basico, 30% intermedio, 0% avanzado.
    * `:intermedio`: 20% basico, 60% intermedio, 20% avanzado.
    * `:avanzado`: 0% basico, 30% intermedio, 70% avanzado.

  Para los dos niveles distintos al del jugador, la cantidad de preguntas se
  calcula mediante truncamiento (`trunc(total * porcentaje / 100)`). El resto
  se asigna al nivel propio del jugador, garantizando que la suma sea siempre
  igual a `total`.
  """
  @spec reparto(atom() | String.t(), integer()) :: %{
          basico: non_neg_integer(),
          intermedio: non_neg_integer(),
          avanzado: non_neg_integer()
        }
  def reparto(nivel, total)
      when is_integer(total) and total <= 0 and (is_atom(nivel) or is_binary(nivel)) do
    %{basico: 0, intermedio: 0, avanzado: 0}
  end

  def reparto(total, nivel)
      when is_integer(total) and total <= 0 and (is_atom(nivel) or is_binary(nivel)) do
    %{basico: 0, intermedio: 0, avanzado: 0}
  end

  def reparto(nivel, total)
      when is_integer(total) and (is_atom(nivel) or is_binary(nivel)) do
    do_reparto(normalize_nivel(nivel), total)
  end

  def reparto(total, nivel)
      when is_integer(total) and (is_atom(nivel) or is_binary(nivel)) do
    do_reparto(normalize_nivel(nivel), total)
  end

  defp do_reparto(:basico, total) do
    intermedio = trunc(total * 0.3)
    avanzado = trunc(total * 0.0)
    basico = total - (intermedio + avanzado)
    %{basico: basico, intermedio: intermedio, avanzado: avanzado}
  end

  defp do_reparto(:intermedio, total) do
    basico = trunc(total * 0.2)
    avanzado = trunc(total * 0.2)
    intermedio = total - (basico + avanzado)
    %{basico: basico, intermedio: intermedio, avanzado: avanzado}
  end

  defp do_reparto(:avanzado, total) do
    basico = trunc(total * 0.0)
    intermedio = trunc(total * 0.3)
    avanzado = total - (basico + intermedio)
    %{basico: basico, intermedio: intermedio, avanzado: avanzado}
  end

  @doc """
  Calcula los puntos acumulados por un usuario en un tema específico
  a partir del historial de partidas.

  Soporta tanto registros en memoria (mapas) como líneas en formato NDJSON.
  Los puntajes históricos pueden ser negativos. Si el usuario nunca ha jugado
  ese tema o el historial está vacío, devuelve 0.
  """
  def puntaje_por_tema(arg1, arg2, arg3) do
    {historial, val1, val2} =
      cond do
        is_list(arg1) -> {arg1, arg2, arg3}
        is_list(arg3) -> {arg3, arg1, arg2}
        is_list(arg2) -> {arg2, arg1, arg3}
        true -> {[], arg1, arg2}
      end

    {usuario, tema} = identificar_usuario_y_tema(historial, val1, val2)
    usuario_str = to_string(usuario)

    # Los bots no se cuentan en las estadísticas históricas de jugadores
    if es_bot?(usuario_str) do
      0
    else
      calcular_puntaje_acumulado(historial, usuario_str, to_string(tema))
    end
  end

  @doc """
  Verifica si un nombre de jugador corresponde a un bot (prefijo "bot_").
  """
  def es_bot?(nombre) do
    String.starts_with?(to_string(nombre), "bot_")
  end

  @doc """
  Calcula el ranking histórico acumulado a partir del historial de partidas.
  Opcionalmente filtra por un tema específico.
  Excluye automáticamente a todos los bots (prefijo "bot_").

  Cada entrada contiene `:puesto`, `:jugador`, `:puntaje` y `:partidas`
  (número de partidas del historial filtrado en las que participó el jugador).
  """
  def ranking_historico(historial, tema \\ nil) do
    records = parse_history_records(historial)

    filtrados =
      if tema do
        filtrar_por_tema(records, tema)
      else
        records
      end

    {puntajes_acumulados, partidas} =
      Enum.reduce(filtrados, {%{}, %{}}, fn r, acc ->
        puntajes = r["puntajes"] || r[:puntajes] || %{}

        Enum.reduce(puntajes, acc, fn {jugador, pts}, {pts_acc, part_acc} ->
          jugador_str = to_string(jugador)

          if es_bot?(jugador_str) do
            {pts_acc, part_acc}
          else
            pts_int = if is_number(pts), do: round(pts), else: 0

            {Map.update(pts_acc, jugador_str, pts_int, fn acumulado -> acumulado + pts_int end),
             Map.update(part_acc, jugador_str, 1, fn partidas -> partidas + 1 end)}
          end
        end)
      end)

    puntajes_acumulados
    |> Trivia.Puntaje.calcular_ranking()
    |> Enum.map(fn entrada -> Map.put(entrada, :partidas, Map.get(partidas, entrada.jugador)) end)
  end

  @doc """
  Calcula las estadísticas de un jugador a partir del historial (comando `score`):

    * `:puntaje_total` – suma de sus puntajes en todas las partidas.
    * `:partidas_jugadas` – partidas del historial en las que aparece.
    * `:temas` – lista ordenada por tema de `%{tema, puntaje, nivel}`; las variantes
      de un mismo tema (`Trivia.Tema.normalizar/1`) se suman en una sola entrada.

  Los bots no tienen estadísticas: para un nombre con prefijo `bot_` se
  devuelven valores vacíos.
  """
  def estadisticas_jugador(historial, usuario) do
    usuario_str = to_string(usuario)

    participaciones =
      if es_bot?(usuario_str) do
        []
      else
        historial
        |> parse_history_records()
        |> Enum.flat_map(fn r ->
          puntajes = r["puntajes"] || r[:puntajes]

          with true <- is_map(puntajes),
               {:ok, pts} when is_number(pts) <- find_in_map(puntajes, usuario_str) do
            [{to_string(extract_tema(r) || "desconocido"), round(pts)}]
          else
            _ -> []
          end
        end)
      end

    # Se agrupa por tema normalizado y se muestra el texto de su primera aparición
    temas =
      participaciones
      |> Enum.group_by(fn {tema, _} -> Tema.normalizar(tema) end)
      |> Enum.map(fn {_tema_norm, [{tema, _} | _] = grupo} ->
        total = Enum.reduce(grupo, 0, fn {_, pts}, acc -> acc + pts end)
        %{tema: tema, puntaje: total, nivel: calcular(total)}
      end)
      |> Enum.sort_by(fn entrada -> Tema.normalizar(entrada.tema) end)

    %{
      usuario: usuario_str,
      puntaje_total: Enum.reduce(participaciones, 0, fn {_, pts}, acc -> acc + pts end),
      partidas_jugadas: length(participaciones),
      temas: temas
    }
  end

  defp identificar_usuario_y_tema(historial, val1, val2) do
    str1 = to_string(val1)
    str2 = to_string(val2)

    records = parse_history_records(historial)

    temas =
      records
      |> Enum.map(fn record -> extract_tema(record) end)
      |> Enum.reject(fn tema -> is_nil(tema) end)
      |> Enum.map(fn tema -> to_string(tema) end)
      |> Enum.uniq()

    cond do
      str2 in temas and str1 not in temas ->
        {val1, val2}

      str1 in temas and str2 not in temas ->
        {val2, val1}

      true ->
        # Asunción por defecto: primero usuario, segundo tema
        {val1, val2}
    end
  end

  defp calcular_puntaje_acumulado(historial, usuario, tema) do
    historial
    |> parse_history_records()
    |> filtrar_por_tema(tema)
    |> Enum.reduce(0, fn r, acc ->
      acc + extract_user_points(r, usuario)
    end)
  end

  defp filtrar_por_tema(records, tema) do
    tema_norm = Tema.normalizar(tema)

    Enum.filter(records, fn r ->
      t = extract_tema(r)
      t != nil and Tema.normalizar(t) == tema_norm
    end)
  end

  defp parse_history_records(historial) do
    Enum.flat_map(historial, fn
      line when is_binary(line) ->
        case Jason.decode(line) do
          {:ok, map} when is_map(map) -> [map]
          _ -> []
        end

      map when is_map(map) ->
        [map]

      _ ->
        []
    end)
  end

  defp extract_tema(record) do
    record["tema"] || record[:tema]
  end

  defp extract_user_points(record, usuario) do
    puntajes = record["puntajes"] || record[:puntajes]

    cond do
      is_map(puntajes) ->
        case find_in_map(puntajes, usuario) do
          {:ok, pts} when is_number(pts) -> pts
          _ -> 0
        end

      is_list(puntajes) ->
        case Enum.find(puntajes, fn item ->
               u = item["jugador"] || item[:jugador] || item["usuario"] || item[:usuario]
               u != nil and to_string(u) == usuario
             end) do
          nil -> 0
          item -> item["puntaje"] || item[:puntaje] || item["puntos"] || item[:puntos] || 0
        end

      true ->
        u = record["jugador"] || record[:jugador] || record["usuario"] || record[:usuario]

        if u != nil and to_string(u) == usuario do
          record["puntaje"] || record[:puntaje] || record["puntos"] || record[:puntos] || 0
        else
          0
        end
    end
  end

  defp find_in_map(map, key_str) do
    Enum.find_value(map, :error, fn {k, v} ->
      if to_string(k) == key_str, do: {:ok, v}, else: nil
    end)
  end

  defp normalize_nivel(:basico), do: :basico
  defp normalize_nivel(:intermedio), do: :intermedio
  defp normalize_nivel(:avanzado), do: :avanzado
  defp normalize_nivel("basico"), do: :basico
  defp normalize_nivel("intermedio"), do: :intermedio
  defp normalize_nivel("avanzado"), do: :avanzado

  defp normalize_nivel(other) do
    raise ArgumentError,
          "nivel inválido: #{inspect(other)}. Debe ser :basico, :intermedio o :avanzado"
  end
end
