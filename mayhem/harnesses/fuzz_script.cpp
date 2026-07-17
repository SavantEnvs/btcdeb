// libFuzzer harness for btcdeb's Bitcoin Script interpreter.
//
// btcdeb is a Bitcoin Script debugger: its whole reason for existing is to
// decode a raw script and step it through the consensus interpreter
// (debugger/interpreter.cpp's EvalScript). The old Mayhemfile fuzzed the raw
// `btcdeb` CLI with no input file, which drives no code and records 0 edges,
// so this replaces it with an in-process harness over the exact same code
// path: parse the fuzz input as a raw CScript and run it through EvalScript
// with a no-op signature checker. This is the standard, high-coverage Bitcoin
// Script fuzz surface.

#include <cstddef>
#include <cstdint>
#include <vector>

#include <script/interpreter.h>
#include <script/script.h>
#include <debugger/script.h>

// btcdeb logs interpreter steps to stderr via these function pointers; silence
// them so fuzzing isn't dominated by I/O (the CLI does the same when piped).
extern "C" int LLVMFuzzerInitialize(int* /*argc*/, char*** /*argv*/) {
    btc_logf        = btc_logf_dummy;
    btc_sighash_logf = btc_logf_dummy;
    btc_sign_logf    = btc_logf_dummy;
    btc_segwit_logf  = btc_logf_dummy;
    btc_taproot_logf = btc_logf_dummy;
    return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    if (size < 1) return 0;

    // First byte selects the SCRIPT_VERIFY_* flag combination; the rest is the
    // raw script. Fuzzing the flags exercises the many consensus rule branches.
    unsigned int flags = data[0];
    const uint8_t* script_bytes = data + 1;
    size_t script_size = size - 1;

    CScript script(script_bytes, script_bytes + script_size);

    std::vector<std::vector<unsigned char>> stack;
    BaseSignatureChecker checker;            // all checks return false (no keys)
    ScriptExecutionData execdata;
    ScriptError err = SCRIPT_ERR_OK;

    // SigVersion::BASE keeps us on the legacy/witness-v0 dispatch that the
    // no-op checker fully supports (tapscript paths assert on debugger-only
    // invariants, which are the tool's assumptions, not consensus defects).
    EvalScript(stack, script, flags, checker, SigVersion::BASE, execdata, &err);

    return 0;
}
