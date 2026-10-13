import SwiftUI
import AppKit
import ApplicationServices

struct FileTarget: Identifiable {
    let id = UUID()
    let url: URL
    let point: CGPoint
    var swallowed = false
}

@MainActor
final class RobotViewModel: ObservableObject {
    @Published var position: CGPoint? = nil   // nil = pencerenin ortası (boşta)
    @Published var angle: Double = 0
    @Published var isCleaning = false
    @Published var message = ""
    @Published var trail: [CGPoint] = []      // robotun izi (köşe noktaları)
    @Published var targets: [FileTarget] = []
    @Published var swallowedCount = 0
    @Published var chomp = false

    var home: CGPoint = .zero
    var canvasSize: CGSize = .zero
    var customDestination: URL?

    var expand: (() -> Void)?
    var collapse: (() -> Void)?

    private let fm = FileManager.default
    private var destination: URL?
    private var unknownCount = 0

    // Ayarlar: istediğiniz gibi değiştirebilirsiniz
    private let speed: CGFloat = 330          // piksel/saniye (küçültürseniz daha yavaş olur)
    private let turnSpeed: Double = 220       // derece/saniye
    private let laneWidth: CGFloat = 70       // şeritler arası mesafe
    private let swallowRadius: CGFloat = 44   // yutma mesafesi

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

    // MARK: - Finder'dan ikon konumları

    /// İkon konumlarını bulur: önce .DS_Store (izin gerektirmez), sonra Finder (izin varsa, daha taze).
    private func fetchIconPositions(files: [URL]) -> (positions: [String: CGPoint], error: String?) {
        let ds = positionsFromDSStore(files: files)
        var positions = ds.positions

        let f = positionsFromFinder()
        for (k, v) in f.positions { positions[k] = v }   // Finder'ın verdiği öncelikli

        if positions.isEmpty {
            if f.denied, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                NSWorkspace.shared.open(url)
            }
            let msg = (f.error ?? "İkon konumları okunamadı.") + "\n.DS_Store: " + ds.info
            return ([:], msg)
        }
        return (positions, nil)
    }

    /// Masaüstünün .DS_Store dosyasından 'Iloc' (ikon konumu) kayıtlarını okur.
    private func positionsFromDSStore(files: [URL]) -> (positions: [String: CGPoint], info: String) {
        let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let path = desktop.appendingPathComponent(".DS_Store")
        guard let data = try? Data(contentsOf: path) else { return ([:], "okunamadı veya yok") }

        func be32(_ off: Int) -> Int32 {
            let b = [UInt8](data[off..<off + 4])
            return Int32(bitPattern: UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        }

        var result: [String: CGPoint] = [:]
        for url in files {
            let name = url.lastPathComponent
            let variants = [name.precomposedStringWithCanonicalMapping, name.decomposedStringWithCanonicalMapping]
            for variant in variants {
                let u16 = Array(variant.utf16)
                var pattern = Data()
                let n = UInt32(u16.count)
                pattern.append(contentsOf: [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF),
                                            UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
                for u in u16 { pattern.append(UInt8(u >> 8)); pattern.append(UInt8(u & 0xFF)) }
                pattern.append(contentsOf: Array("Iloc".utf8))
                pattern.append(contentsOf: Array("blob".utf8))
                pattern.append(contentsOf: [0, 0, 0, 16])

                if let r = data.range(of: pattern) {
                    let o = r.upperBound
                    if o + 8 <= data.count {
                        let x = Double(be32(o)), y = Double(be32(o + 4))
                        result[name.precomposedStringWithCanonicalMapping] = CGPoint(x: x, y: y)
                        break
                    }
                }
            }
        }
        return (result, "\(data.count) bayt, \(result.count)/\(files.count) dosya eşleşti")
    }

    /// Finder'a AppleScript ile sorar (Otomasyon izni gerekir).
    private func positionsFromFinder() -> (positions: [String: CGPoint], error: String?, denied: Bool) {
        let permissionHelp = "Konumlar okunamadı. Finder izni de verilmemiş: açılan Ayarlar'da Gizlilik ve Güvenlik › Otomasyon bölümünden RobotSupurge için Finder'ı açın."

        let finder = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        let status = AEDeterminePermissionToAutomateTarget(finder.aeDesc, typeWildCard, typeWildCard, true)
        if status == -1743 { return ([:], permissionHelp, true) }

        let src = """
        tell application "Finder"
            set out to {}
            set total to count of items of desktop
            repeat with k from 1 to total
                try
                    set theItem to item k of desktop
                    set nm to name of theItem
                    set pos to desktop position of theItem
                    set end of out to {nm, pos}
                on error errMsg
                    set end of out to {"__ERR__", errMsg}
                end try
            end repeat
            return out
        end tell
        """
        var result: [String: CGPoint] = [:]
        var err: NSDictionary?
        guard let script = NSAppleScript(source: src) else { return ([:], "AppleScript oluşturulamadı.", false) }
        let d = script.executeAndReturnError(&err)
        if let err {
            let num = (err["NSAppleScriptErrorNumber"] as? Int) ?? 0
            let msg = (err["NSAppleScriptErrorMessage"] as? String) ?? "bilinmeyen hata"
            if num == -1743 { return ([:], permissionHelp, true) }
            return ([:], "Finder'dan konumlar alınamadı (hata \(num)): \(msg)", false)
        }

        var firstErr: String? = nil
        let total = d.numberOfItems
        if total > 0 {
            for i in 1...total {
                guard let pair = d.atIndex(i), pair.numberOfItems >= 2 else { continue }
                let first = pair.atIndex(1)?.stringValue ?? ""
                if first == "__ERR__" {
                    if firstErr == nil { firstErr = pair.atIndex(2)?.stringValue }
                    continue
                }
                guard let posD = pair.atIndex(2), posD.numberOfItems >= 2,
                      let xi = posD.atIndex(1), let yi = posD.atIndex(2) else { continue }
                result[first.precomposedStringWithCanonicalMapping] =
                    CGPoint(x: Double(xi.int32Value), y: Double(yi.int32Value))
            }
        }

        if result.isEmpty {
            let detail = firstErr ?? (total == 0 ? "Finder masaüstünde öğe görmüyor" : "konum verisi çözülemedi")
            return ([:], "Finder konum vermedi (\(total) öğe). Neden: \(detail)\nİpucu: Masaüstünde sağ tık › 'Yığınları Kullan' açıksa kapatın.", false)
        }
        return (result, nil, false)
    }

    /// Finder konum veremezse kullanılan tahmini ızgara (sağdan sola sütunlar)
    private func estimatedPoint(_ i: Int) -> CGPoint {
        let rows = max(1, Int((canvasSize.height - 120) / 100))
        let col = i / rows, row = i % rows
        return CGPoint(x: canvasSize.width - 70 - CGFloat(col) * 100,
                       y: 90 + CGFloat(row) * 100)
    }

    /// Hiçbir şey taşınmadıysa az önce oluşturulan boş tarihli klasörü sil
    private func discardEmptyDestination(_ url: URL) {
        guard customDestination == nil else { return }
        if (try? fm.contentsOfDirectory(atPath: url.path))?.isEmpty == true {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - Temizlik

    func startCleaning() async {
        guard !isCleaning else { return }
        isCleaning = true

        let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let dest: URL
        do { dest = try makeDestination() } catch {
            print("Klasör oluşturulamadı: \(error)")
            isCleaning = false
            return
        }
        destination = dest

        let files = ((try? fm.contentsOfDirectory(at: desktop,
                                                  includingPropertiesForKeys: nil,
                                                  options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.standardizedFileURL != dest.standardizedFileURL }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        var iconPositions: [String: CGPoint] = [:]
        var fetchError: String? = nil
        if !files.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
            let r = fetchIconPositions(files: files)
            iconPositions = r.positions
            fetchError = r.error
        }

        expand?()
        try? await Task.sleep(nanoseconds: 200_000_000)
        position = home
        trail = [home]

        if files.isEmpty {
            message = "Masaüstü zaten tertemiz ✨"
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            finish()
            return
        }

        if let fetchError {
            discardEmptyDestination(dest)
            message = fetchError
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            finish()
            return
        }

        // Yalnızca ikon konumu bilinen dosyalar hedeflenir (tahmin yok)
        let known: [FileTarget] = files.compactMap { url in
            let key = url.lastPathComponent.precomposedStringWithCanonicalMapping
            guard let p = iconPositions[key] else { return nil }
            return FileTarget(url: url, point: p)
        }
        unknownCount = files.count - known.count

        if known.isEmpty {
            discardEmptyDestination(dest)
            message = "Dosya adları Finder'daki konumlarla eşleşmedi (\(iconPositions.count) konum geldi, \(files.count) dosya var)."
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            finish()
            return
        }
        targets = known
        swallowedCount = 0

        // 1) Yılan gibi tarama
        for wp in sweepWaypoints() {
            await travel(to: wp)
            trail.append(wp)
        }

        // 2) Şeritlerin dışında kalan olursa doğrudan o dosyaya git
        for i in targets.indices where !targets[i].swallowed {
            let p = targets[i].point
            await travel(to: p)
            trail.append(p)
        }

        // 3) Eve dön
        await travel(to: home)
        trail.append(home)

        var done = "\(swallowedCount) dosya yutuldu ✨"
        if unknownCount > 0 { done += "\n(\(unknownCount) dosyanın yeri bulunamadı, dokunulmadı)" }
        message = done
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        finish()
    }

    private func finish() {
        message = ""
        collapse?()
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            position = nil
            angle = 0
            trail = []
            targets = []
            swallowedCount = 0
        }
        isCleaning = false
    }

    // MARK: - Tarama rotası (boustrophedon / yılan)

    private func sweepWaypoints() -> [CGPoint] {
        let pts = targets.map { $0.point }
        guard !pts.isEmpty else { return [] }
        let margin: CGFloat = 50

        let minX = max(60, pts.map(\.x).min()! - margin)
        let maxX = min(canvasSize.width - 50, pts.map(\.x).max()! + margin)
        let top = max(90, pts.map(\.y).min()! - margin)
        let bottom = min(canvasSize.height - 60, pts.map(\.y).max()! + margin)

        var xs = Array(stride(from: maxX, through: minX, by: -laneWidth))
        if let last = xs.last, last > minX + 20 { xs.append(minX) }
        if xs.isEmpty { xs = [maxX] }

        var wps: [CGPoint] = []
        var down = true
        for x in xs {
            if down { wps += [CGPoint(x: x, y: top), CGPoint(x: x, y: bottom)] }
            else    { wps += [CGPoint(x: x, y: bottom), CGPoint(x: x, y: top)] }
            down.toggle()
        }
        return wps
    }

    // MARK: - Hareket

    private func travel(to point: CGPoint) async {
        var pos = position ?? home
        let dx = point.x - pos.x, dy = point.y - pos.y
        guard hypot(dx, dy) > 1 else { return }

        let heading: Double = Double(atan2(Double(dx), Double(-dy))) * 180.0 / Double.pi   // yukarı = 0°
        await rotate(to: heading)

        var last = Date()
        while true {
            try? await Task.sleep(nanoseconds: 16_000_000)
            let now = Date()
            let dt = min(now.timeIntervalSince(last), 0.05)
            last = now

            let rx = point.x - pos.x, ry = point.y - pos.y
            let remaining = hypot(rx, ry)
            let step = speed * CGFloat(dt)

            if remaining <= step {
                pos = point
                position = pos
                _ = await swallowIfNeeded(at: pos)
                break
            }
            pos.x += rx / remaining * step
            pos.y += ry / remaining * step
            position = pos

            if await swallowIfNeeded(at: pos) { last = Date() }
        }
    }

    private func rotate(to desired: Double) async {
        var remaining = (desired - angle).truncatingRemainder(dividingBy: 360)
        if remaining > 180 { remaining -= 360 }
        if remaining < -180 { remaining += 360 }

        var last = Date()
        while abs(remaining) > 0.5 {
            try? await Task.sleep(nanoseconds: 16_000_000)
            let now = Date()
            let dt = min(now.timeIntervalSince(last), 0.05)
            last = now
            let step = min(abs(remaining), turnSpeed * dt)
            let signed = remaining > 0 ? step : -step
            angle += signed
            remaining -= signed
        }
    }

    // MARK: - Yutma: sadece robotun tam üstünde olduğu dosya

    private func swallowIfNeeded(at p: CGPoint) async -> Bool {
        var ate = false
        for i in targets.indices where !targets[i].swallowed {
            let t = targets[i]
            if hypot(t.point.x - p.x, t.point.y - p.y) < swallowRadius {
                targets[i].swallowed = true
                if let dest = destination, move(t.url, to: dest) { swallowedCount += 1 }
                ate = true
            }
        }
        if ate {
            chomp = true
            try? await Task.sleep(nanoseconds: 180_000_000)
            chomp = false
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return ate
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
