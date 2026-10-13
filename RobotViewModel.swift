import SwiftUI
import AppKit

@MainActor
final class RobotViewModel: ObservableObject {
    @Published var position: CGPoint? = nil   // nil = pencerenin ortası (boşta)
    @Published var angle: Double = 0
    @Published var isCleaning = false
    @Published var message = ""

    var home: CGPoint = .zero
    var canvasSize: CGSize = .zero
    var customDestination: URL?

    var expand: (() -> Void)?
    var collapse: (() -> Void)?

    private let fm = FileManager.default

    // MARK: - Hedef klasör

    private func makeDestination() throws -> URL {
        if let custom = customDestination { return custom }
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        let url = docs
            .appendingPathComponent("Masaüstü Temizliği", isDirectory: true)
            .appendingPathComponent(f.string(from: Date()), isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Temizlik

    func startCleaning() async {
        guard !isCleaning else { return }

        let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let dest: URL
        do { dest = try makeDestination() } catch {
            print("Klasör oluşturulamadı: \(error)"); return
        }

        let files = ((try? fm.contentsOfDirectory(at: desktop,
                                                  includingPropertiesForKeys: nil,
                                                  options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.standardizedFileURL != dest.standardizedFileURL }

        isCleaning = true
        expand?()
        try? await Task.sleep(nanoseconds: 150_000_000)
        position = home

        if files.isEmpty {
            message = "Masaüstü zaten tertemiz ✨"
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            finish()
            return
        }

        var moved = 0
        for (i, file) in files.enumerated() {
            await drive(to: target(for: i))
            if move(file, to: dest) { moved += 1 }
        }

        await drive(to: home)
        message = "\(moved) dosya taşındı ✨"
        try? await Task.sleep(nanoseconds: 1_800_000_000)
        finish()
    }

    private func finish() {
        message = ""
        collapse?()
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            position = nil
            angle = 0
        }
        isCleaning = false
    }

    // MARK: - Hareket

    /// macOS masaüstü ikonları varsayılan olarak sağdan sola sütunlar halinde dizilir;
    /// robot da sağ kenardan başlayarak zigzag süpürür.
    private func target(for index: Int) -> CGPoint {
        let rows = 6
        let col = index / rows
        var row = index % rows
        if col % 2 == 1 { row = rows - 1 - row }          // zigzag
        let top: CGFloat = 140
        let bottom = canvasSize.height - 120
        let y = top + CGFloat(row) * (bottom - top) / CGFloat(rows - 1)
        let x = max(80, canvasSize.width - 90 - CGFloat(col) * 110)
        return CGPoint(x: x, y: y)
    }

    private func drive(to point: CGPoint) async {
        let from = position ?? home
        let dx = point.x - from.x
        let dy = point.y - from.y
        guard hypot(dx, dy) > 1 else { return }

        // Önce dön, sonra git
        let desired = atan2(dx, -dy) * 180 / .pi           // yukarı = 0°
        var delta = (desired - angle).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }

        withAnimation(.easeInOut(duration: 0.3)) { angle += delta }
        try? await Task.sleep(nanoseconds: 300_000_000)

        let duration = min(1.2, max(0.5, hypot(dx, dy) / 700))
        withAnimation(.easeInOut(duration: duration)) { position = point }
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    }

    // MARK: - Dosya taşıma

    @discardableResult
    private func move(_ file: URL, to folder: URL) -> Bool {
        var target = folder.appendingPathComponent(file.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            let base = file.deletingPathExtension().lastPathComponent
            let ext = file.pathExtension
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            target = folder.appendingPathComponent(name)
            n += 1
        }
        do {
            try fm.moveItem(at: file, to: target)
            return true
        } catch {
            print("Taşınamadı \(file.lastPathComponent): \(error)")
            return false
        }
    }
}
