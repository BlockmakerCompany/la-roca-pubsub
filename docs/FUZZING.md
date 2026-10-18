# Fuzzing del router L7 (AFL++ con cobertura real del assembly)

Este documento explica **cómo** fuzzeamos el router HTTP de La Roca, **por qué**
la cobertura guiada sobre assembly a mano no es trivial, y **qué resultados**
obtuvimos. Es el respaldo técnico de la afirmación de robustez del motor.

---

## 1. Qué se fuzzea y por qué

El punto de entrada de red de La Roca es el parser L7 (`src/routers/parse_http_request.asm`).
Es el primer código que toca **cualquier byte que llega por el socket**, y por lo
tanto es la mayor superficie de ataque (malformed requests, desbordes, lecturas
fuera de rango). Si este parser tiene un bug de memoria, el motor entero cae.

Lo extrajimos a un módulo **puro** —sin syscalls, sin handlers, sin side effects—,
de modo que se pueda fuzzear de forma aislada, sin red ni motor:

```asm
; parse_http_request(buffer_ptr, length) -> route_code
; Sin syscalls, sin estado global, sin efectos colaterales.
```

El harness (`tests/afl_harness.c`) lee STDIN, llama al parser y sale. AFL++ usa su
fork-server para reiniciar el proceso por cada mutación, así que un segfault
aparece inmediatamente como crash.

---

## 2. El problema: el assembly no se instrumenta solo

`afl-clang-fast` instrumenta **el código C** que compila. Pero el parser es
**assembly ensamblado con NASM**: afl-clang-fast no lo toca. El resultado es una
ilusión de cobertura: el harness C tiene 2 bloques básicos, así que `afl-showmap`
reportaba siempre **2 tuples con el mismo hash**, sin importar el input.

Esto se verificó empíricamente:

```bash
$ afl-showmap -- ./bin/fuzz_parser < seed1  # 2 tuples
$ afl-showmap -- ./bin/fuzz_parser < seed2  # 2 tuples, mismo hash
```

Sin cobertura diferenciada, afl-fuzz **no puede guiarse** hacia caminos nuevos.
Las dos vías para arreglarlo:

| Vía | Mecanismo | Costo |
|-----|-----------|-------|
| QEMU mode (`-Q`) | `afl-qemu-trace` emula e instrumenta el binario | Compilar QEMU parcheado (~40 min, GB de disco) + `qemu-user`, `meson`, `libglib2.0-dev`, `bison`, `flex` |
| **Instrumentación manual** ✅ | Marcar cada bloque básico con un `call __afl_trace` | Ninguna dependencia extra; el runtime ya venía en `afl-compiler-rt.o` |

Elegimos la **instrumentación manual**: logra la misma cobertura real, sin
sudo ni builds pesados, y además es fiel al espíritu del proyecto (todo a mano,
sin dependencias).

---

## 3. Cómo instrumentamos el assembly

En `parse_http_request.asm` definimos una macro condicional:

```asm
%ifdef AFL_INSTRUMENTED
    extern __afl_trace
%macro AFL_EDGE 1
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push rbx
    mov rbx, rsp
    and rsp, -16          ; stack alineado a 16 para el call (SysV)
    mov edi, %1
    call __afl_trace
    mov rsp, rbx
    pop rbx
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
%endmacro
%else
%macro AFL_EDGE 1        ; build de producción: no genera nada
%endmacro
%endif
```

Cada bloque básico del router lleva un `AFL_EDGE <id>` con un id único (17 edges
en total: entrada, GET/POST, cada ruta, y cada rama del validador de topics).
`__afl_trace(id)` implementa el contador **neverZero** del mapa compartido:

```c
void __afl_trace(const u32 x) {
    PREV_LOC_T prev = __afl_prev_loc[0];
    __afl_prev_loc[0] = (x >> 1);
    u8 *p = &__afl_area_ptr[prev ^ x];
    // incremento con protección de desborde (nunca vuelve a 0)
    ...
}
```

Propiedades clave:

- **Producción intacta**: sin `-DAFL_INSTRUMENTED`, `AFL_EDGE` expande a nada.
  El binario de producción es byte-identical al de un build sin instrumentar.
- **Registros preservados**: la macro salva/restaura todos los registros
  caller-saved (y `rbx`), así que no altera la semántica del parser.
- **Stack siempre alineado**: `and rsp, -16` garantiza el ABI SysV del `call`
  independientemente de si el edge está en el cuerpo del prologue o en la
  entrada de un `call`-target.

---

## 4. Cómo construir y verificar cobertura

```bash
# Build del harness instrumentado (assembly + runtime AFL)
make fuzz-afl

# Verificar que la cobertura es REAL (varía por input)
afl-showmap -o /tmp/map -- ./bin/fuzz_parser_afl < tests/corpus/get_live.txt
#   -> 3 tuples (antes: 2 tuples idénticos para todo)

# Smoke test sin crash (corpus + edge cases + ráfaga aleatoria)
./tests/test_fuzz_smoke.sh
```

---

## 5. Campaña real

```bash
afl-fuzz -i tests/corpus -o tests/findings -V 300 -- ./bin/fuzz_parser_afl
```

Resultados (`tests/findings/default/fuzzer_stats`):

| Métrica | Valor |
|---------|-------|
| Duración | 300 s |
| Ejecuciones totales | **2.712.732** |
| Velocidad | **9.042 exec/s** |
| Ciclos de cola completos | 1.765 |
| Edges alcanzados (de 17 bloques básicos) | **15** |
| **Crashes** | **0** |
| Hangs | 0 |

---

## 6. Robustez + eficiencia: la foto completa

El fuzzing demuestra la **robustez** (0 crashes tras cientos de miles de
mutaciones guiadas sobre el punto de entrada de red). La **eficiencia** se
demuestra con el benchmark de concurrencia (`tests/bench.go`), que en el entorno
de CI dio:

| Métrica | Valor |
|---------|-------|
| Throughput | **27.558 req/s** |
| Mensajes/s (batch de 100) | **~2.755.800 msg/s** |
| Errores | 0 |

En conjunto: un router L7 que aguanta fuzzing agresivo sin un solo crash y que
sostiene ~2,7 millones de mensajes por segundo sobre el loopback local.
