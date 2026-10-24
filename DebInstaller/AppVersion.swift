//
//  AppVersion.swift — source of truth. Independiente de lo que haga xcodegen
//  con Info.plist. Actualizar aquí al bumpar versión.
//

import Foundation

enum AppVersion {
    static let marketing: String = "0.1.4"
    static let build: String = "5"
    static var display: String { "v\(marketing) (build \(build))" }
}
