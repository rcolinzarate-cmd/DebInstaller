// DebInstaller-Bridging-Header.h — expone jbroot_helper.c a Swift.

#ifndef DebInstaller_Bridging_Header_h
#define DebInstaller_Bridging_Header_h

#include <unistd.h>

int   djb_init_libjailbreak(char *errbuf, int errbuf_len);
int   djb_process_checkin(void);
int   djb_dopamine_get_root(void);
int   djb_dopamine_drop_root(void);

int   djb_posix_spawn_capture(const char *path, const char *const argv_in[],
                               char *captured_out, int out_max, int *spawn_errno);
int   djb_dpkg_install(const char *dpkg_path, const char *deb_path,
                        char *out_buf, int out_max, int *spawn_errno);

int   djb_exec_root_cmd(const char *path, const char *a1, const char *a2,
                         const char *a3, const char *a4, const char *a5, const char *a6);

const char* djb_jbroot(void);
int   djb_libjailbreak_available(void);
int   djb_exec_cmd_root_available(void);
int   djb_current_uid(void);
int   djb_current_euid(void);

#endif
