defmodule Trivia.BancoPreguntas do
  @moduledoc """
  Módulo para carga, validación, filtrado y sorteo del banco de preguntas.

  No accede directamente al sistema de archivos; todas las operaciones de carga
  se canalizan a través de `Trivia.Persistencia`.
  """

  alias Trivia.Nivel
  alias Trivia.Persistencia

  @niveles_validos ["basico", "intermedio", "avanzado", :basico, :intermedio, :avanzado]
  @opciones_validas ["A", "B", "C", "D"]

  # ── Carga y Validación ──────────────────────────────────────────────

  @doc """
  Obtiene el banco de preguntas validado en memoria a través de `Trivia.Persistencia`.

  Retorna `{:ok, preguntas}` o `{:error, reason}`.
  """
  def cargar_banco(server \\ Persistencia) do
    Persistencia.obtener_preguntas(server)
  end

  @doc """
  Alias de `cargar_banco/1` para obtener el banco de preguntas en caché.
  """
  def obtener_banco(server \\ Persistencia) do
    cargar_banco(server)
  end

  @doc """
  Valida una lista completa de preguntas.
  """
  def validar_banco(preguntas) when is_list(preguntas) do
    case Enum.reduce_while(preguntas, :ok, fn p, :ok ->
           case validar_pregunta(p) do
             :ok -> {:cont, :ok}
             {:error, motivo} -> {:halt, {:error, {motivo, p}}}
           end
         end) do
      :ok -> {:ok, preguntas}
      {:error, _} = err -> err
    end
  end

  def validar_banco(_), do: {:error, :formato_invalido}

  def validar_preguntas(preguntas), do: validar_banco(preguntas)

  @doc """
  Valida la estructura de una pregunta individual.

  Requisitos:
    * Debe ser un mapa.
    * `tema`: texto o átomo no vacío.
    * `nivel`: `"basico"`, `"intermedio"` o `"avanzado"`.
    * `enunciado`: texto no vacío.
    * `opciones`: mapa con exactamente cuatro opciones: "A", "B", "C", "D".
    * `respuesta`: debe ser una de las cuatro letras válidas.
  """
  def validar_pregunta(p) when is_map(p) do
    with :ok <- validar_tema(p["tema"] || p[:tema]),
         :ok <- validar_nivel(p["nivel"] || p[:nivel]),
         :ok <- validar_enunciado(p["enunciado"] || p[:enunciado]),
         :ok <- validar_opciones(p["opciones"] || p[:opciones]),
         :ok <- validar_respuesta(p["respuesta"] || p[:respuesta]) do
      :ok
    end
  end

  def validar_pregunta(_), do: {:error, :no_es_mapa}

  defp validar_tema(tema) when is_binary(tema) and byte_size(tema) > 0, do: :ok
  defp validar_tema(tema) when is_atom(tema) and not is_nil(tema), do: :ok
  defp validar_tema(_), do: {:error, :tema_invalido}

  defp validar_nivel(nivel) when nivel in @niveles_validos, do: :ok
  defp validar_nivel(_), do: {:error, :nivel_invalido}

  defp validar_enunciado(e) when is_binary(e) and byte_size(e) > 0, do: :ok
  defp validar_enunciado(_), do: {:error, :enunciado_invalido}

  defp validar_opciones(opciones) when is_map(opciones) do
    keys =
      opciones
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.sort()

    if keys == @opciones_validas and
         Enum.all?(Map.values(opciones), fn v -> is_binary(v) and byte_size(v) > 0 end) do
      :ok
    else
      {:error, :opciones_invalidas}
    end
  end

  defp validar_opciones(_), do: {:error, :opciones_invalidas}

  defp validar_respuesta(r) when is_binary(r) do
    upper = String.upcase(r)

    if upper in @opciones_validas do
      :ok
    else
      {:error, :respuesta_invalida}
    end
  end

  defp validar_respuesta(r) when is_atom(r) and not is_nil(r) do
    validar_respuesta(Atom.to_string(r))
  end

  defp validar_respuesta(_), do: {:error, :respuesta_invalida}

  # ── Filtrado ────────────────────────────────────────────────────────

  @doc """
  Filtra preguntas por tema.
  """
  def filtrar_por_tema(preguntas, tema) when is_list(preguntas) do
    tema_str = String.downcase(to_string(tema))
    tema_stem = String.trim_trailing(tema_str, "s")

    Enum.filter(preguntas, fn p ->
      t = p["tema"] || p[:tema]

      if t != nil do
        t_str = String.downcase(to_string(t))
        t_str == tema_str or String.trim_trailing(t_str, "s") == tema_stem
      else
        false
      end
    end)
  end

  @doc """
  Filtra preguntas por nivel.
  """
  def filtrar_por_nivel(preguntas, nivel) when is_list(preguntas) do
    nivel_str = String.downcase(to_string(nivel))

    Enum.filter(preguntas, fn p ->
      n = p["nivel"] || p[:nivel]
      n != nil and String.downcase(to_string(n)) == nivel_str
    end)
  end

  @doc """
  Filtra preguntas por tema y dificultad.
  """
  def filtrar(preguntas, tema, nivel) when is_list(preguntas) and not is_list(tema) do
    preguntas
    |> filtrar_por_tema(tema)
    |> filtrar_por_nivel(nivel)
  end

  def filtrar(preguntas, opts) when is_list(preguntas) and is_list(opts) do
    tema = Keyword.get(opts, :tema)
    nivel = Keyword.get(opts, :nivel)

    preguntas
    |> then(fn list -> if tema, do: filtrar_por_tema(list, tema), else: list end)
    |> then(fn list -> if nivel, do: filtrar_por_nivel(list, nivel), else: list end)
  end

  @doc """
  Lista los temas disponibles en una colección de preguntas.
  """
  def listar_temas(preguntas) when is_list(preguntas) do
    preguntas
    |> Enum.map(&(&1["tema"] || &1[:tema]))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
  end

  # ── Sorteo y Selección ──────────────────────────────────────────────

  @doc """
  Sortea preguntas a partir de un banco en memoria o cargándolas desde Persistencia.

  Parámetros:
    * `banco_o_tema`: lista de preguntas o tema si se invoca la versión de 3 argumentos.
    * `tema`: tema de las preguntas solicitadas.
    * `nivel_jugador`: `:basico`, `:intermedio` o `:avanzado`.
    * `total_preguntas`: cantidad de preguntas requeridas.

  Garantías:
    * Se respeta el reparto proporcional según el nivel del jugador.
    * No hay preguntas duplicadas en la selección.
    * Dentro de cada nivel, las preguntas se ordenan aleatoriamente.
    * El orden global va de menor a mayor dificultad (`basico` -> `intermedio` -> `avanzado`).
    * Retorna `{:error, :tema_inexistente}` si el tema no existe.
    * Retorna `{:error, :preguntas_insuficientes}` si no hay suficientes preguntas en algún nivel.
  """
  def sortear_preguntas(tema, nivel_jugador, total_preguntas)
      when is_binary(tema) or is_atom(tema) do
    case cargar_banco() do
      {:ok, preguntas} ->
        sortear_preguntas(preguntas, tema, nivel_jugador, total_preguntas)

      {:error, _} = err ->
        err
    end
  end

  def sortear_preguntas(preguntas, tema, nivel_jugador, total_preguntas)
      when is_list(preguntas) and is_integer(total_preguntas) do
    with :ok <- validar_nivel_jugador(nivel_jugador),
         {:ok, preguntas_tema} <- obtener_preguntas_tema(preguntas, tema) do
      reparto = Nivel.reparto(nivel_jugador, total_preguntas)

      case seleccionar_por_reparto(preguntas_tema, reparto) do
        {:ok, seleccion} -> {:ok, seleccion}
        {:error, _} = err -> err
      end
    end
  end

  def sortear_preguntas(server, tema, nivel_jugador, total_preguntas)
      when (is_atom(server) or is_pid(server)) and is_integer(total_preguntas) do
    case cargar_banco(server) do
      {:ok, preguntas} ->
        sortear_preguntas(preguntas, tema, nivel_jugador, total_preguntas)

      {:error, _} = err ->
        err
    end
  end

  # Aliases
  def sortear(p, t, n, tot), do: sortear_preguntas(p, t, n, tot)
  def sortear(t, n, tot), do: sortear_preguntas(t, n, tot)
  def seleccionar(p, t, n, tot), do: sortear_preguntas(p, t, n, tot)
  def seleccionar(t, n, tot), do: sortear_preguntas(t, n, tot)
  def seleccionar_preguntas(p, t, n, tot), do: sortear_preguntas(p, t, n, tot)
  def seleccionar_preguntas(t, n, tot), do: sortear_preguntas(t, n, tot)

  defp validar_nivel_jugador(nivel)
       when nivel in [:basico, :intermedio, :avanzado, "basico", "intermedio", "avanzado"],
       do: :ok

  defp validar_nivel_jugador(_), do: {:error, :nivel_invalido}

  defp obtener_preguntas_tema(preguntas, tema) do
    filtradas = filtrar_por_tema(preguntas, tema)

    if filtradas == [] do
      {:error, :tema_inexistente}
    else
      {:ok, filtradas}
    end
  end

  defp seleccionar_por_reparto(preguntas_tema, reparto) do
    niveles_ordenados = [:basico, :intermedio, :avanzado]

    resultado =
      Enum.reduce_while(niveles_ordenados, {:ok, []}, fn nivel, {:ok, acumuladas} ->
        requeridas = Map.get(reparto, nivel, 0)
        candidatas = filtrar_por_nivel(preguntas_tema, nivel)

        if length(candidatas) < requeridas do
          {:halt, {:error, :preguntas_insuficientes}}
        else
          seleccion_nivel = Enum.take_random(candidatas, requeridas)
          {:cont, {:ok, acumuladas ++ seleccion_nivel}}
        end
      end)

    resultado
  end

  # ── Seguridad y Exposición ──────────────────────────────────────────

  @doc """
  Elimina la clave `"respuesta"` (y `:respuesta`) de una pregunta
  para que no sea expuesta a los clientes en la red.
  """
  def ocultar_respuesta(pregunta) when is_map(pregunta) do
    Map.drop(pregunta, ["respuesta", :respuesta])
  end

  @doc """
  Elimina la clave `"respuesta"` de una lista de preguntas.
  """
  def ocultar_respuestas(preguntas) when is_list(preguntas) do
    Enum.map(preguntas, &ocultar_respuesta/1)
  end

  @doc """
  Prepara una pregunta o lista de preguntas para ser enviada al cliente,
  asegurando que la respuesta correcta permanezca solo en el servidor.
  """
  def para_cliente(pregunta_o_preguntas) when is_list(pregunta_o_preguntas) do
    ocultar_respuestas(pregunta_o_preguntas)
  end

  def para_cliente(pregunta_o_preguntas) when is_map(pregunta_o_preguntas) do
    ocultar_respuesta(pregunta_o_preguntas)
  end
end
