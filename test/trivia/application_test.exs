defmodule Trivia.ApplicationTest do
  # Arranca y detiene la aplicación real y modifica variables de entorno y la
  # configuración global: no puede ejecutarse en paralelo con otras pruebas.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Trivia.Application, as: TriviaApp

  @moduletag :aplicacion

  setup do
    rol_env = System.get_env("TRIVIA_ROLE")
    rol_config = Application.fetch_env(:trivia, :role)
    data_dir_config = Application.fetch_env(:trivia, :data_dir)

    tmp_dir =
      Path.join(System.tmp_dir!(), "trivia_app_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    File.cp!(Path.expand("data/questions.json"), Path.join(tmp_dir, "questions.json"))

    on_exit(fn ->
      # Restablecer la aplicación tal como la dejó `mix test`
      capture_log(fn -> Application.stop(:trivia) end)
      restaurar_env("TRIVIA_ROLE", rol_env)
      restaurar_config(:role, rol_config)
      restaurar_config(:data_dir, data_dir_config)
      {:ok, _} = Application.ensure_all_started(:trivia)
      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  defp restaurar_env(var, nil), do: System.delete_env(var)
  defp restaurar_env(var, valor), do: System.put_env(var, valor)

  defp restaurar_config(clave, {:ok, valor}), do: Application.put_env(:trivia, clave, valor)
  defp restaurar_config(clave, :error), do: Application.delete_env(:trivia, clave)

  # Reinicia la aplicación real con el rol indicado en TRIVIA_ROLE (o sin él)
  defp reiniciar_app(rol_env) do
    capture_log(fn -> Application.stop(:trivia) end)
    restaurar_env("TRIVIA_ROLE", rol_env)
    {:ok, _} = Application.ensure_all_started(:trivia)
  end

  describe "arranque real de Trivia.Application" do
    test "en rol servidor levanta el árbol completo con el directorio de datos configurado",
         %{tmp_dir: dir} do
      Application.put_env(:trivia, :data_dir, dir)
      reiniciar_app("server")

      assert is_pid(Process.whereis(Trivia.Supervisor))

      hijos =
        Trivia.Supervisor
        |> Supervisor.which_children()
        |> Enum.map(fn {id, pid, _tipo, _modulos} ->
          assert is_pid(pid)
          id
        end)
        |> Enum.sort()

      assert hijos ==
               Enum.sort([
                 Trivia.Persistencia,
                 Trivia.SupervisorPartidas,
                 Trivia.GestorPartidas,
                 Trivia.GestorJugadores,
                 Trivia.Servidor
               ])

      assert :sys.get_state(Trivia.Persistencia).data_dir == dir

      # El árbol atiende peticiones de punta a punta
      assert {:error, :sesion_no_iniciada} =
               GenServer.call(Trivia.Servidor, {:peticion, :score})
    end

    test "en rol cliente no levanta un servidor propio" do
      reiniciar_app("client")

      assert is_pid(Process.whereis(Trivia.AppSupervisor))
      assert Supervisor.which_children(Trivia.AppSupervisor) == []
      assert Process.whereis(Trivia.Supervisor) == nil
      assert Process.whereis(Trivia.Servidor) == nil
    end

    test "sin TRIVIA_ROLE y con rol :none en la configuración no levanta el servidor" do
      Application.put_env(:trivia, :role, :none)
      reiniciar_app(nil)

      assert Process.whereis(Trivia.Supervisor) == nil
    end
  end

  describe "resolver_rol/2" do
    test "TRIVIA_ROLE tiene prioridad sobre la configuración y el nombre del nodo" do
      Application.put_env(:trivia, :role, :none)

      for valor <- ["server", "servidor"] do
        assert TriviaApp.resolver_rol(:pedro@host, valor) == :server
      end

      for valor <- ["client", "cliente", "none"] do
        assert TriviaApp.resolver_rol(:servidor@host, valor) == :client
      end
    end

    test "con rol :none en la configuración no se deduce el rol del nombre del nodo" do
      Application.put_env(:trivia, :role, :none)
      assert TriviaApp.resolver_rol(:servidor@host, nil) == :none
    end

    test "con rol configurado, el prefijo del nodo decide sin distinguir mayúsculas" do
      Application.put_env(:trivia, :role, :server)

      assert TriviaApp.resolver_rol(:servidor@host, nil) == :server
      assert TriviaApp.resolver_rol(:SERVIDOR_2@host, nil) == :server
      assert TriviaApp.resolver_rol(:server@host, nil) == :server
      assert TriviaApp.resolver_rol(:pedro@host, nil) == :client
    end

    test "en un nodo sin nombre se usa el rol de la configuración" do
      Application.put_env(:trivia, :role, :server)
      assert TriviaApp.resolver_rol(:nonode@nohost, nil) == :server

      Application.put_env(:trivia, :role, :client)
      assert TriviaApp.resolver_rol(:nonode@nohost, nil) == :client
    end
  end
end
