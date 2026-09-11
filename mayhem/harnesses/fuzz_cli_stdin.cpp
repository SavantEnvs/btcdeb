// Backport harness for btcdeb-buggy-mhh-run-21 — an INSTRUMENTED stand-in for the exact surface
// the original mayhemheroes run 21 fuzzed: the plain `btcdeb` CLI fed a line on stdin.
//
// Why not just fuzz the CLI binary, as run 21 did? Because Mayhem's engine no longer derives edge
// coverage from an uninstrumented black-box command: two 1200s runs of `cmd: /mayhem/btcdeb` on
// this very branch fuzzed (60k tests, and they DID find the bug) but reported `edges_covered: 0`,
// which SPEC.md §6.2 item 11 rejects ("an uninstrumented, black-box file-input target can build and
// pass fuzz-smoke yet record zero coverage; prefer an instrumented harness"). The original 2022 run
// got 36,931 edges from Mayhem's own binary tracer; that path is gone.
//
// So this harness reproduces btcdeb.cpp's `pipe_in` branch IN PROCESS, byte for byte:
//
//   btcdeb.cpp:226  char buf[1024]; fgets(buf, 1024, stdin);      <- one line, max 1023 bytes
//   btcdeb.cpp:231  strip trailing \r / \n
//   btcdeb.cpp:245  instance.parse_script(script_str)             <- text/hex script parser
//   btcdeb.cpp:259  instance.parse_stack_args(ca.l)               <- no CLI args => empty
//   btcdeb.cpp:265  instance.setup_environment(flags)             <- STANDARD_SCRIPT_VERIFY_FLAGS
//   btcdeb.cpp:345  ContinueScript(*env)                          <- where run 21's bug fires
//
// The input INTERFACE is therefore identical to the CLI's (a raw byte line), so run 21's saved
// testsuite replays unchanged, and the crash is the same one the CLI aborts on: CScriptNum's
// `scriptnum_error` (script/script.h:245/261) thrown out of StepScript and never caught by btcdeb —
// CWE-248, the class the original run recorded. Nothing here catches it either, on purpose: the
// uncaught exception IS the bug. Verified backtrace from the CLI binary on a corpus input:
//   #1 CScriptNum::CScriptNum       ./script/script.h:245
//   #2 StepScript                   script/interpreter.cpp:945
//   #3 StepScript                   debugger/interpreter.cpp:148
//   #4 ContinueScript               debugger/interpreter.cpp:259
//   #5 main                         btcdeb.cpp:345
// i.e. entirely in btcdeb's own code — not a harness artifact.

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

#include <instance.h>
#include <debugger/interpreter.h>
#include <debugger/script.h>
#include <policy/policy.h>

// btcdeb's interactive front end (btcdeb.cpp / functions.cpp) owns these; the debugger library
// objects reference them, and btcdeb.cpp is not linked in here (it has main()).
InterpreterEnv* env = nullptr;
bool quiet = true;
bool pipe_in = true;   // the CLI sets both when stdin/stdout are not a tty — that is the fuzzed mode
bool pipe_out = true;
bool verbose = false;

// btcdeb sends the interpreter's step-by-step commentary to stderr through these function pointers;
// the CLI silences them whenever it is piped (btcdeb.cpp:115), so do the same.
extern "C" int LLVMFuzzerInitialize(int* /*argc*/, char*** /*argv*/) {
    btc_logf          = btc_logf_dummy;
    btc_sighash_logf  = btc_logf_dummy;
    btc_sign_logf     = btc_logf_dummy;
    btc_segwit_logf   = btc_logf_dummy;
    btc_taproot_logf  = btc_logf_dummy;
    btcdeb_verbose    = false;
    return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    // fgets(buf, 1024, stdin): up to 1023 bytes, stopping after the first '\n'. Embedded NULs are
    // copied in exactly as fgets copies them, so the strlen() below truncates the same way the CLI's
    // does — keeping this harness's notion of "the input" identical to the CLI's.
    char buf[1024];
    size_t n = 0;
    while (n + 1 < sizeof(buf) && n < size) {
        char c = static_cast<char>(data[n]);
        buf[n++] = c;
        if (c == '\n') break;
    }
    if (n == 0) return 0;              // fgets failure; the CLI warns and runs an empty script
    buf[n] = '\0';

    int len = static_cast<int>(strlen(buf));
    while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r')) buf[--len] = 0;

    Instance instance;                 // destructor frees env + checker: no cross-iteration state
    if (!instance.parse_script(buf)) return 0;          // CLI: "invalid script", exit 1

    instance.parse_stack_args(std::vector<const char*>{});
    if (!instance.setup_environment(STANDARD_SCRIPT_VERIFY_FLAGS)) return 0;

    env = instance.env;
    env->allow_disabled_opcodes = false;                // the CLI's default (no -z)
    ContinueScript(*env);                               // <- run 21's uncaught scriptnum_error
    env = nullptr;
    return 0;
}
