// jbroot_helper.c
// Puente C → libjailbreak.dylib de Dopamine. Evita el problema de llamar
// funciones C variádicas desde Swift (que no es trivial).
//
// Funciones exportadas por libjailbreak.dylib que usamos:
//   int  jbclient_initialize_primitives(void);
//   int  exec_cmd_root(const char *path, ...);   // NULL-terminated varargs
//   char *jbclient_get_jbroot(void);              // devuelve "/var/jb" (o path virtual)

#include <dlfcn.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

static void *lj_handle = NULL;

typedef int  (*init_fn_t)(void);
typedef int  (*exec_root_fn_t)(const char *, ...);
typedef char* (*get_jbroot_fn_t)(void);

static const char *LIBJB_PATHS[] = {
    "/var/jb/basebin/libjailbreak.dylib",
    "/var/jb/usr/lib/libjailbreak.dylib",
    NULL
};

/// Carga libjailbreak e inicializa primitivas. Devuelve 0 OK, negativo si falla.
int djb_init_libjailbreak(char *errbuf, int errbuf_len) {
    if (lj_handle) return 0;

    for (int i = 0; LIBJB_PATHS[i] != NULL; i++) {
        lj_handle = dlopen(LIBJB_PATHS[i], RTLD_NOW);
        if (lj_handle) break;
    }
    if (!lj_handle) {
        if (errbuf) snprintf(errbuf, errbuf_len, "dlopen libjailbreak falló: %s", dlerror());
        return -1;
    }

    init_fn_t init = (init_fn_t)dlsym(lj_handle, "jbclient_initialize_primitives");
    if (!init) {
        if (errbuf) snprintf(errbuf, errbuf_len, "dlsym jbclient_initialize_primitives falló");
        return -2;
    }
    int r = init();
    if (r != 0 && errbuf) snprintf(errbuf, errbuf_len, "init devolvió %d", r);
    return r;
}

/// Ejecuta un comando como root vía exec_cmd_root. Pasa hasta 6 argumentos (NULL-terminated).
/// Devuelve el exit code del child, o -901/-902 si libjailbreak no disponible.
int djb_exec_root_cmd(const char *path, const char *a1, const char *a2,
                      const char *a3, const char *a4, const char *a5, const char *a6) {
    if (!lj_handle) {
        int r = djb_init_libjailbreak(NULL, 0);
        if (r != 0) return -901;
    }
    exec_root_fn_t fn = (exec_root_fn_t)dlsym(lj_handle, "exec_cmd_root");
    if (!fn) return -902;

    // Build argv for variadic call — NULL-terminated
    if (a1 == NULL) return fn(path, NULL);
    if (a2 == NULL) return fn(path, a1, NULL);
    if (a3 == NULL) return fn(path, a1, a2, NULL);
    if (a4 == NULL) return fn(path, a1, a2, a3, NULL);
    if (a5 == NULL) return fn(path, a1, a2, a3, a4, NULL);
    if (a6 == NULL) return fn(path, a1, a2, a3, a4, a5, NULL);
    return fn(path, a1, a2, a3, a4, a5, a6, NULL);
}

/// Devuelve el jbroot real ("/var/jb") para traducir paths. Puntero estático de libjailbreak.
const char* djb_jbroot(void) {
    if (!lj_handle) {
        if (djb_init_libjailbreak(NULL, 0) != 0) return NULL;
    }
    get_jbroot_fn_t fn = (get_jbroot_fn_t)dlsym(lj_handle, "jbclient_get_jbroot");
    if (!fn) return NULL;
    return fn();
}

/// Reporta si libjailbreak está disponible (sin llamar init). Útil para diagnóstico.
int djb_libjailbreak_available(void) {
    for (int i = 0; LIBJB_PATHS[i] != NULL; i++) {
        if (access(LIBJB_PATHS[i], R_OK) == 0) return 1;
    }
    return 0;
}
