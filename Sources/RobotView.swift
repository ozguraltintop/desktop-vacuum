import SwiftUI

struct RobotView: View {
    @ObservedObject var vm: RobotViewModel

    var body: some View {
        GeometryReader { geo in
            let pos = vm.position ?? CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

            ZStack {
                RobotBody(active: vm.isCleaning)
                    .frame(width: 76, height: 76)
                    .rotationEffect(.degrees(vm.angle))
                    .scaleEffect(vm.chomp ? 1.22 : 1.0)
                    .animation(.spring(response: 0.18, dampingFraction: 0.45), value: vm.chomp)
                    .position(pos)
                    .onTapGesture {
                        Task { await vm.startCleaning() }
                    }

                if !vm.message.isEmpty {
                    Text(vm.message)
                        .font(.system(size: 14, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .position(x: pos.x, y: pos.y + 90)
                }
            }
        }
        .background(alignment: .topLeading) {
            if vm.isCleaning {
                TrailLayer(vm: vm).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if vm.isCleaning && !vm.targets.isEmpty {
                MiniMap(vm: vm).padding(24).allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Robotun bıraktığı iz (taranan alan)

struct TrailLayer: View {
    @ObservedObject var vm: RobotViewModel

    var body: some View {
        Canvas { ctx, _ in
            guard let first = vm.trail.first else { return }
            var path = Path()
            path.move(to: first)
            for p in vm.trail.dropFirst() { path.addLine(to: p) }
            if let pos = vm.position { path.addLine(to: pos) }

            // Taranan alan
            ctx.stroke(path, with: .color(Color.cyan.opacity(0.14)),
                       style: StrokeStyle(lineWidth: 72, lineCap: .round, lineJoin: .round))
            // Rota çizgisi
            ctx.stroke(path, with: .color(Color.cyan.opacity(0.55)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [6, 6]))
        }
    }
}

// MARK: - Mini harita

struct MiniMap: View {
    @ObservedObject var vm: RobotViewModel

    var body: some View {
        let w: CGFloat = 220
        let aspect = vm.canvasSize.height / max(vm.canvasSize.width, 1)

        VStack(alignment: .leading, spacing: 6) {
            Text("Çalışma Haritası  •  \(vm.swallowedCount)/\(vm.targets.count) dosya")
                .font(.system(size: 11, weight: .semibold))

            Canvas { ctx, size in
                let s = size.width / max(vm.canvasSize.width, 1)

                if let first = vm.trail.first {
                    var path = Path()
                    path.move(to: CGPoint(x: first.x * s, y: first.y * s))
                    for p in vm.trail.dropFirst() { path.addLine(to: CGPoint(x: p.x * s, y: p.y * s)) }
                    if let pos = vm.position { path.addLine(to: CGPoint(x: pos.x * s, y: pos.y * s)) }
                    ctx.stroke(path, with: .color(Color.cyan.opacity(0.35)),
                               style: StrokeStyle(lineWidth: 72 * s, lineCap: .round, lineJoin: .round))
                    ctx.stroke(path, with: .color(Color.cyan),
                               style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                }

                for t in vm.targets {
                    let r = CGRect(x: t.point.x * s - 3, y: t.point.y * s - 3, width: 6, height: 6)
                    ctx.fill(Path(ellipseIn: r), with: .color(t.swallowed ? .green : .orange))
                }

                if let pos = vm.position {
                    let r = CGRect(x: pos.x * s - 4, y: pos.y * s - 4, width: 8, height: 8)
                    ctx.fill(Path(ellipseIn: r), with: .color(.white))
                }
            }
            .frame(width: w, height: w * aspect)
            .background(Color.black.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Robot gövdesi

struct RobotBody: View {
    var active: Bool
    @State private var brushSpin = false

    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(0.25)).blur(radius: 6).offset(y: 4)

            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.30), Color(white: 0.12)],
                                     startPoint: .top, endPoint: .bottom))
            Circle().strokeBorder(Color(white: 0.55), lineWidth: 2)

            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.20), Color(white: 0.08)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .padding(10)

            Circle().fill(Color(white: 0.05)).frame(width: 22, height: 22)
            Circle()
                .fill(active ? Color.green : Color.cyan)
                .frame(width: 8, height: 8)
                .shadow(color: active ? .green : .cyan, radius: 4)

            // Ön sensör (robotun yüzü yukarıda)
            Capsule()
                .fill(Color.cyan.opacity(0.8))
                .frame(width: 22, height: 4)
                .offset(y: -30)

            Image(systemName: "asterisk")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.orange)
                .rotationEffect(.degrees(brushSpin ? 360 : 0))
                .offset(x: -26, y: -22)
        }
        .onChange(of: active) { _, isActive in
            if isActive {
                withAnimation(.linear(duration: 0.6).repeatForever(autoreverses: false)) { brushSpin = true }
            } else {
                withAnimation(.linear(duration: 0)) { brushSpin = false }
            }
        }
    }
}
