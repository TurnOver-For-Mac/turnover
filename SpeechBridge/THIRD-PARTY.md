# Third-party material

- `SpeechBridge/BusType/cfgmgr32.spec` is Wine's export list for cfgmgr32.dll, copied from the
  Wine project (LGPL-2.1-or-later) and used only to generate the pass-through thunks of the
  cfgmgr32 shim. It is data, not code, but the licence travels with it.
- The stand-in DLLs reproduce the *exported interfaces* of other programs so that games find
  what they expect: Tolk's System Access driver (SAAPI64), NVDA's controller client, the UAP
  WindowsTTS plugin, Microsoft's SAPI 5 engine and SpVoice interfaces, and the ZDSR client
  library. None of their code is included; each is written from the interface alone.
- Everything else in this folder is MIT, see LICENSE in this folder. TurnOver itself is GPL-3.0-or-later.
