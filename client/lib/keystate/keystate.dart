// The key-state probe, chosen at compile time.
// Is one nominated key still held down, right now?
//
// ⚠️ THE IMPLEMENTATION IS CHOSEN AT COMPILE TIME. The Windows answer needs
// dart:ffi, which does not exist on the web - importing it unconditionally
// does not degrade gracefully, it fails the web build outright. That is how
// this was found: the panel the browser is served stopped compiling.
export 'keystate_stub.dart'
    if (dart.library.ffi) 'keystate_ffi.dart';
