// jbroot_helper.c v0.1.6
// NUEVA ARQUITECTURA: en vez de usar exec_cmd_root (que requiere trust de jbd),
// usamos la cadena correcta para apps sideloaded:
//   1. jbclient_process_checkin()      — registramos la app con jbd
//   2. jbclient_dopamine_get_root()    — jbd nos otorga uid=0
//   3. posix_spawn normal              — ahora que somos root el sandbox nos deja
//   4. jbclient_dopamine_drop_root()   — bajamos privilegio
//

#include <dlfcn.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <spawn.h>
#include <errno.h>

extern char **environ;

typedef int   (*int_void_fn_t)(void);
typedef char* (*get_jbroot_fn_t)(void);
typedef int   (*exec_root_fn_t)(const char *, ...);

/// Resuelve símbolo via RTLD_DEFAULT, con fallback a dlopen libjailbreak.
static void* resolve_symbol(const char *name) {
    void *sym = dlsym(RTLD_DEFAULT, name);
    if (sym) return sym;
    static void *fallback_handle = NULL;
    if (!fallback_handle) {
        fallback_handle = dlopen("/var/jb/basebin/libjailbreak.dylib", RTLD_NOW);
    }
    if (fallback_handle) return dlsym(fallback_handle, name);
    return NULL;
}

/// Checkin con jbd. Devuelve resultado de la fn o -1 si no encontrada.
int djb_process_checkin(void) {
    int_void_fn_t fn = (int_void_fn_t)resolve_symbol("jbclient_process_checkin");
    if (!fn) return -1000;
    return fn();
}

/// Pide a jbd que nos haga root (uid=0). Devuelve 0 OK, otro = error.
int djb_dopamine_get_root(void) {
    int_void_fn_t fn = (int_void_fn_t)resolve_symbol("jbclient_dopamine_get_root");
    if (!fn) return -1001;
    return fn();
}

/// Baja privilegio.
int djb_dopamine_drop_root(void) {
    int_void_fn_t fn = (int_void_fn_t)resolve_symbol("jbclient_dopamine_drop_root");
    if (!fn) return -1002;
    return fn();
}

/// Init libjailbreak (puede retornar negativo si systemhook ya la inicializó, es OK).
int djb_init_libjailbreak(char *errbuf, int errbuf_len) {
    int_void_fn_t init = (int_void_fn_t)resolve_symbol("jbclient_initialize_primitives");
    if (!init) {
        if (errbuf) snprintf(errbuf, errbuf_len, "jbclient_initialize_primitives no encontrada");
        return -1;
    }
    int r = init();
    if (errbuf) snprintf(errbuf, errbuf_len, "rc=%d", r);
    return r;
}

/// Spawn de un proceso con posix_spawn, con stdout/stderr capturados en pipes.
/// Devuelve exit code del child (o -1 si spawn falló).
/// Si captured_out != NULL, recibe un malloc'd string con el combinado (hasta out_max bytes).
int djb_posix_spawn_capture(const char *path, const char *const argv_in[],
                             char *captured_out, int out_max,
                             int *spawn_errno) {
    int out_pipe[2];
    if (pipe(out_pipe) != 0) { if (spawn_errno) *spawn_errno = errno; return -1; }

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, out_pipe[1], 1);
    posix_spawn_file_actions_adddup2(&fa, out_pipe[1], 2);
    posix_spawn_file_actions_addclose(&fa, out_pipe[0]);
    posix_spawn_file_actions_addclose(&fa, out_pipe[1]);

    pid_t pid = -1;
    // argv_in es NULL-terminated array
    int rc = posix_spawn(&pid, path, &fa, NULL, (char *const *)argv_in, environ);
    posix_spawn_file_actions_destroy(&fa);
    close(out_pipe[1]);
    if (rc != 0) {
        if (spawn_errno) *spawn_errno = rc;
        close(out_pipe[0]);
        return -1;
    }

    // Leer output
    int total = 0;
    if (captured_out && out_max > 0) {
        while (total < out_max - 1) {
            int n = (int)read(out_pipe[0], captured_out + total, out_max - 1 - total);
            if (n <= 0) break;
            total += n;
        }
        captured_out[total] = 0;
    } else {
        // Descartar
        char buf[256];
        while (read(out_pipe[0], buf, sizeof(buf)) > 0) {}
    }
    close(out_pipe[0]);

    int status = 0;
    waitpid(pid, &status, 0);
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    return -status;
}

/// Spawn dpkg -i del paquete. Devuelve exit code (negativo = error antes de spawn).
int djb_dpkg_install(const char *dpkg_path, const char *deb_path,
                      char *out_buf, int out_max, int *spawn_errno) {
    const char *argv[] = { dpkg_path, "-i", deb_path, NULL };
    return djb_posix_spawn_capture(dpkg_path, argv, out_buf, out_max, spawn_errno);
}

/// Versión legacy — intenta vía exec_cmd_root (lo que no funcionó en v0.1.5).
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

const char* djb_jbroot(void) {
    get_jbroot_fn_t fn = (get_jbroot_fn_t)resolve_symbol("jbclient_get_jbroot");
    if (!fn) return NULL;
    return fn();
}

int djb_libjailbreak_available(void) {
    if (access("/var/jb/basebin/libjailbreak.dylib", R_OK) == 0) return 1;
    return 0;
}

int djb_exec_cmd_root_available(void) {
    return dlsym(RTLD_DEFAULT, "exec_cmd_root") != NULL ? 1 : 0;
}

/// Devuelve uid/euid actual del proceso. Útil para verificar si get_root funcionó.
int djb_current_uid(void) { return (int)getuid(); }
int djb_current_euid(void) { return (int)geteuid(); }
