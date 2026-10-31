// -----------------------------------------------------------------------------
// File: tests/afl_harness.c
// Project: La Roca Micro-PubSub
// Responsibility: AFL++ fuzz harness for the pure L7 parser
//                 (src/routers/parse_http_request.asm).
//
// This harness links ONLY against parse_http_request.o — no engine, no network,
// no filesystem. It feeds STDIN into the parser and exits. AFL++ uses its fork
// server to restart the process for every mutated input, so a segfault in the
// parser surfaces immediately as a crash.
//
// Build (via make):  make fuzz     -> plain harness (smoke test only)
//                    make fuzz-afl -> parser assembly instrumented with AFL++
//                                     edge calls + AFL++ runtime linked in
//
// Run with AFL++:    afl-fuzz -i tests/corpus -o tests/findings \
//                       -- ./bin/fuzz_parser_afl
//   (no -Q needed: the assembly is instrumented by hand, see docs/FUZZING.md)
// -----------------------------------------------------------------------------
#include <unistd.h>
#include <string.h>

// Pure L7 parser exported from src/routers/parse_http_request.asm
// C ABI: int parse_http_request(const char *buffer, int length);
extern int parse_http_request(const char *buffer, int length);

int main(void) {
    char buffer[8192];

    // Zero-pad the whole buffer so the parser (which intentionally does NOT
    // bound-check against `length`) never reads past the input into invalid
    // memory. Reads beyond the input land in zeros within this buffer.
    memset(buffer, 0, sizeof(buffer));

    // AFL++ feeds mutated payloads via STDIN (fd 0)
    int len = (int)read(0, buffer, sizeof(buffer) - 1);
    if (len > 0) {
        // Jump directly into La Roca's pure L7 router. Mark volatile so the
        // call is never optimized away.
        volatile int route = parse_http_request(buffer, len);
        (void)route;
    }

    return 0;
}
