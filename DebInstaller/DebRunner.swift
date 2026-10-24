//
//  DebRunner.swift
//  v0.1.6 — flujo correcto para apps sideloaded:
//   1. process_checkin con jbd
//   2. dopamine_get_root → nos convertimos en uid=0 real
//   3. posix_spawn de dpkg (ya como root, sandbox nos deja)
//   4. captura stdout+stderr vía pipe
//   5. dopamine_drop_root al terminar
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

    static func installDeb(from inputURL: URL) -> Result {
        var trace: [String] = []
        func t(_ s: String) { trace.append(s) }

        t("➜ installDeb v0.1.6 — vía get_root + posix_spawn")
        t("  source: \(inputURL.path)")
        t("  uid actual (antes): \(djb_current_uid()) euid: \(djb_current_euid())")

        let needsScope = inputURL.startAccessingSecurityScopedResource()
        defer { if needsScope { inputURL.stopAccessingSecurityScopedResource() } }

        guard let dpkg = findDpkg() else {
            t("❌ dpkg no encontrado")
            return Result(exitCode: -800, combinedLog: trace.joined(separator: "\n"))
        }
        t("  dpkg: \(dpkg)")

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let staging = docs.appendingPathComponent("to_install.deb")
        try? FileManager.default.removeItem(at: staging)
        do {
            try FileManager.default.copyItem(at: inputURL, to: staging)
            t("✅ staging: \(staging.path)")
        } catch {
            t("❌ copyItem: \(error.localizedDescription)")
            return Result(exitCode: -801, combinedLog: trace.joined(separator: "\n"))
        }

        // 1. Init libjailbreak (puede fallar, es OK)
        var ibuf = [CChar](repeating: 0, count: 256)
        let initRc = ibuf.withUnsafeMutableBufferPointer { djb_init_libjailbreak($0.baseAddress, Int32($0.count)) }
        t("  init libjailbreak: rc=\(initRc) (negativo = ya init'd por systemhook)")

        // 2. Process checkin con jbd
        let checkinRc = djb_process_checkin()
        t("  jbclient_process_checkin: rc=\(checkinRc)")

        // 3. Pedir root
        let rootRc = djb_dopamine_get_root()
        t("  jbclient_dopamine_get_root: rc=\(rootRc)")
        t("  uid después de get_root: \(djb_current_uid()) euid: \(djb_current_euid())")

        if rootRc != 0 && djb_current_euid() != 0 {
            t("❌ No pude obtener root. jbd rechazó la petición.")
            t("   Posible causa: la app no está en el trust cache de jbd.")
            t("   Puede ser necesario llamar jbclient_root_trustcache_add_cdhash primero.")
        }

        // 4. posix_spawn de dpkg
        t("")
        t("--- posix_spawn: \(dpkg) -i \(staging.path) ---")
        var outBuf = [CChar](repeating: 0, count: 16384)
        var spawnErr: Int32 = 0
        let exitCode = outBuf.withUnsafeMutableBufferPointer { bp -> Int32 in
            djb_dpkg_install(dpkg, staging.path, bp.baseAddress, Int32(bp.count), &spawnErr)
        }
        let output = String(cString: outBuf)
        t("  exit code: \(exitCode)")
        if spawnErr != 0 {
            t("  spawn errno: \(spawnErr) (\(String(cString: strerror(spawnErr))))")
        }
        if !output.isEmpty {
            t("--- dpkg output ---")
            t(output)
            t("--- end ---")
        } else {
            t("  (sin output)")
        }

        // 5. Drop root
        let dropRc = djb_dopamine_drop_root()
        t("  drop_root: rc=\(dropRc)")
        t("  uid final: \(djb_current_uid()) euid: \(djb_current_euid())")

        // Cleanup
        try? FileManager.default.removeItem(atPath: staging.path)

        return Result(exitCode: exitCode, combinedLog: trace.joined(separator: "\n"))
    }

    static func systemInfo() -> String {
        var lines: [String] = []
        lines.append("=== DebInstaller \(AppVersion.display) — info sistema ===")
        lines.append("iOS: \(UIDevice.current.systemVersion)")
        lines.append("Device: \(UIDevice.current.model)")
        lines.append("Bundle: \(Bundle.main.bundleIdentifier ?? "?")")
        lines.append("uid: \(djb_current_uid()) euid: \(djb_current_euid())")
        lines.append("")

        lines.append("=== dpkg ===")
        for p in dpkgCandidates {
            lines.append("\(FileManager.default.fileExists(atPath: p) ? "✅" : "❌") \(p)")
        }
        lines.append("")

        lines.append("=== /var/jb ===")
        if let items = try? FileManager.default.contentsOfDirectory(atPath: "/var/jb") {
            lines.append("Contenido: \(items.sorted().joined(separator: ", "))")
        }
        lines.append("")

        lines.append("=== libjailbreak ===")
        lines.append("\(djb_libjailbreak_available() == 1 ? "✅" : "❌") /var/jb/basebin/libjailbreak.dylib")
        let avail = djb_exec_cmd_root_available() == 1
        lines.append("\(avail ? "✅" : "❌") exec_cmd_root resuelta")
        if let jb = djb_jbroot() { lines.append("jbroot: \(String(cString: jb))") }
        lines.append("")

        lines.append("=== dylibs del jailbreak inyectadas ===")
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
