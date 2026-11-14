# Trivia Concurrente

Juego de preguntas y respuestas concurrente y distribuido con soporte para múltiples partidas simultáneas y jugadores automáticos (bots), desarrollado en Elixir y OTP.

---

## Integrantes

* Andrés Camilo Gómez
* Jacobo Londoño Davila

---

## Guía Rápida: Compilación y Cómo Levantar el Servidor y los Clientes

### 1. Prerrequisitos y Compilación
* Elixir 1.17+ y Erlang/OTP 27+ (con `epmd` activo para nodos distribuidos).

```bash
mix deps.get
mix compile
```

---

### 2. Cómo Levantar el Servidor Central (Consola 1)

El servidor central se levanta en su propio nodo Erlang. Cuando el nombre corto del nodo comienza por `servidor` (o `server`), o cuando se define `TRIVIA_ROLE=server`, `Trivia.Application` inicia automáticamente todo el árbol de supervisión (`Trivia.Supervisor`, `Trivia.Persistencia`, `Trivia.SupervisorPartidas`, `Trivia.GestorPartidas`, `Trivia.GestorJugadores` y `Trivia.Servidor`).

**Opción A — Servidor en consola interactiva IEx (recomendado para sustentación):**
```bash
iex --sname servidor --cookie trivia -S mix
```

Al abrirse el prompt `iex(servidor@tu_host)1>`, el servidor **ya está arriba y esperando clientes**. Puedes verificar su nombre de nodo exacto y que el proceso está activo ejecutando dentro de IEx:
```elixir
Node.self()
# => :"servidor@tu_host"

Process.whereis(Trivia.Servidor)
# => #PID<0.165.0>
```
*(Si iniciaste un nodo con otro nombre y deseas levantar el árbol del servidor manualmente en ese nodo, puedes ejecutar `Trivia.Supervisor.start_link()`).*

**Opción B — Servidor en modo sin consola interactiva (`--no-halt`):**
```bash
elixir --sname servidor --cookie trivia -S mix run --no-halt
```

---

### 3. Cómo Levantar y Conectar los Clientes (Consolas 2 y 3)

Cada jugador abre una terminal independiente con su propio `--sname` y la misma `--cookie trivia`. Los nodos cuyo nombre no comienza por `servidor`/`server` arrancan en modo `:client` (sin levantar un servidor local).

#### Consola 2 — Cliente 1 (ejemplo: Pedro)
1. Levantar el nodo de Pedro:
   ```bash
   iex --sname pedro --cookie trivia -S mix
   ```
2. Dentro de IEx, iniciar la consola interactiva del cliente apuntando al nodo del servidor (reemplaza `tu_host` por el host que aparece en el prompt `iex(servidor@tu_host)1>` de la Consola 1):
   ```elixir
   Trivia.Cliente.iniciar(:"servidor@tu_host")
   ```
   *(Alternativa en un solo comando desde la terminal: `elixir --sname pedro --cookie trivia -S mix run -e 'Trivia.Cliente.iniciar(:"servidor@tu_host")'`)*

#### Consola 3 — Cliente 2 (ejemplo: Carlos)
1. Levantar el nodo de Carlos:
   ```bash
   iex --sname carlos --cookie trivia -S mix
   ```
2. Dentro de IEx, conectar al mismo nodo servidor:
   ```elixir
   Trivia.Cliente.iniciar(:"servidor@tu_host")
   ```

---

### 4. Comandos Disponibles en la Consola del Cliente (`trivia> `)

| Comando | Descripción |
|---|---|
| `connect <usuario> <clave>` | Inicia sesión en el servidor (o registra automáticamente al usuario en `data/users.json` si no existe). |
| `disconnect` | Cierra la sesión activa (si había partida en curso, guarda el puntaje parcial y la cierra según sección 6.5). |
| `score` | Muestra el puntaje histórico acumulado, partidas jugadas y nivel por tema del jugador. |
| `ranking` | Muestra el ranking histórico global de jugadores humanos. |
| `ranking <tema>` | Muestra el ranking histórico filtrado por un tema (ej. `ranking ciencias`). |
| `create_game tema=<t> preguntas=<n> tiempo=<s>` | Crea una nueva partida configurando tema, cantidad de preguntas y segundos por ronda. |
| `add_bot <facil\|dificil>` | Agrega un bot (`bot_1`, `bot_2`, `bot_3`) a la partida en espera (mínimo 2, máximo 3). |
| `start_game` | Inicia la partida una vez agregados entre 2 y 3 bots. |
| `answer <A\|B\|C\|D>` | Envía la respuesta del jugador para la pregunta de la ronda abierta. |
| `leave_game` | Abandona la partida actual (cancela sin guardar si estaba en espera; guarda resultado parcial si estaba en curso). |
| `help` / `exit` | Muestra la lista de comandos o cierra el cliente. |

---

### 5. Ejecución de Pruebas Automatizadas
```bash
mix test
```

---

## Arquitectura del Servidor

El servidor central concentra el estado global y coordina la persistencia, el banco de preguntas y las partidas concurrentes.

```text
Trivia.Supervisor (one_for_one)
├── Trivia.Persistencia (GenServer)
├── Trivia.SupervisorPartidas (DynamicSupervisor, one_for_one)
│   └── Trivia.Partida (GenServer, restart: :transient)
│       └── Trivia.Bot (GenServer enlazado/monitoreado por partida)
├── Trivia.GestorPartidas (GenServer)
├── Trivia.GestorJugadores (GenServer)
└── Trivia.Servidor (GenServer)
```

### Módulos Principales

1. **`Trivia.Application`**: Punto de entrada de la aplicación OTP. Determina automáticamente el rol del nodo (`:server` para nodos `servidor@...` o `TRIVIA_ROLE=server`; `:client` para nodos de jugadores como `pedro@...`, `carlos@...` o `TRIVIA_ROLE=client`) para que los clientes nunca levanten su propia copia del servidor.
2. **`Trivia.Supervisor`**: Supervisor raíz del servidor que coordina los servicios principales (`Persistencia`, `SupervisorPartidas`, `GestorPartidas`, `GestorJugadores` y `Servidor`).
3. **`Trivia.Servidor`**: Punto de entrada único para clientes remotos. Valida la forma de cada petición, identifica al jugador mediante el PID del cliente emisor (`from`) y enruta hacia `GestorJugadores` o `GestorPartidas`.
4. **`Trivia.GestorJugadores`**: Administra el registro automático y autenticación de jugadores, las sesiones activas, el monitoreo de procesos cliente remotos (aplicando abandono según sección 6.5 ante desconexión) y las consultas `score` y `ranking`.
5. **`Trivia.SupervisorPartidas`**: `DynamicSupervisor` encargado de supervisar dinámicamente cada proceso independiente de partida (`Trivia.Partida`) con estrategia `restart: :transient`.
6. **`Trivia.GestorPartidas`**: `GenServer` coordinador del ciclo de vida de las partidas:
   * Asignación de identificadores únicos (`P-1001`, `P-1002`, ...).
   * Mapeo de jugadores a partidas para impedir que un jugador cree o participe en múltiples partidas a la vez.
   * Ubicación de partidas para los clientes sin exponer los PIDs de los procesos.
   * Manejo de avisos asíncronos de reinicio (`GenServer.cast`) para actualizar PIDs y notificar al creador ante fallas.
7. **`Trivia.Partida`**: `GenServer` que modela una partida individual aislada. Administra su propio estado (creador, tema, nivel, preguntas, bots, estado, puntajes, temporizadores de ronda y pausas).
8. **`Trivia.Bot`**: `GenServer` para cada jugador automático (`:facil` o `:dificil`), con funciones puras de decisión y envío asíncrono mediante `Process.send_after/3`.
9. **`Trivia.BancoPreguntas`**: Carga, valida y sortea preguntas por tema y dificultad garantizando el reparto proporcional y la seguridad de las respuestas hacia clientes.
10. **`Trivia.Persistencia`**: `GenServer` exclusivo para lectura y escritura de archivos en `data/` (secciones 8.1 y 9):
    * `data/users.json` — Lista JSON de usuarios registrados (`usuario` y `clave`).
    * `data/questions.json` — Banco semilla de preguntas (`tema`, `nivel`, `enunciado`, `opciones` y `respuesta`), cargado y validado al iniciar el servidor y mantenido en memoria para todas las partidas.
    * `data/results.log` — Historial de partidas finalizadas en formato NDJSON (una línea JSON por partida con `id`, `fecha`, `tema`, `nivel`, `ganador` y `puntajes`).
11. **`Trivia.Nivel`** y **`Trivia.Puntaje`**: Módulos funcionales puros para cálculo de puntajes, bonificación por rapidez, niveles, reparto y estadísticas históricas.
12. **`Trivia.Cliente`** y **`Trivia.Receptor`**: Módulos del nodo cliente. `Trivia.Cliente` traduce comandos de consola en peticiones al servidor remoto y `Trivia.Receptor` corre en un proceso separado (con historial acotado a las 100 notificaciones más recientes) para recibir e imprimir notificaciones asíncronas sin bloquear la lectura del teclado.

---

## Reglas de Puntaje y Ejemplo de Flujo

### Cálculo de puntaje por pregunta (sección 6.4)
| Situación | Básico | Intermedio | Avanzado | Bonificación por rapidez (solo respuestas correctas) | Máximo por pregunta |
|---|---|---|---|---|---|
| Respuesta correcta | +10 | +15 | +20 | `trunc(5 * segundos_restantes / tiempo_pregunta)` (0 a 5 pts) | **15** (`basico`), **20** (`intermedio`), **25** (`avanzado`) |
| Respuesta incorrecta | -5 | -8 | -10 | 0 | — |
| Sin responder | 0 | 0 | 0 | 0 | 0 |

Por lo tanto, en una partida de **3 preguntas**, el puntaje máximo posible es de **45 puntos** en nivel `basico` (3 × 15) y **75 puntos** en el caso teórico de 3 preguntas de nivel `avanzado` (3 × 25).

### Ejemplo de flujo completo en consola (partida de 3 preguntas)
```text
trivia> connect pedro 1234
Usuario 'pedro' registrado y conectado exitosamente.

trivia> create_game tema=ciencias preguntas=3 tiempo=10
Partida creada: P-1001 (nivel basico). Agrega al menos 2 bots con add_bot y ejecuta start_game.

trivia> add_bot facil
Bot agregado a la partida: bot_1.

trivia> add_bot dificil
Bot agregado a la partida: bot_2.

trivia> start_game
La partida ha comenzado.

═══ Partida P-1001 iniciada (ciencias, nivel basico) ═══
Jugadores: pedro, bot_1, bot_2 | Preguntas: 3 | Tiempo por pregunta: 10s

═══ Pregunta 1 de 3 - ciencias - Nivel basico ═══
¿Cuál es el planeta más grande del sistema solar?
  A) Marte      B) Júpiter      C) Saturno      D) Neptuno
Tiempo: 10 segundos

trivia> answer B
Respuesta registrada.

Respuesta correcta: B
  pedro       +14   (total 14)
  bot_2       +12   (total 12)
  bot_1        -5   (total -5)
...
═══ Fin de la partida P-1001 (ciencias, nivel basico) ═══
#    Jugador   Puntaje
1    pedro         41
2    bot_2         18
3    bot_1          5

Ganador: pedro

trivia> score
=== pedro ===
Puntaje acumulado: 41
Partidas jugadas: 1

Tema        Puntaje   Nivel
ciencias         41   basico

trivia> ranking ciencias
=== Ranking (ciencias) ===
#    Jugador     Puntaje    Partidas
1    pedro            41           1

trivia> disconnect
Sesión cerrada correctamente.
```

---

## Concurrencia y Resiliencia ante Fallas

* **Aislamiento**: Cada partida corre en su propio proceso `GenServer`. Un fallo o choque en una partida no afecta a las demás partidas activas ni al servidor.
* **Reinicio Transitorio (`restart: :transient`)**:
  * Una partida que finaliza o se cancela voluntariamente termina con razón `:normal` y el supervisor no la reinicia.
  * Una partida que sufre un choque anormal es reiniciada automáticamente por `Trivia.SupervisorPartidas` en su estado inicial (`:esperando`, con el creador original, sin bots y con puntajes en cero).
  * La partida reiniciada reporta su nuevo PID al `GestorPartidas` mediante `cast` (evitando bloqueos o deadlocks), y el gestor despacha la notificación correspondiente al creador.

---

## Documentación del Uso de Inteligencia Artificial

Durante el desarrollo de este proyecto se utilizaron herramientas de asistencia de inteligencia artificial con los siguientes propósitos:

* **Herramienta utilizada**: Asistente de codificación con IA (Antigravity / LLM).
* **Propósito**:
  * Estructuración incremental por hitos de los módulos Elixir/OTP (`GenServer`, `Supervisor`, `DynamicSupervisor`) siguiendo la arquitectura definida en `proyecto20262.md`.
  * Generación y endurecimiento de pruebas automatizadas con `ExUnit` y nodos distribuidos con `:peer`.
  * Revisión de casos borde de concurrencia (temporizadores de ronda, persistencia recuperable e historial acotado de notificaciones) y redacción de documentación técnica.
