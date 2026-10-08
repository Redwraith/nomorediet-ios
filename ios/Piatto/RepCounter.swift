import AVFoundation
import simd
import UIKit
import Vision

/// Camera rep counter. Vision body pose gives one joint angle per frame — from the 3D pose when available
/// (independent of where the iPhone is placed), else from the 2D pose. The angle is median-filtered,
/// smoothed and mapped to a 0…1 "depth" (0 = top, 1 = full stretch) that calibrates itself on the user's
/// real range after the first rep. The same logic counts every exercise, flags reps that stop before the
/// lengthened position and times the lifting phase to estimate reps in reserve from the slowdown.
final class RepCounterViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    typealias J = VNHumanBodyPoseObservation.JointName
    struct Motion {
        let sides: [(J, J, J)]
        let stretch: Double
        let top: Double
        let tip: String
        /// Track the height of the first joint above the second (calf raises) instead of an angle.
        var rise = false
    }

    static func motion(for pattern: String) -> Motion? {
        let knee: [(J, J, J)] = [(.leftHip, .leftKnee, .leftAnkle), (.rightHip, .rightKnee, .rightAnkle)]
        let hip: [(J, J, J)] = [(.leftShoulder, .leftHip, .leftKnee), (.rightShoulder, .rightHip, .rightKnee)]
        let elbow: [(J, J, J)] = [(.leftShoulder, .leftElbow, .leftWrist), (.rightShoulder, .rightElbow, .rightWrist)]
        let shoulder: [(J, J, J)] = [(.leftHip, .leftShoulder, .leftElbow), (.rightHip, .rightShoulder, .rightElbow)]
        let side = "Metti l'iPhone di lato, a 2–3 metri, con tutto il corpo nell'inquadratura."
        let upper = "Metti l'iPhone di lato, con busto e braccia ben visibili."
        switch pattern {
        case "squat", "lunge": return Motion(sides: knee, stretch: 95, top: 155, tip: side)
        case "leg_ext": return Motion(sides: knee, stretch: 100, top: 160, tip: side)
        case "leg_curl": return Motion(sides: knee, stretch: 150, top: 95, tip: side)
        case "hinge": return Motion(sides: hip, stretch: 110, top: 160, tip: side)
        case "hip_thrust": return Motion(sides: hip, stretch: 125, top: 165, tip: side)
        case "curl": return Motion(sides: elbow, stretch: 150, top: 70, tip: upper)
        case "tri_oh": return Motion(sides: elbow, stretch: 70, top: 150, tip: upper)
        case "tri_push": return Motion(sides: elbow, stretch: 85, top: 155, tip: upper)
        case "push_h", "push_v": return Motion(sides: elbow, stretch: 90, top: 150, tip: upper)
        case "pull_v": return Motion(sides: elbow, stretch: 150, top: 90, tip: upper)
        case "pull_h": return Motion(sides: elbow, stretch: 150, top: 100, tip: upper)
        case "raise_l": return Motion(sides: shoulder, stretch: 20, top: 75, tip: "Mettiti di fronte all'iPhone, braccia visibili.")
        case "fly":
            // seen from the front: the arm opens away from the other shoulder
            let open: [(J, J, J)] = [(.rightShoulder, .leftShoulder, .leftElbow), (.leftShoulder, .rightShoulder, .rightElbow)]
            return Motion(sides: open, stretch: 170, top: 115, tip: "Mettiti di fronte all'iPhone, a 2–3 metri, con le braccia visibili.")
        case "core": return Motion(sides: hip, stretch: 150, top: 105, tip: side)
        case "pullover": return Motion(sides: shoulder, stretch: 165, top: 30, tip: upper)
        case "face_pull": return Motion(sides: elbow, stretch: 165, top: 70, tip: upper)
        case "rear_fly": return Motion(sides: shoulder, stretch: 15, top: 80, tip: "Mettiti di fronte all'iPhone, braccia visibili.")
        case "calf":
            // heel raise: the knee-ankle-toe chain is too small for the camera, so the whole body rising is used
            let rise: [(J, J, J)] = [(.leftShoulder, .leftAnkle, .rightAnkle), (.rightShoulder, .rightAnkle, .leftAnkle)]
            return Motion(sides: rise, stretch: 0, top: 1, tip: "Metti l'iPhone di lato, con tutto il corpo e i piedi nell'inquadratura.", rise: true)
        default: return nil
        }
    }

    var completion: (([String: Any]?) -> Void)?
    private let motion: Motion
    private let exercise: String
    private let target: Int

    private let session = AVCaptureSession()
    private let videoQueue = DispatchQueue(label: "reps.video")
    private var previewLayer: AVCaptureVideoPreviewLayer!
    private var useFront = true
    private let skeleton = CAShapeLayer()
    private let countLabel = UILabel()
    private let statusLabel = UILabel()
    private let depthBar = UIProgressView(progressViewStyle: .bar)
    private let speech = AVSpeechSynthesizer()
    private let tapHaptic = UIImpactFeedbackGenerator(style: .heavy)
    private let warnHaptic = UINotificationFeedbackGenerator()

    // rep state (video queue only)
    private var smoothed: Double?
    private var window: [Double] = []
    /// Extremes actually reached by the user, for self-calibration.
    private var seenLow: Double?
    private var seenHigh: Double?
    private var repStartedAt: CFTimeInterval = 0
    private var frame = 0
    /// The 3D pose is used once it has worked on a few frames in a row.
    private var hits3D = 0
    private var misses3D = 0
    private var use3D: Bool { hits3D >= 3 }
    private var inRep = false
    private var maxDepth = 0.0
    private var maxAt: CFTimeInterval = 0
    private var full = 0
    private var partial = 0
    private var concentric: [Double] = []
    private var bufferSize = CGSize(width: 1080, height: 1920)

    init(pattern: String, exercise: String, target: Int) {
        self.motion = Self.motion(for: pattern)!
        self.exercise = exercise
        self.target = target
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        skeleton.strokeColor = UIColor(red: 0.43, green: 0.76, blue: 0.58, alpha: 1).cgColor
        skeleton.fillColor = UIColor.white.cgColor
        skeleton.lineWidth = 5
        skeleton.lineCap = .round
        view.layer.addSublayer(skeleton)

        countLabel.font = .monospacedDigitSystemFont(ofSize: 112, weight: .heavy)
        countLabel.textColor = .white
        countLabel.textAlignment = .center
        countLabel.text = "0"
        countLabel.layer.shadowOpacity = 0.6
        countLabel.layer.shadowRadius = 8
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.textColor = .white
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.text = "\(exercise)\n\(motion.tip)"
        statusLabel.layer.shadowOpacity = 0.7
        depthBar.progressTintColor = UIColor(red: 0.43, green: 0.76, blue: 0.58, alpha: 1)
        depthBar.trackTintColor = UIColor.white.withAlphaComponent(0.25)

        var doneConfig = UIButton.Configuration.filled()
        doneConfig.title = "Fine serie"
        doneConfig.cornerStyle = .capsule
        doneConfig.baseBackgroundColor = UIColor(red: 0.43, green: 0.76, blue: 0.58, alpha: 1)
        doneConfig.baseForegroundColor = .black
        let done = UIButton(configuration: doneConfig, primaryAction: UIAction { [weak self] _ in self?.finish(save: true) })
        var flipConfig = UIButton.Configuration.gray()
        flipConfig.image = UIImage(systemName: "arrow.triangle.2.circlepath.camera")
        flipConfig.cornerStyle = .capsule
        let flip = UIButton(configuration: flipConfig, primaryAction: UIAction { [weak self] _ in self?.flipCamera() })
        var closeConfig = UIButton.Configuration.gray()
        closeConfig.image = UIImage(systemName: "xmark")
        closeConfig.cornerStyle = .capsule
        let close = UIButton(configuration: closeConfig, primaryAction: UIAction { [weak self] _ in self?.finish(save: false) })

        let bottom = UIStackView(arrangedSubviews: [close, done, flip])
        bottom.spacing = 16
        bottom.alignment = .center
        for v in [countLabel, statusLabel, depthBar, bottom] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            countLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            countLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            depthBar.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -18),
            depthBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            depthBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
            depthBar.heightAnchor.constraint(equalToConstant: 10),
            bottom.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            bottom.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            done.widthAnchor.constraint(equalToConstant: 170),
            done.heightAnchor.constraint(equalToConstant: 54),
        ])
        UIApplication.shared.isIdleTimerDisabled = true
        AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
            DispatchQueue.main.async {
                guard let self else { return }
                if ok { self.configure() } else { self.statusLabel.text = "Consenti la fotocamera in Impostazioni → Nomorediet." }
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
        skeleton.frame = view.bounds
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .high
        session.inputs.forEach { session.removeInput($0) }
        let position: AVCaptureDevice.Position = useFront ? .front : .back
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration()
            statusLabel.text = "Fotocamera non disponibile."
            return
        }
        session.addInput(input)
        if session.outputs.isEmpty {
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        if let connection = session.outputs.first?.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = useFront
            }
        }
        session.commitConfiguration()
        let capture = self.session
        videoQueue.async { if !capture.isRunning { capture.startRunning() } }
    }

    private func flipCamera() {
        useFront.toggle()
        configure()
    }

    // MARK: frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        bufferSize = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        frame += 1
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up)
        let request = VNDetectHumanBodyPoseRequest()
        // 3D pose every other frame (heavier); it measures true joint angles whatever the camera position
        let request3D = (frame % 2 == 0 && misses3D < 12 && !motion.rise) ? VNDetectHumanBodyPose3DRequest() : nil
        var requests: [VNRequest] = [request]
        if let request3D { requests.append(request3D) }
        try? handler.perform(requests)
        let now = CACurrentMediaTime()

        if let request3D {
            if let body3D = request3D.results?.first, let angle = angle3D(body3D) {
                hits3D += 1
                misses3D = 0
                if use3D { feed(angle, at: now) }
            } else {
                misses3D += 1
                if misses3D >= 4 { hits3D = 0 }
            }
        }
        guard let body = request.results?.first, let points = try? body.recognizedPoints(.all) else {
            DispatchQueue.main.async { self.skeleton.path = nil }
            return
        }
        drawSkeleton(points)
        guard !use3D else { return }
        // the side whose three joints are seen best
        var best: (Double, Double)? = nil
        for (a, b, c) in motion.sides {
            guard let pa = points[a], let pb = points[b], let pc = points[c] else { continue }
            let conf = Double(min(pa.confidence, pb.confidence, pc.confidence))
            guard conf > 0.3 else { continue }
            let value: Double
            if motion.rise {
                // height of the shoulder above the ankles, in units of the ankle-shoulder distance at rest
                value = Double(pa.location.y - (pb.location.y + pc.location.y) / 2)
            } else {
                value = Self.angle(pa.location, pb.location, pc.location)
            }
            if best == nil || conf > best!.0 { best = (conf, value) }
        }
        guard let best else { return }
        feed(best.1, at: now)
    }

    /// Joint angle from the 3D skeleton (metres, camera-independent), for the first side with all three joints.
    private func angle3D(_ body: VNHumanBodyPose3DObservation) -> Double? {
        for (a, b, c) in motion.sides {
            guard let ja = Self.joint3D(a), let jb = Self.joint3D(b), let jc = Self.joint3D(c),
                  let pa = try? body.recognizedPoint(ja), let pb = try? body.recognizedPoint(jb), let pc = try? body.recognizedPoint(jc) else { continue }
            let va = pa.position.columns.3, vb = pb.position.columns.3, vc = pc.position.columns.3
            let v1 = SIMD3<Float>(va.x - vb.x, va.y - vb.y, va.z - vb.z), v2 = SIMD3<Float>(vc.x - vb.x, vc.y - vb.y, vc.z - vb.z)
            let mag = simd_length(v1) * simd_length(v2)
            guard mag > 0 else { continue }
            return Double(acos(max(-1, min(1, simd_dot(v1, v2) / mag)))) * 180 / .pi
        }
        return nil
    }

    private static func joint3D(_ j: J) -> VNHumanBodyPose3DObservation.JointName? {
        switch j {
        case .leftShoulder: .leftShoulder
        case .rightShoulder: .rightShoulder
        case .leftElbow: .leftElbow
        case .rightElbow: .rightElbow
        case .leftWrist: .leftWrist
        case .rightWrist: .rightWrist
        case .leftHip: .leftHip
        case .rightHip: .rightHip
        case .leftKnee: .leftKnee
        case .rightKnee: .rightKnee
        case .leftAnkle: .leftAnkle
        case .rightAnkle: .rightAnkle
        default: nil
        }
    }

    /// Median of the last 5 values (removes single-frame pose glitches), then light smoothing.
    private func feed(_ raw: Double, at time: CFTimeInterval) {
        window.append(raw)
        if window.count > 5 { window.removeFirst() }
        let median = window.sorted()[window.count / 2]
        let value = smoothed.map { $0 * 0.4 + median * 0.6 } ?? median
        smoothed = value
        seenLow = min(seenLow ?? value, value)
        seenHigh = max(seenHigh ?? value, value)
        track(angle: value, at: time)
    }

    private static func angle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Double {
        let v1 = CGVector(dx: a.x - b.x, dy: a.y - b.y), v2 = CGVector(dx: c.x - b.x, dy: c.y - b.y)
        let dot = v1.dx * v2.dx + v1.dy * v2.dy
        let mag = hypot(v1.dx, v1.dy) * hypot(v2.dx, v2.dy)
        guard mag > 0 else { return 180 }
        return Double(acos(max(-1, min(1, dot / mag)))) * 180 / .pi
    }

    private func track(angle: Double, at time: CFTimeInterval) {
        // depth against the plan's angles, and against the range this user actually moves through
        let planned: Double
        var calibrated: Double
        if motion.rise {
            // calf raise: up (shoulder highest) is the contraction, down is the stretch
            guard let low = seenLow, let high = seenHigh, high - low > 0.015 else { return }
            calibrated = (high - angle) / (high - low)
            planned = calibrated
        } else {
            planned = (angle - motion.top) / (motion.stretch - motion.top)
            calibrated = planned
            if let low = seenLow, let high = seenHigh {
                let span = abs(motion.stretch - motion.top)
                if high - low > span * 0.45 {
                    let stretchSeen = motion.stretch > motion.top ? high : low
                    let topSeen = motion.stretch > motion.top ? low : high
                    calibrated = (angle - topSeen) / (stretchSeen - topSeen)
                }
            }
        }
        DispatchQueue.main.async { self.depthBar.setProgress(Float(max(0, min(1, calibrated))), animated: false) }
        if !inRep && calibrated > 0.45 {
            inRep = true
            maxDepth = planned
            maxAt = time
            repStartedAt = time
        }
        guard inRep else { return }
        if planned > maxDepth { maxDepth = planned; maxAt = time }
        // back near the top, and not a jitter: a rep takes at least 0.6 s
        if calibrated < 0.2 && time - repStartedAt > 0.6 { completeRep(at: time) }
    }

    private func completeRep(at time: CFTimeInterval) {
        inRep = false
        let lift = time - maxAt
        let reachedStretch = motion.rise || maxDepth >= 0.85
        if reachedStretch { full += 1; concentric.append(lift) } else { partial += 1 }
        let total = full + partial
        let loss = velocityLoss()
        DispatchQueue.main.async {
            self.countLabel.text = "\(total)"
            UIView.animate(withDuration: 0.12, animations: { self.countLabel.transform = CGAffineTransform(scaleX: 1.25, y: 1.25) }) { _ in
                UIView.animate(withDuration: 0.2) { self.countLabel.transform = .identity }
            }
            if reachedStretch {
                self.tapHaptic.impactOccurred()
                self.say("\(total)")
                var text = "Ripetizione completa"
                if let loss, loss >= 0.35 { text = "Stai rallentando molto: sei vicino al cedimento" }
                else if let loss, loss >= 0.2 { text = "Velocità in calo: ancora 2–3 ripetizioni" }
                self.statusLabel.text = text
            } else {
                self.warnHaptic.notificationOccurred(.warning)
                self.say("Più ampio")
                self.statusLabel.text = "Non sei arrivato al massimo allungamento"
            }
            if self.target > 0 && total == self.target { self.say("Obiettivo raggiunto") }
        }
    }

    /// Slowdown of the lifting phase versus the first two full reps (0 = same speed).
    private func velocityLoss() -> Double? {
        guard concentric.count >= 3 else { return nil }
        let base = (concentric[0] + concentric[1]) / 2
        guard let last = concentric.last, last > 0 else { return nil }
        return max(0, 1 - base / last)
    }

    private func say(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "it-IT")
        utterance.rate = 0.55
        speech.stopSpeaking(at: .immediate)
        speech.speak(utterance)
    }

    private func drawSkeleton(_ points: [J: VNRecognizedPoint]) {
        let pairs: [(J, J)] = [(.leftShoulder, .rightShoulder), (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
                               (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist), (.leftShoulder, .leftHip),
                               (.rightShoulder, .rightHip), (.leftHip, .rightHip), (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
                               (.rightHip, .rightKnee), (.rightKnee, .rightAnkle), (.neck, .nose)]
        let size = bufferSize
        DispatchQueue.main.async {
            let bounds = self.view.bounds
            let scale = max(bounds.width / size.width, bounds.height / size.height)
            let ox = (size.width * scale - bounds.width) / 2, oy = (size.height * scale - bounds.height) / 2
            func map(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * size.width * scale - ox, y: (1 - p.y) * size.height * scale - oy) }
            let path = UIBezierPath()
            for (a, b) in pairs {
                guard let pa = points[a], let pb = points[b], pa.confidence > 0.3, pb.confidence > 0.3 else { continue }
                path.move(to: map(pa.location))
                path.addLine(to: map(pb.location))
            }
            self.skeleton.path = path.cgPath
        }
    }

    private func finish(save: Bool) {
        let capture = self.session
        videoQueue.async { capture.stopRunning() }
        UIApplication.shared.isIdleTimerDisabled = false
        let loss = velocityLoss()
        let rir: String
        switch loss ?? 0 {
        case ..<0.2: rir = "3+"
        case ..<0.35: rir = "2"
        case ..<0.5: rir = "1"
        default: rir = "0"
        }
        let result: [String: Any]? = save ? ["reps": full + partial, "full": full, "partial": partial,
                                             "velocityLoss": Int(((loss ?? 0) * 100).rounded()),
                                             "rir": concentric.count >= 3 ? rir : ""] : nil
        dismiss(animated: true) { self.completion?(result) }
    }
}
