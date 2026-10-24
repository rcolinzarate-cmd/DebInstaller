//
//  DebRunner.swift
//  v0.1.1 — usa libjailbreak.dylib (exec_cmd_root) en vez de posix_spawn.
//           La sandbox iOS bloquea posix_spawn aunque haya jailbreak; hay que ir
//           vía jbd (jailbreakd) con las funciones de libjailbreak de Dopamine.
//

import Foundation
import Darwin
import UIKit
import MachO

enum DebRunner {

    static let dpkgCandidates = [
        "/var/jb/usr/bin/dpkg",
        "/var/jb/usr/local/bin/dpkg",
    ]

    static func findDpkg() -> String? {
        for p in dpkgCandidates where FileManager.default.fileExists(atPath: p) { return p }
        return nil
    }

    struct Result {
        let exitCode: Int32
        let combinedLog: String
        var ok: Bool { exitCode == 0 }
    }

    /// Instala un .deb vía exec_cmd_root → dpkg.
    /// Redirige stdout/stderr de dpkg a un archivo en /var/jb/tmp/ (escribible por root)
    /// y luego lee ese archivo desde la app (que SÍ puede leer /var/jb/...).
    static func installDeb(from url: URL) -> Result {
        guard let dpkg = findDpkg() else {
            return Result(exitCode: -800, combinedLog: "❌ dpkg no encontrado en /var/jb/usr/bin/ ni /var/jb/usr/local/bin/")
        }

        // 1. Verificar que exec_cmd_root esté resuelta (via systemhook o fallback dlopen)
        //    No llamamos init si no es necesario — systemhook ya la inicializó
        if djb_exec_cmd_root_available() == 0 {
            // Intentar init como último recurso
            var errbuf = [CChar](repeating: 0, count: 512)
            _ = errbuf.withUnsafeMutableBufferPointer { bp in
                djb_init_libjailbreak(bp.baseAddress, Int32(bp.count))
            }
            if djb_exec_cmd_root_available() == 0 {
                return Result(exitCode: -800,
                              combinedLog: "❌ exec_cmd_root no está disponible en el proceso. systemhook no inyectado o libjailbreak no cargada.")
            }
        }

        // 2. Copiar el .deb a /var/jb/tmp/ (dpkg lo lee desde ahí sin problemas sandbox)
        let timestamp = Int(Date().timeIntervalSince1970)
        let debName = url.lastPathComponent.replacingOccurrences(of: " ", with: "_")
        let targetPath = "/var/jb/tmp/debinst_\(timestamp)_\(debName)"
        do {
            if FileManager.default.fileExists(atPath: targetPath) {
                // Nos interesa limpiar previos del app para no crecer /var/jb/tmp
                try? FileManager.default.removeItem(atPath: targetPath)
            }
            // La app SÍ puede escribir a /var/jb/tmp si el jbroot está mounted con permisos
            try FileManager.default.copyItem(atPath: url.path, toPath: targetPath)
        } catch {
            // Si no, lo copiamos vía exec_cmd_root cp
            let srcQuoted = url.path
            let rc = djb_exec_root_cmd("/var/jb/bin/cp", srcQuoted, targetPath, nil, nil, nil, nil)
            if rc != 0 {
                return Result(exitCode: Int32(rc),
                              combinedLog: "❌ No pude copiar .deb a /var/jb/tmp (rc=\(rc)): \(error.localizedDescription)")
            }
        }

        // 3. Ejecutar dpkg -i <path> con stdout+stderr capturados en log
        let logPath = "/var/jb/tmp/debinst_\(timestamp).log"

        // Como exec_cmd_root no captura stdout, usamos sh -c "dpkg ... > logfile 2>&1"
        let sh = "/var/jb/bin/sh"
        let shellCmd = "\"\(dpkg)\" -i \"\(targetPath)\" > \"\(logPath)\" 2>&1"
        let rc = djb_exec_root_cmd(sh, "-c", shellCmd, nil, nil, nil, nil)

        // 4. Leer el log
        var log = "exec_cmd_root returned: \(rc)\n"
        if let logData = try? Data(contentsOf: URL(fileURLWithPath: logPath)),
           let logStr = String(data: logData, encoding: .utf8) {
            log += "\n--- dpkg output ---\n\(logStr)"
        } else {
            log += "\n(no se pudo leer el log en \(logPath) — probable que la app no tenga permisos de lectura ahí)"
        }

        // Limpiar
        _ = djb_exec_root_cmd("/var/jb/bin/rm", "-f", targetPath, logPath, nil, nil, nil)

        return Result(exitCode: Int32(rc), combinedLog: log)
    }

    /// Diagnóstico ampliado: incluye dylibs cargadas en el proceso para ver si systemhook está inyectado.
    static func systemInfo() -> String {
        var lines: [String] = []
        lines.append("=== DebInstaller \(AppVersion.display) — info sistema ===")
        lines.append("iOS: \(UIDevice.current.systemVersion)")
        lines.append("Device: \(UIDevice.current.model)")
        lines.append("Bundle: \(Bundle.main.bundleIdentifier ?? "?")")
        lines.append("")

        lines.append("=== dpkg path ===")
        for p in dpkgCandidates {
            let ok = FileManager.default.fileExists(atPath: p)
            lines.append("\(ok ? "✅" : "❌") \(p)")
        }
        lines.append("")

        lines.append("=== /var/jb accesible? ===")
        let jbRoot = "/var/jb"
        if FileManager.default.fileExists(atPath: jbRoot) {
            lines.append("✅ \(jbRoot) existe")
            if let items = try? FileManager.default.contentsOfDirectory(atPath: jbRoot) {
                lines.append("Contenido: \(items.prefix(10).joined(separator: ", "))")
            }
        } else {
            lines.append("❌ \(jbRoot) NO existe — no hay jailbreak Dopamine activo")
        }
        lines.append("")

        lines.append("=== libjailbreak.dylib ===")
        let hasLj = djb_libjailbreak_available() == 1
        lines.append("\(hasLj ? "✅" : "❌") /var/jb/basebin/libjailbreak.dylib (en disco)")
        let hasExecRoot = djb_exec_cmd_root_available() == 1
        lines.append("\(hasExecRoot ? "✅" : "❌") exec_cmd_root resuelta en proceso (via systemhook)")
        if hasLj && !hasExecRoot {
            // Intentar init como fallback
            var buf = [CChar](repeating: 0, count: 512)
            let r = buf.withUnsafeMutableBufferPointer { bp in
                djb_init_libjailbreak(bp.baseAddress, Int32(bp.count))
            }
            lines.append("init libjailbreak intentado: rc=\(r) — \(String(cString: buf))")
            if djb_exec_cmd_root_available() == 1 {
                lines.append("✅ exec_cmd_root ahora disponible tras fallback dlopen")
            }
        }
        if let jb = djb_jbroot() {
            lines.append("jbroot reportado: \(String(cString: jb))")
        }
        lines.append("")

        lines.append("=== dylibs inyectadas (buscar systemhook!) ===")
        let count = _dyld_image_count()
        var hits: [String] = []
        for i in 0..<count {
            if let cstr = _dyld_get_image_name(i) {
                let p = String(cString: cstr)
                if p.contains("jb/") || p.contains("dopamine") || p.contains("systemhook") || p.contains("ellekit") || p.contains("basebin") {
                    hits.append(p)
                }
            }
        }
        if hits.isEmpty {
            lines.append("⚠ NINGÚN dylib del jailbreak inyectado en esta app!")
            lines.append("  (systemhook debería aparecer si Dopamine está inyectando)")
        } else {
            for h in hits { lines.append("✅ \(h)") }
        }

        return lines.joined(separator: "\n")
    }
}
