import Config

config :trivia,
  role: :server,
  data_dir: Path.expand("data")

# Configuración específica del entorno (p. ej. config/test.exs), si existe
if File.exists?(Path.join(__DIR__, "#{config_env()}.exs")) do
  import_config "#{config_env()}.exs"
end
