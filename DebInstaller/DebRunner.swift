//
//  DebRunner.swift
//  v0.1.4 — arquitectura corregida:
//   - security-scoped URL para archivos del picker
//   - staging en app's Documents (sandbox nos deja escribir ahí)
//   - dpkg leyendo desde Documents via exec_cmd_root (root sí puede leer app containers)
//   - log de dpkg a Documents también (evita depender de /var/jb/tmp)
//   - usa /bin/sh de Apple (siempre existe)
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

    /// Instala un .deb. Flujo:
    /// 1. Abrir scope del URL si viene de UIDocumentPicker
    /// 2. Copiar/mover a Documents de nuestra app (fuera del tmp sandbox restringido)
    /// 3. Verificar que libjailbreak + exec_cmd_root estén disponibles
    /// 4. Spawn /bin/sh -c "dpkg -i <path> > <logfile> 2>&1" como root
    /// 5. Leer el log
    static func installDeb(from inputURL: URL) -> Result {
        var trace: [String] = []
        func t(_ s: String) { trace.append(s) }

        t("➜ installDeb v0.1.4 iniciado")
        t("  source: \(inputURL.path)")

        // 1. Security-scoped (necesario para URLs del picker)
        let needsScope = inputURL.startAccessingSecurityScopedResource()
        defer { if needsScope { inputURL.stopAccessingSecurityScopedResource() } }
        t("  needsSecurityScope: \(needsScope)")

        // 2. Verificar dpkg existe
        guard let dpkg = findDpkg() else {
            t("❌ dpkg no encontrado en /var/jb/usr/bin ni /var/jb/usr/local/bin")
            return Result(exitCode: -800, combinedLog: trace.joined(separator: "\n"))
        }
        t("  dpkg: \(dpkg)")

        // 3. Copiar a Documents de la app (escribible siempre)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let stagingName = "to_install.deb"
        let staging = docs.appendingPathComponent(stagingName)
        try? FileManager.default.removeItem(at: staging)
        do {
            try FileManager.default.copyItem(at: inputURL, to: staging)
            t("✅ copiado a staging: \(staging.path)")
            let attrs = try? FileManager.default.attributesOfItem(atPath: staging.path)
            if let size = attrs?[.size] as? Int { t("  tamaño: \(size) bytes") }
        } catch {
            t("❌ copyItem falló: \(error.localizedDescription)")
            // Fallback: usar exec_cmd_root cat para copiar (requiere source legible por root)
            let logPath = docs.appendingPathComponent("rootcp.log").path
            let shellCmd = "cat '\(inputURL.path)' > '\(staging.path)' 2>'\(logPath)'; echo \"cat_rc=$?\" >> '\(logPath)'"
            let rc = djb_exec_root_cmd("/bin/sh", "-c", shellCmd, nil, nil, nil, nil)
            t("  fallback cat via root → rc=\(rc)")
            if let logData = try? Data(contentsOf: URL(fileURLWithPath: logPath)),
               let logStr = String(data: logData, encoding: .utf8) {
                t("  cat log: \(logStr)")
            }
            if !FileManager.default.fileExists(atPath: staging.path) {
                t("❌ staging sigue sin existir — abandono")
                return Result(exitCode: -801, combinedLog: trace.joined(separator: "\n"))
            }
        }

        // 4. Verificar exec_cmd_root disponible (via fallback dlopen si hace falta)
        if djb_exec_cmd_root_available() == 0 {
            var errbuf = [CChar](repeating: 0, count: 256)
            _ = errbuf.withUnsafeMutableBufferPointer { bp in
                djb_init_libjailbreak(bp.baseAddress, Int32(bp.count))
            }
            if djb_exec_cmd_root_available() == 0 {
                t("❌ exec_cmd_root no disponible aún tras init: \(String(cString: errbuf))")
                return Result(exitCode: -802, combinedLog: trace.joined(separator: "\n"))
            }
        }
        t("✅ exec_cmd_root disponible")

        // 5. Ejecutar dpkg como root. Output a archivo en Documents (nosotros podemos leerlo).
        let logPath = docs.appendingPathComponent("dpkg_last.log").path
        try? FileManager.default.removeItem(atPath: logPath)

        // Comando shell: dpkg lee desde staging (que está en Documents de la app, legible por root)
        let shellCmd = "\"\(dpkg)\" -i \"\(staging.path)\" > \"\(logPath)\" 2>&1; echo \"__EXIT__=$?\" >> \"\(logPath)\""
        t("  cmdline: /bin/sh -c '\(shellCmd)'")

        let rc = djb_exec_root_cmd("/bin/sh", "-c", shellCmd, nil, nil, nil, nil)
        t("  exec_cmd_root returned: \(rc)")

        // 6. Leer el log de dpkg
        if let data = try? Data(contentsOf: URL(fileURLWithPath: logPath)),
           let str = String(data: data, encoding: .utf8) {
            t("")
            t("--- dpkg output ---")
            t(str)
            t("--- end dpkg ---")

            // Buscar nuestro marcador __EXIT__ para saber el exit code real de dpkg
            var dpkgExit: Int32 = Int32(rc)
            if let marker = str.range(of: "__EXIT__=") {
                let after = str[marker.upperBound...]
                let codeStr = after.prefix { $0.isNumber }
                if let code = Int32(codeStr) {
                    dpkgExit = code
                    t("Exit code real de dpkg: \(code)")
                }
            }

            // Cleanup staging
            try? FileManager.default.removeItem(atPath: staging.path)
            try? FileManager.default.removeItem(atPath: logPath)

            return Result(exitCode: dpkgExit, combinedLog: trace.joined(separator: "\n"))
        } else {
            t("⚠ no pude leer el log en \(logPath)")
            try? FileManager.default.removeItem(atPath: staging.path)
            return Result(exitCode: Int32(rc), combinedLog: trace.joined(separator: "\n"))
        }
    }

    /// Diagnóstico ampliado.
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
                lines.append("Contenido: \(items.prefix(15).joined(separator: ", "))")
            }
            // Check /var/jb/tmp existence
            let jbtmp = "/var/jb/tmp"
            lines.append("\(FileManager.default.fileExists(atPath: jbtmp) ? "✅" : "❌") \(jbtmp)")
            // Check sh binaries
            for sh in ["/bin/sh", "/var/jb/bin/sh", "/var/jb/bin/cp", "/var/jb/usr/bin/cp"] {
                lines.append("\(FileManager.default.fileExists(atPath: sh) ? "✅" : "❌") \(sh)")
            }
        }
        lines.append("")

        lines.append("=== Documents escribibles (nuestro sandbox) ===")
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        lines.append("docs: \(docs.path)")
        let testFile = docs.appendingPathComponent("write_test.tmp")
        do {
            try "test".write(to: testFile, atomically: true, encoding: .utf8)
            lines.append("✅ Documents escribible")
            try? FileManager.default.removeItem(at: testFile)
        } catch {
            lines.append("❌ Documents NO escribible: \(error.localizedDescription)")
        }
        lines.append("")

        lines.append("=== libjailbreak.dylib ===")
        let hasLj = djb_libjailbreak_available() == 1
        lines.append("\(hasLj ? "✅" : "❌") /var/jb/basebin/libjailbreak.dylib (en disco)")
        let hasExecRoot = djb_exec_cmd_root_available() == 1
        lines.append("\(hasExecRoot ? "✅" : "❌") exec_cmd_root resuelta via RTLD_DEFAULT")
        if hasLj && !hasExecRoot {
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
            lines.append("jbroot: \(String(cString: jb))")
        }
        lines.append("")

        lines.append("=== dylibs inyectadas ===")
        let count = _dyld_image_count()
        var hits: [String] = []
        for i in 0..<count {
            if let cstr = _dyld_get_image_name(i) {
                let p = String(cString: cstr)
                if p.contains("dopamine") || p.contains("systemhook") || p.contains("ellekit") || p.contains("basebin") || p.contains("TweakInject") {
                    hits.append(p)
                }
            }
        }
        if hits.isEmpty {
            lines.append("⚠ Ninguna dylib del jailbreak inyectada")
        } else {
            for h in hits { lines.append("✅ \(h)") }
        }

        return lines.joined(separator: "\n")
    }
}
