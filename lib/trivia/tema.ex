defmodule Trivia.Tema do
  @moduledoc """
  Normalización única de temas.

  El tema se guarda y se muestra tal como lo escribió el usuario (o como aparece
  en el banco de preguntas); para comparar o agrupar temas siempre se usa
  `normalizar/1`, de modo que el banco, el nivel, `score` y `ranking` coincidan.

  Reglas, en orden:

    1. Se quitan los espacios al inicio y al final.
    2. Se pasa a minúsculas.
    3. Se eliminan los acentos y diacríticos (`"Geografía"` → `"geografia"`).
    4. Se elimina una única `"s"` final, de modo que singular y plural coinciden
       (`"ciencia"`, `"Ciencias"` y `"ciencias"` son el mismo tema). El banco usa
       `"ciencias"` y `"matematicas"` mientras que jugadores e historial suelen
       escribir `"ciencia"`; sin esta regla `create_game ciencia` no encontraría
       preguntas. No cubre plurales en `"es"` (`"animal"` ≠ `"animales"`).
  """

  @doc """
  Retorna la forma normalizada de un tema, usada solo para comparar o agrupar.
  """
  @spec normalizar(term()) :: String.t()
  def normalizar(tema) do
    tema
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.replace(~r/s\z/, "")
  end

  @doc """
  Indica si dos temas son el mismo según `normalizar/1`.
  """
  @spec iguales?(term(), term()) :: boolean()
  def iguales?(tema_a, tema_b), do: normalizar(tema_a) == normalizar(tema_b)
end
