// jbroot_helper.c  v0.1.2
// systemhook ya carga libjailbreak.dylib en nuestro proceso automáticamente.
// Entonces NO hay que dlopen (eso devuelve rc=-1 "already loaded").
// Usamos RTLD_DEFAULT para resolver símbolos del espacio global del proceso.

#include <dlfcn.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

typedef int   (*init_fn_t)(void);
typedef int   (*exec_root_fn_t)(const char *, ...);
typedef char* (*get_jbroot_fn_t)(void);

/// Resuelve un símbolo en el espacio global (RTLD_DEFAULT).
/// Si no está, intenta dlopen de libjailbreak como fallback.
static void* resolve_symbol(const char *name) {
    void *sym = dlsym(RTLD_DEFAULT, name);
    if (sym) return sym;
    // Fallback: la dylib existe pero no está cargada (raro bajo Dopamine)
    static void *fallback_handle = NULL;
    if (!fallback_handle) {
        fallback_handle = dlopen("/var/jb/basebin/libjailbreak.dylib", RTLD_NOW);
        if (!fallback_handle) {
            fallback_handle = dlopen("/var/jb/usr/lib/libjailbreak.dylib", RTLD_NOW);
        }
    }
    if (fallback_handle) {
        return dlsym(fallback_handle, name);
    }
    return NULL;
}

/// Intenta init pero no es error fatal si falla (puede estar ya inicializada por systemhook).
/// errbuf recibe info diagnóstica. Devuelve rc de init o 0 si no se encontró (asumimos pre-init).
int djb_init_libjailbreak(char *errbuf, int errbuf_len) {
    init_fn_t init = (init_fn_t)resolve_symbol("jbclient_initialize_primitives");
    if (!init) {
        if (errbuf) snprintf(errbuf, errbuf_len, "jbclient_initialize_primitives no encontrada en el proceso");
        return -1;
    }
    int r = init();
    if (errbuf) snprintf(errbuf, errbuf_len, "init rc=%d (negativo = ya inicializada por systemhook, OK)", r);
    return r;
}

/// Ejecuta como root. Resuelve exec_cmd_root cada vez (barato).
/// Pasa hasta 6 args, NULL-terminated. Devuelve exit code o -901/-902 si falla setup.
int djb_exec_root_cmd(const char *path, const char *a1, const char *a2,
                      const char *a3, const char *a4, const char *a5, const char *a6) {
    exec_root_fn_t fn = (exec_root_fn_t)resolve_symbol("exec_cmd_root");
    if (!fn) return -902;

    if (a1 == NULL) return fn(path, NULL);
    if (a2 == NULL) return fn(path, a1, NULL);
    if (a3 == NULL) return fn(path, a1, a2, NULL);
    if (a4 == NULL) return fn(path, a1, a2, a3, NULL);
    if (a5 == NULL) return fn(path, a1, a2, a3, a4, NULL);
    if (a6 == NULL) return fn(path, a1, a2, a3, a4, a5, NULL);
    return fn(path, a1, a2, a3, a4, a5, a6, NULL);
}

/// Devuelve el jbroot ("/var/jb") o NULL.
const char* djb_jbroot(void) {
    get_jbroot_fn_t fn = (get_jbroot_fn_t)resolve_symbol("jbclient_get_jbroot");
    if (!fn) return NULL;
    return fn();
}

/// Chequeo barato: ¿existe libjailbreak.dylib en disco?
int djb_libjailbreak_available(void) {
    if (access("/var/jb/basebin/libjailbreak.dylib", R_OK) == 0) return 1;
    if (access("/var/jb/usr/lib/libjailbreak.dylib", R_OK) == 0) return 1;
    return 0;
}

/// Chequeo: ¿está exec_cmd_root resuelta en nuestro proceso ahora mismo?
/// Devuelve 1 si sí, 0 si no (en diagnóstico ayuda a saber si systemhook la cargó).
int djb_exec_cmd_root_available(void) {
    return dlsym(RTLD_DEFAULT, "exec_cmd_root") != NULL ? 1 : 0;
}
