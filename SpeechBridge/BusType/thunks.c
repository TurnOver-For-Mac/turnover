/* the pass-throughs, kept away from cfgmgr32.h whose prototypes they would clash with */
#include <windows.h>
#define CR_CALL_NOT_IMPLEMENTED 0x27
FARPROC shim_real(const char *name);
#include "thunks.h"
