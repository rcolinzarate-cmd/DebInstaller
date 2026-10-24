//
//  DebRunner.swift
//  v0.1.5 — múltiples intentos para diagnosticar qué permite exec_cmd_root:
//   1. dpkg DIRECTO (sin shell) — más limpio, sin stdout capture
//   2. /var/jb/bin/sh (si existe)
//   3. /var/jb/usr/bin/sh
//   4. /bin/sh (de Apple, probablemente bloqueado por jbd trust cache)
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

    static let shellCandidates = [
        "/var/jb/bin/sh",
        "/var/jb/usr/bin/sh",
        "/bin/sh",
    ]

    static func findDpkg() -> String? {
        for p in dpkgCandidates where FileManager.default.fileExists(atPath: p) { return p }
        return nil
    }

    static func findShell() -> String? {
        for p in shellCandidates where FileManager.default.fileExists(atPath: p) { return p }
        return nil
    }

    struct Result {
        let exitCode: Int32
        let combinedLog: String
        var ok: Bool { exitCode == 0 }
    }

    static func installDeb(from inputURL: URL) -> Result {
        var trace: [String] = []
        func t(_ s: String) { trace.append(s) }

        t("➜ installDeb v0.1.5 iniciado")
        t("  source: \(inputURL.path)")

        let needsScope = inputURL.startAccessingSecurityScopedResource()
        defer { if needsScope { inputURL.stopAccessingSecurityScopedResource() } }
        t("  needsSecurityScope: \(needsScope)")

        guard let dpkg = findDpkg() else {
            t("❌ dpkg no encontrado")
            return Result(exitCode: -800, combinedLog: trace.joined(separator: "\n"))
        }
        t("  dpkg path: \(dpkg)")

        // Staging en Documents (sandbox lo permite)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let staging = docs.appendingPathComponent("to_install.deb")
        try? FileManager.default.removeItem(at: staging)
        do {
            try FileManager.default.copyItem(at: inputURL, to: staging)
            t("✅ copiado a staging: \(staging.path)")
            if let size = (try? FileManager.default.attributesOfItem(atPath: staging.path))?[.size] as? Int {
                t("  tamaño: \(size) bytes")
            }
        } catch {
            t("❌ copyItem falló: \(error.localizedDescription)")
            return Result(exitCode: -801, combinedLog: trace.joined(separator: "\n"))
        }

        // Chequeo exec_cmd_root
        if djb_exec_cmd_root_available() == 0 {
            var errbuf = [CChar](repeating: 0, count: 256)
            _ = errbuf.withUnsafeMutableBufferPointer { bp in
                djb_init_libjailbreak(bp.baseAddress, Int32(bp.count))
            }
            if djb_exec_cmd_root_available() == 0 {
                t("❌ exec_cmd_root no disponible: \(String(cString: errbuf))")
                return Result(exitCode: -802, combinedLog: trace.joined(separator: "\n"))
            }
        }
        t("✅ exec_cmd_root disponible")

        // ----- TEST 0: trivial — probar /var/jb/bin/true o /var/jb/usr/bin/true
        for truePath in ["/var/jb/usr/bin/true", "/var/jb/bin/true"] {
            if FileManager.default.fileExists(atPath: truePath) {
                let r = djb_exec_root_cmd(truePath, nil, nil, nil, nil, nil, nil)
                t("  test: exec \(truePath) → rc=\(r) \(r == 0 ? "✅" : "❌")")
            } else {
                t("  skip: \(truePath) no existe")
            }
        }

        // ----- INTENTO 1: dpkg DIRECTO sin shell (sin captura de output)
        t("")
        t("--- INTENTO 1: dpkg DIRECTO sin shell ---")
        t("  cmd: \(dpkg) -i \(staging.path)")
        let rc1 = djb_exec_root_cmd(dpkg, "-i", staging.path, nil, nil, nil, nil)
        t("  → rc=\(rc1) \(rc1 == 0 ? "✅ ÉXITO" : "❌ falló")")

        if rc1 == 0 {
            // Verificar que el paquete quedó instalado consultando dpkg -l
            t("")
            t("--- Verificación: paquete está instalado? ---")
            let listLog = docs.appendingPathComponent("dpkg_list.log").path
            try? FileManager.default.removeItem(atPath: listLog)
            // intento vía shell del jb si existe
            if let sh = ["/var/jb/bin/sh","/var/jb/usr/bin/sh"].first(where: { FileManager.default.fileExists(atPath: $0) }) {
                let listCmd = "\"\(dpkg)\" -l com.rcoli.siseos > \"\(listLog)\" 2>&1"
                _ = djb_exec_root_cmd(sh, "-c", listCmd, nil, nil, nil, nil)
                if let d = try? Data(contentsOf: URL(fileURLWithPath: listLog)),
                   let s = String(data: d, encoding: .utf8) {
                    t(s)
                }
            }
            try? FileManager.default.removeItem(atPath: staging.path)
            return Result(exitCode: 0, combinedLog: trace.joined(separator: "\n"))
        }

        // ----- INTENTO 2: via shell del jailbreak (uno de los candidatos)
        let logPath = docs.appendingPathComponent("dpkg_last.log").path
        for sh in shellCandidates {
            if !FileManager.default.fileExists(atPath: sh) {
                t("")
                t("--- SKIP shell: \(sh) (no existe) ---")
                continue
            }
            t("")
            t("--- INTENTO con shell: \(sh) ---")
            try? FileManager.default.removeItem(atPath: logPath)
            let cmd = "\"\(dpkg)\" -i \"\(staging.path)\" > \"\(logPath)\" 2>&1; echo __EXIT__=$? >> \"\(logPath)\""
            let rc = djb_exec_root_cmd(sh, "-c", cmd, nil, nil, nil, nil)
            t("  exec_cmd_root rc=\(rc)")
            if let d = try? Data(contentsOf: URL(fileURLWithPath: logPath)),
               let s = String(data: d, encoding: .utf8) {
                t("  === output dpkg ===")
                t(s)
                t("  === fin output ===")

                // Buscar exit real
                var realExit: Int32 = Int32(rc)
                if let m = s.range(of: "__EXIT__=") {
                    let after = s[m.upperBound...]
                    if let code = Int32(after.prefix { $0.isNumber }) { realExit = code }
                }
                if realExit == 0 {
                    try? FileManager.default.removeItem(atPath: staging.path)
                    try? FileManager.default.removeItem(atPath: logPath)
                    return Result(exitCode: 0, combinedLog: trace.joined(separator: "\n"))
                }
            } else {
                t("  (sin log — shell no escribió nada)")
            }
        }

        try? FileManager.default.removeItem(atPath: staging.path)
        return Result(exitCode: Int32(rc1), combinedLog: trace.joined(separator: "\n"))
    }

    static func systemInfo() -> String {
        var lines: [String] = []
        lines.append("=== DebInstaller \(AppVersion.display) — info sistema ===")
        lines.append("iOS: \(UIDevice.current.systemVersion)")
        lines.append("Device: \(UIDevice.current.model)")
        lines.append("Bundle: \(Bundle.main.bundleIdentifier ?? "?")")
        lines.append("")

        lines.append("=== dpkg path ===")
        for p in dpkgCandidates {
            lines.append("\(FileManager.default.fileExists(atPath: p) ? "✅" : "❌") \(p)")
        }
        lines.append("")

        lines.append("=== Shells disponibles ===")
        for p in shellCandidates {
            lines.append("\(FileManager.default.fileExists(atPath: p) ? "✅" : "❌") \(p)")
        }
        lines.append("")

        lines.append("=== Binarios root útiles ===")
        for p in ["/var/jb/usr/bin/true","/var/jb/bin/true","/var/jb/bin/ls","/var/jb/usr/bin/cat"] {
            lines.append("\(FileManager.default.fileExists(atPath: p) ? "✅" : "❌") \(p)")
        }
        lines.append("")

        lines.append("=== /var/jb accesible ===")
        if FileManager.default.fileExists(atPath: "/var/jb") {
            if let items = try? FileManager.default.contentsOfDirectory(atPath: "/var/jb") {
                lines.append("Contenido: \(items.sorted().joined(separator: ", "))")
            }
        }
        lines.append("")

        lines.append("=== libjailbreak ===")
        lines.append("\(djb_libjailbreak_available() == 1 ? "✅" : "❌") /var/jb/basebin/libjailbreak.dylib")
        let avail = djb_exec_cmd_root_available() == 1
        lines.append("\(avail ? "✅" : "❌") exec_cmd_root via RTLD_DEFAULT")
        if !avail {
            var buf = [CChar](repeating: 0, count: 256)
            let r = buf.withUnsafeMutableBufferPointer { bp in djb_init_libjailbreak(bp.baseAddress, Int32(bp.count)) }
            lines.append("init rc=\(r) — \(String(cString: buf))")
            if djb_exec_cmd_root_available() == 1 { lines.append("✅ ahora disponible tras fallback dlopen") }
        }
        if let jb = djb_jbroot() { lines.append("jbroot: \(String(cString: jb))") }
        lines.append("")

        lines.append("=== dylibs inyectadas ===")
        let n = _dyld_image_count()
        for i in 0..<n {
            if let cstr = _dyld_get_image_name(i) {
                let p = String(cString: cstr)
                if p.contains("dopamine") || p.contains("systemhook") || p.contains("ellekit") || p.contains("TweakInject") {
                    lines.append("✅ \(p)")
                }
            }
        }

        return lines.joined(separator: "\n")
    }
}
