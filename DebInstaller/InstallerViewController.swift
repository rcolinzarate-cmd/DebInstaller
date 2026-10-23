//
//  InstallerViewController.swift
//  UI principal: picker de .deb + botón instalar + log de salida.
//

import UIKit
import UniformTypeIdentifiers

final class InstallerViewController: UIViewController, UIDocumentPickerDelegate {

    private let scrollView = UIScrollView()
    private let container = UIStackView()
    private let selectedFileLabel = UILabel()
    private let logView = UITextView()
    private var selectedDeb: URL?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "DebInstaller"
        view.backgroundColor = .systemBackground

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])

        container.axis = .vertical
        container.spacing = 12
        container.alignment = .fill
        container.distribution = .fill
        container.translatesAutoresizingMaskIntoConstraints = false
        container.layoutMargins = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        container.isLayoutMarginsRelativeArrangement = true
        scrollView.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: scrollView.topAnchor),
            container.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            container.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        let intro = UILabel()
        intro.text = "Instala paquetes .deb directo en tu jailbreak Dopamine, sin Sileo ni SSH."
        intro.numberOfLines = 0
        intro.font = .preferredFont(forTextStyle: .body)
        container.addArrangedSubview(intro)

        let pickBtn = makeButton(title: "📂 Elegir .deb de Archivos", action: #selector(pickDeb))
        container.addArrangedSubview(pickBtn)

        let embedBtn = makeButton(title: "📦 Instalar paquete embebido (si existe)", action: #selector(installEmbedded))
        container.addArrangedSubview(embedBtn)

        let urlBtn = makeButton(title: "🌐 Bajar .deb desde URL", action: #selector(installFromURL))
        container.addArrangedSubview(urlBtn)

        selectedFileLabel.text = "— ningún .deb seleccionado —"
        selectedFileLabel.font = .preferredFont(forTextStyle: .footnote)
        selectedFileLabel.textColor = .secondaryLabel
        selectedFileLabel.numberOfLines = 0
        container.addArrangedSubview(selectedFileLabel)

        let installBtn = makeButton(title: "⚙️ Instalar paquete seleccionado", action: #selector(installSelected))
        installBtn.backgroundColor = .systemGreen
        container.addArrangedSubview(installBtn)

        let diagBtn = makeButton(title: "🔍 Diagnóstico (ver si dpkg existe)", action: #selector(showDiagnostics))
        diagBtn.backgroundColor = .systemGray
        container.addArrangedSubview(diagBtn)

        let logLabel = UILabel()
        logLabel.text = "Log de salida:"
        logLabel.font = .preferredFont(forTextStyle: .caption1)
        container.addArrangedSubview(logLabel)

        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.isEditable = false
        logView.layer.borderColor = UIColor.separator.cgColor
        logView.layer.borderWidth = 1
        logView.layer.cornerRadius = 6
        logView.backgroundColor = .systemGray6
        logView.text = "Esperando acción.\n"
        logView.translatesAutoresizingMaskIntoConstraints = false
        logView.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        container.addArrangedSubview(logView)

        let footer = UILabel()
        footer.text = "v0.1.0 — rcolinzarate"
        footer.font = .preferredFont(forTextStyle: .caption2)
        footer.textColor = .tertiaryLabel
        footer.textAlignment = .center
        container.addArrangedSubview(footer)
    }

    private func makeButton(title: String, action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .preferredFont(forTextStyle: .body)
        b.contentHorizontalAlignment = .center
        b.contentEdgeInsets = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        b.backgroundColor = .systemBlue
        b.setTitleColor(.white, for: .normal)
        b.layer.cornerRadius = 8
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }

    private func log(_ s: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.logView.text = (self.logView.text ?? "") + s + "\n"
            let bottom = NSMakeRange(self.logView.text.count - 1, 1)
            self.logView.scrollRangeToVisible(bottom)
        }
    }

    @objc private func pickDeb() {
        let types: [UTType]
        if let debType = UTType(filenameExtension: "deb") {
            types = [debType, .data, .archive]
        } else {
            types = [.data, .archive]
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    @objc private func installEmbedded() {
        guard let url = Bundle.main.urls(forResourcesWithExtension: "deb", subdirectory: nil)?.first else {
            log("❌ No hay .deb embebido en el bundle de la app.")
            log("   (para embeber: pon el archivo en DebInstaller/embedded/*.deb antes de compilar)")
            return
        }
        log("📦 .deb embebido encontrado: \(url.lastPathComponent)")
        selectedDeb = url
        selectedFileLabel.text = "Seleccionado: \(url.lastPathComponent) (embebido)"
        installSelected()
    }

    @objc private func installFromURL() {
        let alert = UIAlertController(title: "Instalar desde URL", message: "Pega la URL directa al .deb", preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "https://..."
            tf.keyboardType = .URL
            tf.autocapitalizationType = .none
            tf.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancelar", style: .cancel))
        alert.addAction(UIAlertAction(title: "Bajar + Instalar", style: .default) { _ in
            guard let s = alert.textFields?.first?.text, let url = URL(string: s), url.scheme?.hasPrefix("http") == true else {
                self.log("❌ URL inválida")
                return
            }
            self.downloadAndInstall(from: url)
        })
        present(alert, animated: true)
    }

    private func downloadAndInstall(from url: URL) {
        log("🌐 Bajando: \(url.absoluteString)")
        let task = URLSession.shared.downloadTask(with: url) { [weak self] tmp, resp, err in
            guard let self = self else { return }
            if let err = err {
                self.log("❌ Error de red: \(err.localizedDescription)")
                return
            }
            guard let tmp = tmp else {
                self.log("❌ Sin archivo descargado")
                return
            }
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let fileName = url.lastPathComponent.isEmpty ? "download.deb" : url.lastPathComponent
            let dest = docs.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.moveItem(at: tmp, to: dest)
                self.log("✅ Descargado a: \(dest.path)")
                self.selectedDeb = dest
                DispatchQueue.main.async {
                    self.selectedFileLabel.text = "Seleccionado: \(dest.lastPathComponent) (de URL)"
                    self.installSelected()
                }
            } catch {
                self.log("❌ No pude mover el archivo descargado: \(error.localizedDescription)")
            }
        }
        task.resume()
    }

    @objc private func installSelected() {
        guard let deb = selectedDeb else {
            log("❌ Primero elige un .deb (botón 📂)")
            return
        }
        log("⚙️  Instalando: \(deb.lastPathComponent)")
        DispatchQueue.global().async { [weak self] in
            let result = DebRunner.installDeb(from: deb)
            self?.log("--- stdout ---")
            self?.log(result.stdout.isEmpty ? "(vacío)" : result.stdout)
            self?.log("--- stderr ---")
            self?.log(result.stderr.isEmpty ? "(vacío)" : result.stderr)
            self?.log("--- exit code: \(result.exitCode) ---")
            if result.ok {
                self?.log("✅ Instalación OK. Haz respring (Dopamine → Reiniciar SpringBoard) para activar el tweak.")
            } else {
                self?.log("❌ Instalación falló (ver stderr arriba).")
            }
        }
    }

    @objc private func showDiagnostics() {
        log(DebRunner.systemInfo())
    }

    /// Llamado por AppDelegate cuando se abre un .deb externo.
    func handleIncomingDeb(url: URL) {
        selectedDeb = url
        selectedFileLabel.text = "Seleccionado: \(url.lastPathComponent) (vía Compartir)"
        log("📥 Recibido vía Compartir: \(url.lastPathComponent)")
    }

    // MARK: - UIDocumentPickerDelegate

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        selectedDeb = url
        selectedFileLabel.text = "Seleccionado: \(url.lastPathComponent)"
        log("📂 Seleccionado: \(url.lastPathComponent)")
    }
}
