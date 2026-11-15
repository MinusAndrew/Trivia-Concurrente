defmodule Trivia.Persistencia do
  @moduledoc """
  GenServer responsable exclusivo de la lectura y escritura de archivos de datos.

  Administra tres archivos dentro del directorio configurado (`data_dir`):

    * `users.json`     – Lista JSON de usuarios registrados: `%{"usuario" => ..., "clave" => ...}`
    * `questions.json` – Lista JSON de preguntas del banco
    * `results.log`    – Historial de partidas en formato NDJSON (una línea JSON por partida)

  ## Formato de Resultados (`results.log`)
  Cada línea de `results.log` corresponde a un objeto JSON con la estructura de una partida finalizada:

  ```json
  {
    "id": "P-1001",
    "fecha": "2026-11-08T17:00:00Z",
    "tema": "ciencia",
    "nivel": "basico",
    "ganador": "Pedro",
    "puntajes": {
      "Pedro": 48,
      "bot_1": 22,
      "bot_2": -11
    }
  }
  ```

  No se almacenan estadísticas calculadas en `users.json`. Toda estadística (puntaje acumulado,
  partidas jugadas, puntaje por tema y nivel) se calcula dinámicamente desde el historial.
  """
  use GenServer

  require Logger

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Inicia el GenServer de persistencia.

  Opciones:
    * `:data_dir` – ruta al directorio que contiene los archivos de datos (por defecto `data`).
    * `:name`     – nombre del proceso (por defecto `__MODULE__`).
  """
  def iniciar_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def start_link(opts \\ []), do: iniciar_link(opts)

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :iniciar_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc """
  Retorna la lista de usuarios registrados.
  Si `users.json` no existe, retorna una lista vacía `[]`.
  Si el archivo está corrupto o tiene formato inválido, retorna `{:error, reason}`.
  """
  def listar_usuarios(server \\ __MODULE__) do
    GenServer.call(server, :listar_usuarios)
  end

  @doc """
  Registra un nuevo usuario con su clave en `users.json`.
  Retorna `:ok` o `{:error, reason}` (por ejemplo `{:error, :usuario_existente}`).
  Si el archivo existente está corrupto, no lo sobreescribe y retorna el error.
  """
  def registrar_usuario(usuario, clave, server \\ __MODULE__) do
    GenServer.call(server, {:registrar_usuario, usuario, clave})
  end

  @doc """
  Retorna el historial completo de resultados desde `results.log`.
  Si `results.log` no existe, retorna una lista vacía `[]`.
  Si contiene líneas malformadas, retorna `{:error, reason}`.
  """
  def obtener_historial(server \\ __MODULE__) do
    GenServer.call(server, :obtener_historial)
  end

  @doc """
  Agrega el resultado de una partida a `results.log` en formato NDJSON.
  """
  def registrar_resultado(resultado, server \\ __MODULE__) do
    GenServer.call(server, {:registrar_resultado, resultado})
  end

  @doc """
  Registra atómicamente el resultado de una partida en `results.log`, asegurando
  que no se dupliquen partidas con el mismo identificador (`id`).

  Ejecuta la verificación de existencia previa y la escritura en un único callback
  atómico del GenServer.

  Retorna:
    * `:ok` si se escribió un nuevo resultado.
    * `{:ok, :ya_registrado}` si ya existía una entrada con ese `id` (operación idempotente).
    * `{:error, reason}` si la lectura o escritura falló, o si el archivo está corrupto.
  """
  def registrar_resultado_unico(resultado, server \\ __MODULE__) do
    GenServer.call(server, {:registrar_resultado_unico, resultado})
  end

  @doc """
  Retorna la lista de preguntas validadas del banco en memoria (cargado al iniciar
  desde `questions.json`).
  Retorna `{:ok, preguntas}` o `{:error, reason}`.
  """
  def cargar_preguntas(server \\ __MODULE__) do
    GenServer.call(server, :cargar_preguntas)
  end

  @doc """
  Alias de `cargar_preguntas/1` para obtener el banco de preguntas en caché.
  """
  def obtener_preguntas(server \\ __MODULE__) do
    cargar_preguntas(server)
  end

  @doc """
  Fuerza la recarga y validación de `questions.json` desde disco hacia la memoria del servidor.
  """
  def recargar_preguntas(server \\ __MODULE__) do
    GenServer.call(server, :recargar_preguntas)
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────

  @impl true
  def init(opts) do
    data_dir =
      Keyword.get(opts, :data_dir) ||
        Application.get_env(:trivia, :data_dir, Path.expand("data"))

    case File.mkdir_p(data_dir) do
      :ok ->
        questions_path = Path.join(data_dir, "questions.json")
        banco_preguntas = cargar_y_validar_banco(questions_path)

        state = %{
          data_dir: data_dir,
          users_path: Path.join(data_dir, "users.json"),
          questions_path: questions_path,
          results_path: Path.join(data_dir, "results.log"),
          banco_preguntas: banco_preguntas
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:listar_usuarios, _from, state) do
    case read_users_file(state.users_path) do
      {:ok, users} -> {:reply, users, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:registrar_usuario, usuario, clave}, _from, state) do
    user_str = to_string(usuario)

    if String.starts_with?(user_str, "bot_") do
      {:reply, {:error, :usuario_reservado}, state}
    else
      case read_users_file(state.users_path) do
        {:ok, usuarios} ->
          ya_existe =
            Enum.any?(usuarios, fn u ->
              nombre = u["usuario"] || u["nombre"]
              to_string(nombre) == user_str
            end)

          if ya_existe do
            {:reply, {:error, :usuario_existente}, state}
          else
            nuevo = %{"usuario" => user_str, "clave" => to_string(clave)}
            updated = usuarios ++ [nuevo]

            case Jason.encode(updated, pretty: true) do
              {:ok, json_data} ->
                case File.write(state.users_path, json_data) do
                  :ok -> {:reply, :ok, state}
                  {:error, reason} -> {:reply, {:error, reason}, state}
                end

              {:error, reason} ->
                {:reply, {:error, reason}, state}
            end
          end

        {:error, reason} ->
          # Jamás sobreescribir un archivo existente si está corrupto
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call(:obtener_historial, _from, state) do
    case read_results_file(state.results_path) do
      {:ok, list} -> {:reply, list, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:registrar_resultado, resultado}, _from, state) do
    case Jason.encode(resultado) do
      {:ok, json_line} ->
        case File.write(state.results_path, json_line <> "\n", [:append]) do
          :ok -> {:reply, :ok, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:registrar_resultado_unico, resultado}, _from, state) do
    match_id =
      case resultado["id"] || resultado[:id] do
        nil -> nil
        id -> to_string(id)
      end

    if match_id == nil or match_id == "" do
      {:reply, {:error, :id_invalido}, state}
    else
      case read_results_file(state.results_path) do
        {:ok, existing_results} ->
          existente =
            Enum.find(existing_results, fn r ->
              id = r["id"] || r[:id]
              id != nil and to_string(id) == match_id
            end)

          if existente do
            advertir_si_colision(existente, resultado, match_id)
            {:reply, {:ok, :ya_registrado}, state}
          else
            case Jason.encode(resultado) do
              {:ok, json_line} ->
                case File.write(state.results_path, json_line <> "\n", [:append]) do
                  :ok -> {:reply, :ok, state}
                  {:error, reason} -> {:reply, {:error, reason}, state}
                end

              {:error, reason} ->
                {:reply, {:error, reason}, state}
            end
          end

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call(:cargar_preguntas, _from, state) do
    {:reply, state.banco_preguntas, state}
  end

  def handle_call(:recargar_preguntas, _from, state) do
    resultado = cargar_y_validar_banco(state.questions_path)
    {:reply, resultado, %{state | banco_preguntas: resultado}}
  end

  # ── Helpers privados ────────────────────────────────────────────────

  # Un reintento del mismo resultado es idempotente y no se reporta; un resultado
  # distinto con un id ya registrado se descarta, pero nunca en silencio.
  defp advertir_si_colision(existente, resultado, match_id) do
    normalizado =
      case Jason.encode(resultado) do
        {:ok, json} -> Jason.decode!(json)
        {:error, _} -> resultado
      end

    if normalizado != existente do
      Logger.error(
        "Persistencia: resultado descartado, el id #{match_id} ya existe en results.log " <>
          "con contenido distinto: #{inspect(resultado)}"
      )
    end

    :ok
  end

  defp cargar_y_validar_banco(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, data} when is_list(data) ->
            Trivia.BancoPreguntas.validar_banco(data)

          {:ok, _other} ->
            {:error, :formato_invalido}

          {:error, _} ->
            {:error, :json_invalido}
        end

      {:error, :enoent} ->
        {:error, :archivo_no_encontrado}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_users_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, list} when is_list(list) -> {:ok, list}
          {:ok, _other} -> {:error, :formato_invalido}
          {:error, _} -> {:error, :json_invalido}
        end

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_results_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        lines = String.split(contents, "\n", trim: true)
        parse_ndjson_lines(lines, [])

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_ndjson_lines([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_ndjson_lines([line | rest], acc) do
    case Jason.decode(line) do
      {:ok, data} when is_map(data) ->
        parse_ndjson_lines(rest, [data | acc])

      {:ok, _} ->
        {:error, :formato_invalido}

      {:error, _} ->
        {:error, :json_invalido}
    end
  end
end
