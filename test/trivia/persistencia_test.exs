defmodule Trivia.PersistenciaTest do
  use ExUnit.Case, async: true

  @moduletag :persistencia

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "trivia_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    name = :"persistencia_#{:erlang.unique_integer([:positive])}"
    {:ok, pid} = Trivia.Persistencia.iniciar_link(data_dir: tmp_dir, name: name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(tmp_dir)
    end)

    %{pid: pid, server: name, tmp_dir: tmp_dir}
  end

  # ── users.json ──────────────────────────────────────────────────────

  describe "listar_usuarios/0 y registrar_usuario/2" do
    test "retorna lista vacía cuando users.json no existe", %{server: s} do
      assert Trivia.Persistencia.listar_usuarios(s) == []
    end

    test "registra un nuevo usuario y lo persiste en users.json", %{server: s, tmp_dir: dir} do
      assert :ok = Trivia.Persistencia.registrar_usuario("ana", "1234", s)
      users = Trivia.Persistencia.listar_usuarios(s)
      assert length(users) == 1
      assert hd(users)["usuario"] == "ana"
      assert hd(users)["clave"] == "1234"

      # Verifica que el archivo físico exista en users.json
      users_file = Path.join(dir, "users.json")
      assert File.exists?(users_file)
      decoded = users_file |> File.read!() |> Jason.decode!()
      assert hd(decoded)["usuario"] == "ana"
    end

    test "rechaza usuario duplicado con error propio", %{server: s} do
      :ok = Trivia.Persistencia.registrar_usuario("bob", "pass", s)

      assert {:error, :usuario_existente} =
               Trivia.Persistencia.registrar_usuario("bob", "other", s)
    end

    test "permite registrar múltiples usuarios distintos", %{server: s} do
      :ok = Trivia.Persistencia.registrar_usuario("user1", "pass1", s)
      :ok = Trivia.Persistencia.registrar_usuario("user2", "pass2", s)
      users = Trivia.Persistencia.listar_usuarios(s)
      assert length(users) == 2
    end

    test "no almacena estadísticas calculadas en users.json", %{server: s} do
      :ok = Trivia.Persistencia.registrar_usuario("carlos", "pass", s)
      [user] = Trivia.Persistencia.listar_usuarios(s)
      refute Map.has_key?(user, "puntaje")
      refute Map.has_key?(user, "nivel")
      refute Map.has_key?(user, "partidas")
    end
  end

  # ── results.log ─────────────────────────────────────────────────────

  describe "obtener_historial/0 y registrar_resultado/1" do
    test "retorna lista vacía cuando results.log no existe", %{server: s} do
      assert Trivia.Persistencia.obtener_historial(s) == []
    end

    test "agrega una línea NDJSON al historial y lo crea si no existe", %{server: s, tmp_dir: dir} do
      resultado = %{
        "id" => "P-1001",
        "tema" => "ciencia",
        "nivel" => "basico",
        "ganador" => "Pedro",
        "puntajes" => %{"Pedro" => 48, "bot_1" => 22}
      }

      assert :ok = Trivia.Persistencia.registrar_resultado(resultado, s)
      historial = Trivia.Persistencia.obtener_historial(s)
      assert length(historial) == 1
      assert hd(historial)["id"] == "P-1001"
      assert hd(historial)["puntajes"]["Pedro"] == 48

      # Verifica que results.log sea texto plano NDJSON
      results_file = Path.join(dir, "results.log")
      assert File.exists?(results_file)
      content = File.read!(results_file)
      assert String.ends_with?(content, "\n")
      assert Jason.decode!(String.trim(content))["id"] == "P-1001"
    end

    test "agrega múltiples resultados preservando el orden secuencial", %{server: s} do
      :ok = Trivia.Persistencia.registrar_resultado(%{"id" => "P-1", "ganador" => "Ana"}, s)
      :ok = Trivia.Persistencia.registrar_resultado(%{"id" => "P-2", "ganador" => "Carlos"}, s)
      h = Trivia.Persistencia.obtener_historial(s)
      assert length(h) == 2
      assert Enum.at(h, 0)["id"] == "P-1"
      assert Enum.at(h, 1)["id"] == "P-2"
    end
  end

  # ── registrar_resultado_unico/2 (Atómico e Idempotente) ─────────────

  describe "registrar_resultado_unico/2" do
    test "registra un resultado por primera vez y escribe exactamente una línea", %{
      server: s,
      tmp_dir: dir
    } do
      resultado = %{"id" => "P-101", "tema" => "ciencias", "ganador" => "Ana"}
      assert :ok = Trivia.Persistencia.registrar_resultado_unico(resultado, s)

      historial = Trivia.Persistencia.obtener_historial(s)
      assert length(historial) == 1
      assert hd(historial)["id"] == "P-101"

      lines =
        Path.join(dir, "results.log")
        |> File.read!()
        |> String.split("\n", trim: true)

      assert length(lines) == 1
    end

    test "registrar el mismo resultado por segunda vez no añade otra línea y retorna {:ok, :ya_registrado}",
         %{server: s, tmp_dir: dir} do
      resultado = %{"id" => "P-101", "tema" => "ciencias", "ganador" => "Ana"}
      assert :ok = Trivia.Persistencia.registrar_resultado_unico(resultado, s)

      # Segundo intento con el mismo ID
      assert {:ok, :ya_registrado} =
               Trivia.Persistencia.registrar_resultado_unico(resultado, s)

      # El archivo físico solo contiene una línea
      lines =
        Path.join(dir, "results.log")
        |> File.read!()
        |> String.split("\n", trim: true)

      assert length(lines) == 1
    end

    test "intentos concurrentes de registrar el mismo ID producen exactamente un registro", %{
      server: s,
      tmp_dir: dir
    } do
      resultado = %{"id" => "P-CONC", "tema" => "ciencias", "ganador" => "Pedro"}

      # Lanzar dos tareas concurrentes
      t1 = Task.async(fn -> Trivia.Persistencia.registrar_resultado_unico(resultado, s) end)
      t2 = Task.async(fn -> Trivia.Persistencia.registrar_resultado_unico(resultado, s) end)

      r1 = Task.await(t1)
      r2 = Task.await(t2)

      # Una debe ser :ok y la otra {:ok, :ya_registrado}
      respuestas = Enum.sort([r1, r2])
      assert respuestas == [:ok, {:ok, :ya_registrado}]

      lines =
        Path.join(dir, "results.log")
        |> File.read!()
        |> String.split("\n", trim: true)

      assert length(lines) == 1
    end

    test "historial malformado devuelve error y no escribe la nueva línea", %{
      server: s,
      tmp_dir: dir
    } do
      # Escribir línea corrupta en results.log
      results_file = Path.join(dir, "results.log")
      File.write!(results_file, "{corrupt_ndjson\n")

      resultado = %{"id" => "P-999", "tema" => "historia"}

      assert {:error, :json_invalido} =
               Trivia.Persistencia.registrar_resultado_unico(resultado, s)

      # El archivo no contiene la nueva partida
      content = File.read!(results_file)
      refute content =~ "P-999"
    end

    test "partidas con IDs distintos se registran normalmente", %{server: s} do
      r1 = %{"id" => "P-101", "ganador" => "Ana"}
      r2 = %{"id" => "P-102", "ganador" => "Carlos"}

      assert :ok = Trivia.Persistencia.registrar_resultado_unico(r1, s)
      assert :ok = Trivia.Persistencia.registrar_resultado_unico(r2, s)

      h = Trivia.Persistencia.obtener_historial(s)
      assert length(h) == 2
      assert Enum.map(h, fn registro -> registro["id"] end) == ["P-101", "P-102"]
    end
  end

  # ── questions.json ──────────────────────────────────────────────────

  describe "cargar_preguntas/0" do
    test "retorna error cuando questions.json no existe", %{server: s} do
      assert {:error, :archivo_no_encontrado} = Trivia.Persistencia.cargar_preguntas(s)
    end

    test "retorna error cuando questions.json contiene JSON inválido", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "questions.json"), "{ corrupt json...")
      name = :"pers_json_inv_#{:erlang.unique_integer([:positive])}"
      {:ok, pid} = Trivia.Persistencia.iniciar_link(data_dir: dir, name: name)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      assert {:error, :json_invalido} = Trivia.Persistencia.cargar_preguntas(name)
    end

    test "retorna error cuando el contenido no es una lista", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "questions.json"), Jason.encode!(%{"no" => "lista"}))
      name = :"pers_fmt_inv_#{:erlang.unique_integer([:positive])}"
      {:ok, pid} = Trivia.Persistencia.iniciar_link(data_dir: dir, name: name)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      assert {:error, :formato_invalido} = Trivia.Persistencia.cargar_preguntas(name)
    end

    test "carga preguntas exitosamente al iniciar cuando el archivo es válido", %{tmp_dir: dir} do
      preguntas = [
        %{
          "tema" => "matematicas",
          "nivel" => "basico",
          "enunciado" => "¿2+2?",
          "opciones" => %{"A" => "1", "B" => "2", "C" => "3", "D" => "4"},
          "respuesta" => "D"
        }
      ]

      File.write!(Path.join(dir, "questions.json"), Jason.encode!(preguntas))
      name = :"pers_valid_#{:erlang.unique_integer([:positive])}"
      {:ok, pid} = Trivia.Persistencia.iniciar_link(data_dir: dir, name: name)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      assert {:ok, loaded} = Trivia.Persistencia.cargar_preguntas(name)
      assert length(loaded) == 1
    end

    test "no recarga automáticamente cuando questions.json se crea después del inicio hasta llamar a recargar_preguntas/1",
         %{server: s, tmp_dir: dir} do
      # 1 y 2. Persistencia inició sin questions.json y devuelve :archivo_no_encontrado
      assert {:error, :archivo_no_encontrado} = Trivia.Persistencia.cargar_preguntas(s)

      # 3. Crear posteriormente un questions.json válido en ese directorio
      preguntas = [
        %{
          "tema" => "matematicas",
          "nivel" => "basico",
          "enunciado" => "¿2+2?",
          "opciones" => %{"A" => "1", "B" => "2", "C" => "3", "D" => "4"},
          "respuesta" => "D"
        }
      ]

      File.write!(Path.join(dir, "questions.json"), Jason.encode!(preguntas))

      # 4. cargar_preguntas/1 sigue devolviendo el error en caché sin releer el archivo
      assert {:error, :archivo_no_encontrado} = Trivia.Persistencia.cargar_preguntas(s)

      # 5. Llamar explícitamente a recargar_preguntas/1
      assert {:ok, recargadas} = Trivia.Persistencia.recargar_preguntas(s)
      assert length(recargadas) == 1

      # 6. Ahora cargar_preguntas/1 devuelve las preguntas almacenadas en caché
      assert {:ok, loaded} = Trivia.Persistencia.cargar_preguntas(s)
      assert length(loaded) == 1
      assert hd(loaded)["enunciado"] == "¿2+2?"
    end
  end

  # ── Manejo de Archivos Malformados / Corruptos ───────────────────────

  describe "manejo de archivos existentes malformados" do
    test "listar_usuarios retorna error cuando users.json está malformado", %{
      server: s,
      tmp_dir: dir
    } do
      File.write!(Path.join(dir, "users.json"), "{{bad json}}")
      assert {:error, :json_invalido} = Trivia.Persistencia.listar_usuarios(s)
    end

    test "registrar_usuario NUNCA sobreescribe un users.json malformado existente", %{
      server: s,
      tmp_dir: dir
    } do
      corrupt_content = "CORRUPT DATA DO NOT OVERWRITE"
      path = Path.join(dir, "users.json")
      File.write!(path, corrupt_content)

      # El intento de registro debe fallar
      assert {:error, :json_invalido} =
               Trivia.Persistencia.registrar_usuario("nuevo", "pass", s)

      # El archivo corrupto no fue sobreescrito
      assert File.read!(path) == corrupt_content
    end

    test "obtener_historial retorna error cuando results.log contiene líneas inválidas", %{
      server: s,
      tmp_dir: dir
    } do
      File.write!(Path.join(dir, "results.log"), "linea_no_json\n")
      assert {:error, :json_invalido} = Trivia.Persistencia.obtener_historial(s)
    end
  end
end
