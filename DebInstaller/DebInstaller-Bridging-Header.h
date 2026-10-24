// DebInstaller-Bridging-Header.h — expone jbroot_helper.c a Swift.

#ifndef DebInstaller_Bridging_Header_h
#define DebInstaller_Bridging_Header_h

#include <unistd.h>

/// Carga libjailbreak de Dopamine. Devuelve 0 = OK, negativo = fallo.
/// errbuf (opcional, puede ser NULL) recibe mensaje de error legible.
int djb_init_libjailbreak(char *errbuf, int errbuf_len);

/// Ejecuta `path` con hasta 6 args como root vía exec_cmd_root.
/// Devuelve exit code del child, -901/-902 si libjailbreak no cargó.
int djb_exec_root_cmd(const char *path, const char *a1, const char *a2,
                      const char *a3, const char *a4, const char *a5, const char *a6);

/// Devuelve el path del jbroot ("/var/jb") o NULL si no disponible.
const char* djb_jbroot(void);

/// Verifica si libjailbreak.dylib existe en disco (sin cargarlo).
int djb_libjailbreak_available(void);

/// ¿Está exec_cmd_root ya cargada en el proceso (vía systemhook)?
int djb_exec_cmd_root_available(void);

#endif
