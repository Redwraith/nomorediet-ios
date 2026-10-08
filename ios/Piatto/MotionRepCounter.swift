import CoreMotion
import SwiftUI

/// Counts reps with the iPhone's accelerometer and gyroscope, for any exercise the camera cannot see well.
/// The phone goes in a pocket (legs), in an armband (arms) or on the weight stack of a machine.
/// Vertical acceleration (along gravity) is integrated twice into a displacement with drift removed
/// (high-pass filters), and one rep is one full up-and-down cycle of that displacement, with a threshold
/// that adapts to the size of the movement.
final class MotionRepEngine: ObservableObject {
    @Published private(set) var reps = 0
    @Published private(set) var level = 0.0
    @Published private(set) var running = false
    @Published private(set) var available = CMMotionManager().isDeviceMotionAvailable

    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private var detector = RepDetector()

    func start() {
        guard manager.isDeviceMotionAvailable, !running else { return }
        detector = RepDetector()
        reps = 0
        running = true
        manager.deviceMotionUpdateInterval = 1.0 / 50
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let a = motion.userAcceleration, g = motion.gravity
            // acceleration along gravity, m/s² (positive = up)
            let vertical = -(a.x * g.x + a.y * g.y + a.z * g.z) * 9.81
            let counted = self.detector.add(vertical, dt: 1.0 / 50)
            let position = self.detector.position
            DispatchQueue.main.async {
                self.level = position
                if counted {
                    self.reps += 1
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                }
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        running = false
    }
}

/// Pure signal processing, testable without sensors. Band-pass (0.16–1.2 Hz) the vertical acceleration,
/// then one rep = the filtered signal swinging below −threshold and back above +threshold. The threshold
/// follows 45% of the recent peak (at least 0.12 m/s²), and two reps must be at least 0.8 s apart
/// (or 60% of the typical interval), so pauses and jitters are not counted.
struct RepDetector {
    /// Filtered acceleration, for the live bar.
    private(set) var position = 0.0
    private var previous = 0.0
    private var highPass = 0.0
    private var lowPass1 = 0.0
    private var armed = false
    private var amplitude = 0.3
    private var sinceLast = 0.0
    private var warmup = 0.0
    private var intervals: [Double] = []
    private var count = 0

    /// Adds one sample (m/s², positive up); returns true when a rep completes.
    mutating func add(_ acceleration: Double, dt: Double) -> Bool {
        highPass = 0.995 * (highPass + acceleration - previous)
        previous = acceleration
        let k = 1 - exp(-2 * Double.pi * 1.2 * dt)
        lowPass1 += k * (highPass - lowPass1)
        position += k * (lowPass1 - position)
        sinceLast += dt
        warmup += dt
        guard warmup > 1 else { return false }
        amplitude = max(abs(position), amplitude * 0.998)
        let threshold = max(0.12, amplitude * 0.45)
        let typical = intervals.count >= 2 ? intervals.sorted()[intervals.count / 2] : 0
        if !armed && position < -threshold { armed = true }
        if armed && position > threshold && sinceLast > max(0.8, typical * 0.6) {
            armed = false
            if count > 0 { intervals.append(sinceLast); if intervals.count > 6 { intervals.removeFirst() } }
            sinceLast = 0
            count += 1
            return true
        }
        return false
    }
}

struct MotionRepCounterView: View {
    var exercise: String
    var target: Int
    var done: (Int?) -> Void
    @StateObject private var engine = MotionRepEngine()

    private var tip: String {
        let n = FoodDatabase.normalize(exercise)
        if ["squat", "affond", "stacc", "hip thrust", "calf", "step", "leg press", "bridge"].contains(where: n.contains) {
            return "Metti l'iPhone nella tasca dei pantaloni, schermo verso la gamba."
        }
        if ["curl", "alzat", "lento", "press", "french", "estension", "push"].contains(where: n.contains) && !n.contains("leg") {
            return "Tieni l'iPhone in una fascia da braccio sull'avambraccio che lavora, oppure in mano se l'esercizio lo permette."
        }
        return "Appoggia l'iPhone sul pacco pesi della macchina (si muove insieme al peso), oppure mettilo in tasca."
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text(exercise).font(.title3.bold()).multilineTextAlignment(.center)
                Text(tip).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text("\(engine.reps)")
                    .font(.system(size: 120, weight: .heavy, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: engine.reps)
                // live movement bar
                GeometryReader { geo in
                    let x = max(-1, min(1, engine.level / 1.5))
                    ZStack {
                        Capsule().fill(Color.secondary.opacity(0.2))
                        Circle().fill(Theme.accent).frame(width: 22)
                            .offset(x: x * (geo.size.width / 2 - 11))
                    }
                }
                .frame(height: 22)
                .padding(.horizontal, 30)
                if target > 0 { Text("Obiettivo: \(target) ripetizioni").foregroundStyle(.secondary) }
                if !engine.available { Text("Sensori di movimento non disponibili.").foregroundStyle(.red) }
                Spacer()
                HStack(spacing: 12) {
                    Button(engine.running ? "Ricomincia" : "Inizia") { engine.stop(); engine.start() }
                        .buttonStyle(.bordered).controlSize(.large)
                    Button("Fine serie") { engine.stop(); done(engine.reps) }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(engine.reps == 0)
                }
            }
            .padding(24)
            .navigationTitle("Conta con i sensori")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annulla") { engine.stop(); done(nil) } } }
            .onAppear { UIApplication.shared.isIdleTimerDisabled = true; engine.start() }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false; engine.stop() }
        }
    }
}
