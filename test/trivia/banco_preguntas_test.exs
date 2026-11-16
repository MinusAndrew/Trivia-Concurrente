defmodule Trivia.BancoPreguntasTest do
  use ExUnit.Case, async: true

  alias Trivia.BancoPreguntas

  @moduletag :banco_preguntas

  @pregunta_valida %{
    "tema" => "matematicas",
    "nivel" => "basico",
    "enunciado" => "¿Cuánto es 2 + 3?",
    "opciones" => %{"A" => "4", "B" => "5", "C" => "6", "D" => "7"},
    "respuesta" => "B"
  }

  # Genera N preguntas de prueba para un tema y nivel dados
  defp fixture_preguntas(tema, nivel, cantidad) do
    Enum.map(1..cantidad, fn i ->
      %{
        "id" => "#{tema}_#{nivel}_#{i}",
        "tema" => tema,
        "nivel" => to_string(nivel),
        "enunciado" => "Pregunta #{i} de #{tema} (#{nivel})",
        "opciones" => %{"A" => "op1", "B" => "op2", "C" => "op3", "D" => "op4"},
        "respuesta" => "A"
      }
    end)
  end

  # Banco de prueba con suficientes preguntas (10 por nivel en 'ciencia' e 'historia')
  defp banco_prueba do
    ciencias =
      fixture_preguntas("ciencia", :basico, 10) ++
        fixture_preguntas("ciencia", :intermedio, 10) ++
        fixture_preguntas("ciencia", :avanzado, 10)

    historias =
      fixture_preguntas("historia", :basico, 10) ++
        fixture_preguntas("historia", :intermedio, 10) ++
        fixture_preguntas("historia", :avanzado, 10)

    ciencias ++ historias
  end

  # ── 4. Validación de estructura de preguntas ────────────────────────

  describe "validar_pregunta/1" do
    test "acepta una pregunta con estructura correcta" do
      assert :ok = BancoPreguntas.validar_pregunta(@pregunta_valida)
    end

    test "rechaza si falta el tema o está vacío" do
      assert {:error, :tema_invalido} =
               BancoPreguntas.validar_pregunta(Map.delete(@pregunta_valida, "tema"))

      assert {:error, :tema_invalido} =
               BancoPreguntas.validar_pregunta(Map.put(@pregunta_valida, "tema", ""))
    end

    test "rechaza niveles inválidos distintos de basico, intermedio, avanzado" do
      assert {:error, :nivel_invalido} =
               BancoPreguntas.validar_pregunta(Map.put(@pregunta_valida, "nivel", "experto"))

      assert {:error, :nivel_invalido} =
               BancoPreguntas.validar_pregunta(Map.put(@pregunta_valida, "nivel", "dificil"))
    end

    test "rechaza si el enunciado está ausente o vacío" do
      assert {:error, :enunciado_invalido} =
               BancoPreguntas.validar_pregunta(Map.delete(@pregunta_valida, "enunciado"))

      assert {:error, :enunciado_invalido} =
               BancoPreguntas.validar_pregunta(Map.put(@pregunta_valida, "enunciado", ""))
    end

    test "rechaza si las opciones no son exactamente A, B, C y D" do
      # Faltando una opción (solo 3)
      opciones_incompletas = %{"A" => "1", "B" => "2", "C" => "3"}

      assert {:error, :opciones_invalidas} =
               BancoPreguntas.validar_pregunta(
                 Map.put(@pregunta_valida, "opciones", opciones_incompletas)
               )

      # Con una opción de más (E)
      opciones_extra = %{"A" => "1", "B" => "2", "C" => "3", "D" => "4", "E" => "5"}

      assert {:error, :opciones_invalidas} =
               BancoPreguntas.validar_pregunta(
                 Map.put(@pregunta_valida, "opciones", opciones_extra)
               )

      # Con letras incorrectas
      opciones_malas = %{"1" => "A", "2" => "B", "3" => "C", "4" => "D"}

      assert {:error, :opciones_invalidas} =
               BancoPreguntas.validar_pregunta(
                 Map.put(@pregunta_valida, "opciones", opciones_malas)
               )
    end

    test "rechaza si la respuesta no es una de las 4 opciones (A, B, C, D)" do
      assert {:error, :respuesta_invalida} =
               BancoPreguntas.validar_pregunta(Map.put(@pregunta_valida, "respuesta", "X"))

      assert {:error, :respuesta_invalida} =
               BancoPreguntas.validar_pregunta(Map.put(@pregunta_valida, "respuesta", "1"))
    end

    test "respuesta como mapa no genera excepción" do
      assert {:error, :respuesta_invalida} =
               BancoPreguntas.validar_pregunta(Map.put(@pregunta_valida, "respuesta", %{}))
    end

    test "respuesta como lista no genera excepción" do
      assert {:error, :respuesta_invalida} =
               BancoPreguntas.validar_pregunta(Map.put(@pregunta_valida, "respuesta", [1, 2]))
    end

    test "respuesta como entero no genera excepción" do
      assert {:error, :respuesta_invalida} =
               BancoPreguntas.validar_pregunta(Map.put(@pregunta_valida, "respuesta", 42))
    end

    test "respuesta nil no genera excepción" do
      assert {:error, :respuesta_invalida} =
               BancoPreguntas.validar_pregunta(Map.put(@pregunta_valida, "respuesta", nil))
    end

    test "respuesta como string vacío es inválida" do
      assert {:error, :respuesta_invalida} =
               BancoPreguntas.validar_pregunta(Map.put(@pregunta_valida, "respuesta", ""))
    end
  end

  describe "validar_banco/1" do
    test "valida exitosamente una lista de preguntas válidas" do
      assert {:ok, _} = BancoPreguntas.validar_banco([@pregunta_valida])
    end

    test "retorna error si al menos una pregunta es inválida" do
      invalida = Map.put(@pregunta_valida, "nivel", "invalido")
      assert {:error, _} = BancoPreguntas.validar_banco([@pregunta_valida, invalida])
    end
  end

  # ── 5. Filtrado por tema y dificultad ───────────────────────────────

  describe "filtrado" do
    setup do
      %{banco: banco_prueba()}
    end

    test "filtrar_por_tema retorna únicamente preguntas del tema pedido", %{banco: b} do
      ciencias = BancoPreguntas.filtrar_por_tema(b, "ciencia")
      assert length(ciencias) == 30
      assert Enum.all?(ciencias, fn pregunta -> pregunta["tema"] == "ciencia" end)
    end

    test "filtrar_por_nivel retorna únicamente preguntas del nivel pedido", %{banco: b} do
      basicas = BancoPreguntas.filtrar_por_nivel(b, "basico")
      assert length(basicas) == 20
      assert Enum.all?(basicas, fn pregunta -> pregunta["nivel"] == "basico" end)
    end

    test "filtrar/3 combina tema y nivel", %{banco: b} do
      resultado = BancoPreguntas.filtrar(b, "ciencia", "intermedio")
      assert length(resultado) == 10

      assert Enum.all?(resultado, fn pregunta ->
               pregunta["tema"] == "ciencia" and pregunta["nivel"] == "intermedio"
             end)
    end

    test "listar_temas devuelve temas únicos", %{banco: b} do
      temas = BancoPreguntas.listar_temas(b)
      assert Enum.sort(temas) == ["ciencia", "historia"]
    end
  end

  # ── 6. Selección aleatoria sin duplicados y orden de dificultad ─────

  describe "sortear_preguntas/4" do
    setup do
      %{banco: banco_prueba()}
    end

    test "selecciona la cantidad exacta solicitada y no hay duplicados", %{banco: b} do
      assert {:ok, seleccion} = BancoPreguntas.sortear_preguntas(b, "ciencia", :basico, 5)
      assert length(seleccion) == 5

      # Sin duplicados
      ids = Enum.map(seleccion, fn pregunta -> pregunta["id"] end)
      assert length(Enum.uniq(ids)) == 5
    end

    test "respeta el reparto proporcional y ordena de menor a mayor dificultad", %{banco: b} do
      # Nivel basico con 5 preguntas: 4 básicas y 1 intermedia
      assert {:ok, seleccion} = BancoPreguntas.sortear_preguntas(b, "ciencia", :basico, 5)
      niveles = Enum.map(seleccion, fn pregunta -> pregunta["nivel"] end)

      assert niveles == ["basico", "basico", "basico", "basico", "intermedio"]
    end

    test "jugador intermedio con 10 preguntas recibe 2 básicas, 6 intermedias y 2 avanzadas", %{
      banco: b
    } do
      assert {:ok, seleccion} = BancoPreguntas.sortear_preguntas(b, "ciencia", :intermedio, 10)
      niveles = Enum.map(seleccion, fn pregunta -> pregunta["nivel"] end)

      assert Enum.count(niveles, fn nivel -> nivel == "basico" end) == 2
      assert Enum.count(niveles, fn nivel -> nivel == "intermedio" end) == 6
      assert Enum.count(niveles, fn nivel -> nivel == "avanzado" end) == 2

      # Orden de menor a mayor dificultad
      assert niveles == [
               "basico",
               "basico",
               "intermedio",
               "intermedio",
               "intermedio",
               "intermedio",
               "intermedio",
               "intermedio",
               "avanzado",
               "avanzado"
             ]
    end

    test "dos sorteos distintos producen selecciones aleatorias", %{banco: b} do
      # Con 10 preguntas disponibles de cada nivel, 2 sorteos de 5 preguntas no serán idénticos
      {:ok, s1} = BancoPreguntas.sortear_preguntas(b, "ciencia", :basico, 5)
      {:ok, s2} = BancoPreguntas.sortear_preguntas(b, "ciencia", :basico, 5)

      ids1 = Enum.map(s1, fn pregunta -> pregunta["id"] end)
      _ids2 = Enum.map(s2, fn pregunta -> pregunta["id"] end)

      # Al menos una de 10 ejecuciones debe diferir si hay aleatoriedad
      # (hacemos hasta 5 sorteos para evitar falsos negativos por pura casualidad)
      distintas =
        Enum.any?(1..10, fn _ ->
          {:ok, s} = BancoPreguntas.sortear_preguntas(b, "ciencia", :basico, 5)
          Enum.map(s, fn pregunta -> pregunta["id"] end) != ids1
        end)

      assert distintas
    end
  end

  # ── 7. Errores de preguntas insuficientes y temas inexistentes ───────

  describe "errores en sortear_preguntas" do
    setup do
      %{banco: banco_prueba()}
    end

    test "retorna error claro cuando el tema no existe", %{banco: b} do
      assert {:error, :tema_inexistente} =
               BancoPreguntas.sortear_preguntas(b, "tema_fantasma", :basico, 5)
    end

    test "retorna error claro cuando faltan preguntas de algún nivel para el reparto", %{banco: b} do
      # El banco tiene 10 preguntas avanzadas en historia. Si un avanzado pide 20 preguntas:
      # reparto para :avanzado con 20: 0 básicas, 6 intermedias, 14 avanzadas.
      # Como solo hay 10 avanzadas, debe fallar.
      assert {:error, :preguntas_insuficientes} =
               BancoPreguntas.sortear_preguntas(b, "historia", :avanzado, 20)
    end
  end

  # ── Protección de la clave de respuestas para clientes ──────────────

  describe "para_cliente/1" do
    test "para_cliente/1 elimina la clave 'respuesta' de una pregunta" do
      protegida = BancoPreguntas.para_cliente(@pregunta_valida)
      refute Map.has_key?(protegida, "respuesta")
      assert Map.has_key?(protegida, "enunciado")
      assert Map.has_key?(protegida, "opciones")
    end

    test "para_cliente/1 limpia listas de preguntas" do
      lista = [@pregunta_valida, @pregunta_valida]
      protegidas = BancoPreguntas.para_cliente(lista)

      for p <- protegidas do
        refute Map.has_key?(p, "respuesta")
        refute Map.has_key?(p, :respuesta)
      end
    end
  end

  # ── Carga a través de Persistencia y Semilla del Proyecto ───────────

  describe "integración con Persistencia y archivo semilla" do
    test "carga el banco semilla data/questions.json a través de Persistencia" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "trivia_bp_test_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      # Copia el banco semilla al directorio de prueba
      seed_path = Path.expand("data/questions.json")
      File.cp!(seed_path, Path.join(tmp_dir, "questions.json"))

      name = :"persistencia_bp_#{:erlang.unique_integer([:positive])}"
      {:ok, pid} = Trivia.Persistencia.iniciar_link(data_dir: tmp_dir, name: name)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        File.rm_rf!(tmp_dir)
      end)

      # Carga a través de Persistencia usando el módulo BancoPreguntas
      assert {:ok, preguntas} = BancoPreguntas.cargar_banco(name)
      assert length(preguntas) == 120

      temas = BancoPreguntas.listar_temas(preguntas)
      assert Enum.sort(temas) == ["ciencias", "geografia", "historia", "matematicas", "pokemon"]

      # Verifica que se pueda realizar un sorteo exitoso
      assert {:ok, seleccion} =
               BancoPreguntas.sortear_preguntas(preguntas, "matematicas", :intermedio, 5)

      assert length(seleccion) == 5
    end

    test "el banco de preguntas se carga y valida al iniciar Persistencia y queda disponible en memoria" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "trivia_bp_init_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      seed_path = Path.expand("data/questions.json")
      File.cp!(seed_path, Path.join(tmp_dir, "questions.json"))

      name = :"persistencia_bp_init_#{:erlang.unique_integer([:positive])}"
      {:ok, pid} = Trivia.Persistencia.iniciar_link(data_dir: tmp_dir, name: name)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        File.rm_rf!(tmp_dir)
      end)

      # El estado interno de Persistencia ya tiene el banco validado tras init/1
      pers_state = :sys.get_state(pid)
      assert {:ok, cached} = pers_state.banco_preguntas
      assert length(cached) == 120

      assert {:ok, ^cached} = BancoPreguntas.cargar_banco(name)
    end

    test "el sorteo de preguntas usa el banco en caché sin releer questions.json en cada invocación" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "trivia_bp_cache_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      q_path = Path.join(tmp_dir, "questions.json")
      File.cp!(Path.expand("data/questions.json"), q_path)

      name = :"persistencia_bp_cache_#{:erlang.unique_integer([:positive])}"
      {:ok, pid} = Trivia.Persistencia.iniciar_link(data_dir: tmp_dir, name: name)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        File.rm_rf!(tmp_dir)
      end)

      # Eliminar o corromper questions.json después del arranque
      File.write!(q_path, "{corrupt_after_startup")

      # Múltiples consultas y sorteos siguen funcionando desde la caché en memoria
      assert {:ok, preguntas} = BancoPreguntas.cargar_banco(name)
      assert length(preguntas) == 120

      assert {:ok, sel1} = BancoPreguntas.sortear_preguntas(name, "ciencias", :basico, 5)
      assert {:ok, sel2} = BancoPreguntas.sortear_preguntas(name, "historia", :avanzado, 5)
      assert length(sel1) == 5
      assert length(sel2) == 5
    end

    test "maneja explícitamente banco faltante, JSON malformado o preguntas con estructura inválida al iniciar" do
      base_dir =
        Path.join(System.tmp_dir!(), "trivia_bp_err_#{:erlang.unique_integer([:positive])}")

      # 1. Archivo faltante
      dir_missing = Path.join(base_dir, "missing")
      File.mkdir_p!(dir_missing)
      n1 = :"pers_err_1_#{:erlang.unique_integer([:positive])}"
      {:ok, p1} = Trivia.Persistencia.iniciar_link(data_dir: dir_missing, name: n1)

      # 2. JSON inválido
      dir_bad_json = Path.join(base_dir, "bad_json")
      File.mkdir_p!(dir_bad_json)
      File.write!(Path.join(dir_bad_json, "questions.json"), "{invalid_json")
      n2 = :"pers_err_2_#{:erlang.unique_integer([:positive])}"
      {:ok, p2} = Trivia.Persistencia.iniciar_link(data_dir: dir_bad_json, name: n2)

      # 3. Pregunta con estructura inválida en questions.json
      dir_bad_q = Path.join(base_dir, "bad_q")
      File.mkdir_p!(dir_bad_q)
      pregunta_mala = Map.put(@pregunta_valida, "nivel", "imposible")
      File.write!(Path.join(dir_bad_q, "questions.json"), Jason.encode!([pregunta_mala]))
      n3 = :"pers_err_3_#{:erlang.unique_integer([:positive])}"
      {:ok, p3} = Trivia.Persistencia.iniciar_link(data_dir: dir_bad_q, name: n3)

      on_exit(fn ->
        for pid <- [p1, p2, p3] do
          if Process.alive?(pid), do: GenServer.stop(pid)
        end

        File.rm_rf!(base_dir)
      end)

      assert {:error, :archivo_no_encontrado} = BancoPreguntas.cargar_banco(n1)

      assert {:error, :archivo_no_encontrado} =
               BancoPreguntas.sortear_preguntas(n1, "ciencias", :basico, 5)

      assert {:error, :json_invalido} = BancoPreguntas.cargar_banco(n2)
      assert {:error, {:nivel_invalido, _}} = BancoPreguntas.cargar_banco(n3)
    end
  end
end
