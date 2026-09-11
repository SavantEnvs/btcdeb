// Build-time LeakSanitizer off switch (fleet policy: preventive, every ASan-built target).
//
// ASan stays fully on; only the at-exit leak scan is disabled. btcdeb's CLI leaks by construction
// (btcdeb.cpp:233 strdup()s the script line and only frees it on the success path), and the
// debugger's InterpreterEnv keeps allocations alive for the rewind history — none of that is the
// bug this backport reproduces, and LSan reports of it show up in Mayhem as CWE-401 defects that
// have no counterpart in the original mayhemheroes run 21.
//
// Linked into every fuzz binary by mayhem/build.sh. This is the one sanctioned form: a build-time
// hook, never a baked-in sanitizer-options override (Mayhem alone owns ASAN_OPTIONS) and never a
// runtime toggle.
extern "C" int __lsan_is_turned_off(void) { return 1; }
