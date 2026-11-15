defmodule Trivia.CLITest do
  use ExUnit.Case, async: true

  alias Trivia.CLI

  @moduletag :cli

  describe "opciones_servidor/1 (mix trivia.servidor)" do
    test "sin opciones usa el nodo servidor, la cookie trivia y el directorio por defecto" do
      assert CLI.opciones_servidor([]) ==
               {:ok, %{nombre: "servidor", cookie: "trivia", datos: nil, red: nil}}
    end

    test "acepta nombre, cookie y directorio de datos" do
      argv = ["--nombre", "servidor_2", "--cookie", "secreta", "--datos", "/tmp/trivia"]

      assert CLI.opciones_servidor(argv) ==
               {:ok, %{nombre: "servidor_2", cookie: "secreta", datos: "/tmp/trivia", red: nil}}
    end

    test "--help y -h piden la ayuda" do
      assert CLI.opciones_servidor(["--help"]) == :ayuda
      assert CLI.opciones_servidor(["-h"]) == :ayuda
    end

    test "rechaza opciones desconocidas, argumentos sueltos y valores inválidos" do
      assert {:error, "Opción no válida: --clave" <> _} =
               CLI.opciones_servidor(["--clave", "4000"])

      assert {:error, "Argumento inesperado: extra" <> _} = CLI.opciones_servidor(["extra"])

      assert {:error, "Nombre de nodo no válido" <> _} =
               CLI.opciones_servidor(["--nombre", "a b"])

      assert {:error, "La cookie no puede estar vacía."} = CLI.opciones_servidor(["--cookie", ""])
    end
  end

  describe "opciones_cliente/2 (mix trivia.cliente)" do
    test "sin opciones se conecta a servidor@<host local> con un nombre aleatorio" do
      assert {:ok, %{nombre: nombre, cookie: "trivia", servidor: :servidor@mi_maquina, red: nil}} =
               CLI.opciones_cliente([], "mi_maquina")

      assert nombre =~ ~r/^jugador_\d{4}$/
    end

    test "--servidor sin host se completa con el host local; con host se usa tal cual" do
      assert {:ok, %{servidor: :otro@mi_maquina}} =
               CLI.opciones_cliente(["--servidor", "otro"], "mi_maquina")

      assert {:ok, %{servidor: :"servidor@sala-3"}} =
               CLI.opciones_cliente(["--servidor", "servidor@sala-3"], "mi_maquina")
    end

    test "acepta nombre y cookie" do
      assert {:ok, %{nombre: "pedro", cookie: "secreta"}} =
               CLI.opciones_cliente(["--nombre", "pedro", "--cookie", "secreta"], "h")
    end

    test "rechaza nodos de servidor y nombres mal formados" do
      for valor <- ["@host", "servidor@", "a@b@c", "mal nombre"] do
        assert {:error, _} = CLI.opciones_cliente(["--servidor", valor], "h")
      end

      assert {:error, _} = CLI.opciones_cliente(["--nombre", "pedro!"], "h")

      assert {:error, "Opción no válida: --datos" <> _} =
               CLI.opciones_cliente(["--datos", "x"], "h")
    end

    test "--help pide la ayuda" do
      assert CLI.opciones_cliente(["--help"], "h") == :ayuda
    end
  end

  describe "modo red" do
    test "--publico usa nombres largos en el puerto 9100 con una cookie aleatoria" do
      assert {:ok, %{red: %{host: nil, puerto: 9100}, cookie: cookie}} =
               CLI.opciones_servidor(["--publico"])

      assert byte_size(cookie) >= 20
      assert {:ok, %{cookie: otra}} = CLI.opciones_servidor(["--publico"])
      refute otra == cookie
    end

    test "--host implica modo red y respeta --puerto y --cookie" do
      argv = ["--host", "mi-casa.duckdns.org", "--puerto", "9200", "--cookie", "c"]

      assert {:ok, %{red: %{host: "mi-casa.duckdns.org", puerto: 9200}, cookie: "c"}} =
               CLI.opciones_servidor(argv)

      assert {:ok, %{red: %{host: "192.168.1.20"}}} =
               CLI.opciones_servidor(["--host", "192.168.1.20"])
    end

    test "el servidor rechaza hosts sin punto, puertos inválidos y --puerto sin modo red" do
      assert {:error, "Host no válido" <> _} = CLI.opciones_servidor(["--host", "mi_maquina"])

      assert {:error, "Puerto no válido" <> _} =
               CLI.opciones_servidor(["--publico", "--puerto", "0"])

      assert {:error, "--puerto solo aplica" <> _} = CLI.opciones_servidor(["--puerto", "9100"])
    end

    test "el cliente entra en modo red cuando el servidor es una IP o un dominio" do
      assert {:ok, %{servidor: :"servidor@203.0.113.5", red: %{puerto: 9100}}} =
               CLI.opciones_cliente(["--servidor", "servidor@203.0.113.5"], "h")

      assert {:ok, %{red: %{puerto: 9200}}} =
               CLI.opciones_cliente(
                 ["--servidor", "s@mi-casa.duckdns.org", "--puerto", "9200"],
                 "h"
               )

      assert {:error, "Host no válido" <> _} =
               CLI.opciones_cliente(["--servidor", "s@1..2"], "h")

      assert {:error, "--puerto solo aplica" <> _} =
               CLI.opciones_cliente(["--servidor", "servidor", "--puerto", "9100"], "h")
    end
  end

  test "ip_local/0 retorna una IPv4 en texto" do
    assert {:ok, _} = CLI.ip_local() |> String.to_charlist() |> :inet.parse_ipv4strict_address()
  end

  test "host_local/0 retorna el host corto, sin dominio" do
    host = CLI.host_local()
    assert is_binary(host) and host != ""
    refute host =~ "."
    refute host =~ "@"
  end
end
