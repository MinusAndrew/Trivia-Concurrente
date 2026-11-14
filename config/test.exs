import Config

# In test mode we don't auto-start the server supervisor;
# tests start Persistencia with their own temporary paths.
config :trivia, role: :none
