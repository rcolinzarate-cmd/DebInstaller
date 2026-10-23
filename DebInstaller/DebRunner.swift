//
//  DebRunner.swift
//  Ejecuta dpkg/apt sobre un .deb usando los binarios del jailbreak Dopamine.
//
//  No requiere libjailbreak.dylib ni entitlements especiales — en Dopamine
//  los binarios en /var/jb/usr/bin/ corren con los privilegios heredados del
//  caller. Como la app es sideloaded sobre un sistema con systemhook inyectado,
//  posix_spawn hereda el contexto rootless y dpkg puede escribir en /var/jb/.
//

import Foundation
import Darwin
import UIKit

enum DebRunner {

    /// Rutas típicas donde Dopamine instala dpkg (rootless jailbreak).
    static let dpkgCandidates = [
        "/var/jb/usr/bin/dpkg",
        "/var/jb/usr/local/bin/dpkg",
        "/usr/bin/dpkg"
    ]

    static func findDpkg() -> String? {
        for p in dpkgCandidates {
            if FileManager.default.fileExists(atPath: p) {
                return p
            }
        }
        return nil
    }

    /// Resultado estructurado de una invocación.
    struct Result {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        var ok: Bool { exitCode == 0 }
    }

    /// Ejecuta un comando capturando stdout+stderr. Hereda env.
    static func run(_ binary: String, args: [String], timeoutSec: Int = 120) -> Result {
        let outPipe = Pipe()
        let errPipe = Pipe()

        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(binary)]
        for a in args { argv.append(strdup(a)) }
        argv.append(nil)
        defer { for p in argv where p != nil { free(p) } }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        posix_spawn_file_actions_adddup2(&fileActions, outPipe.fileHandleForWriting.fileDescriptor, 1)
        posix_spawn_file_actions_adddup2(&fileActions, errPipe.fileHandleForWriting.fileDescriptor, 2)
        posix_spawn_file_actions_addclose(&fileActions, outPipe.fileHandleForReading.fileDescriptor)
        posix_spawn_file_actions_addclose(&fileActions, errPipe.fileHandleForReading.fileDescriptor)

        var pid: pid_t = -1
        let envp = ProcessInfo.processInfo.environment
            .map { "\($0.key)=\($0.value)" }
            .map { strdup($0) } + [nil]
        defer { for p in envp where p != nil { free(p) } }
        var mutableEnvp = envp

        let rc = posix_spawn(&pid, binary, &fileActions, nil, argv, &mutableEnvp)

        // Cerrar los extremos de escritura en el padre para que read() devuelva EOF
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()

        guard rc == 0 else {
            return Result(exitCode: -1, stdout: "",
                          stderr: "posix_spawn falló: rc=\(rc) errno=\(errno) (\(String(cString: strerror(errno))))")
        }

        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSec))

        // Leer en paralelo mientras esperamos
        let outGroup = DispatchGroup()
        var outData = Data()
        var errData = Data()
        outGroup.enter(); outGroup.enter()
        DispatchQueue.global().async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            outGroup.leave()
        }
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            outGroup.leave()
        }

        while Date() < deadline {
            let wpid = waitpid(pid, &status, WNOHANG)
            if wpid == pid { break }
            if wpid < 0 { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        outGroup.wait()

        let actualExit = (status & 0xff00) >> 8
        return Result(exitCode: Int32(actualExit),
                      stdout: String(data: outData, encoding: .utf8) ?? "",
                      stderr: String(data: errData, encoding: .utf8) ?? "")
    }

    /// Instala un .deb vía dpkg -i. El archivo debe estar en una ruta que dpkg pueda leer
    /// (no en el sandbox de la app). Copiamos a /tmp primero.
    static func installDeb(from url: URL) -> Result {
        guard let dpkg = findDpkg() else {
            return Result(exitCode: -2, stdout: "",
                          stderr: "dpkg no encontrado. Busqué en:\n" +
                                  dpkgCandidates.joined(separator: "\n") +
                                  "\n\nVerifica que tu jailbreak Dopamine esté activo y /var/jb/usr/bin/dpkg exista.")
        }

        // Copiar el .deb a /tmp donde dpkg sí puede leer (fuera del sandbox app)
        let tmpPath = "/tmp/debinstaller_\(Int(Date().timeIntervalSince1970))_\(url.lastPathComponent)"
        do {
            if FileManager.default.fileExists(atPath: tmpPath) {
                try? FileManager.default.removeItem(atPath: tmpPath)
            }
            try FileManager.default.copyItem(atPath: url.path, toPath: tmpPath)
        } catch {
            // Si /tmp no es escribible por app sandbox, intentamos otra ruta
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let fallback = docs.appendingPathComponent("to_install.deb").path
            try? FileManager.default.removeItem(atPath: fallback)
            try? FileManager.default.copyItem(atPath: url.path, toPath: fallback)
            let r = run(dpkg, args: ["-i", fallback])
            return r
        }

        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        return run(dpkg, args: ["-i", tmpPath])
    }

    /// Diagnóstico: lista información del sistema que puede ayudar a debuggear.
    static func systemInfo() -> String {
        var lines: [String] = []
        lines.append("=== DebInstaller — info sistema ===")
        lines.append("iOS: \(UIDevice.current.systemVersion)")
        lines.append("Device: \(UIDevice.current.model)")
        lines.append("Bundle: \(Bundle.main.bundleIdentifier ?? "?")")
        lines.append("")
        lines.append("=== dpkg path ===")
        for p in dpkgCandidates {
            let exists = FileManager.default.fileExists(atPath: p)
            lines.append("\(exists ? "✅" : "❌") \(p)")
        }
        lines.append("")
        lines.append("=== /var/jb accesible? ===")
        let jbRoot = "/var/jb"
        let jbExists = FileManager.default.fileExists(atPath: jbRoot)
        lines.append("\(jbExists ? "✅" : "❌") \(jbRoot) existe")
        if jbExists {
            if let items = try? FileManager.default.contentsOfDirectory(atPath: jbRoot) {
                lines.append("Contenido (primeros 10): \(items.prefix(10).joined(separator: ", "))")
            }
        }
        lines.append("")
        lines.append("=== /tmp accesible? ===")
        let tmpOK = FileManager.default.isWritableFile(atPath: "/tmp")
        lines.append("\(tmpOK ? "✅" : "❌") /tmp escribible")
        return lines.joined(separator: "\n")
    }
}
