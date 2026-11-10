import SwiftUI
import UIKit
#if DUO_COVER
import AVFoundation
import AVKit
#endif

// Besonderheiten des iPhone Duo: Scharnierwinkel und Cover auf dem Außendisplay.
// Der Code hinter DUO_HINGE / DUO_COVER wird nur übersetzt, wenn das SDK die Schnittstellen kennt.

struct CoverDisplayInfo {
    var image: UIImage?
    var title: String
    var author: String
    var progress: Double
}

/// Das, was auf dem Außendisplay erscheint, während innen gelesen wird:
/// das Buchcover über die ganze Fläche, wie ein zugeklapptes Buch von außen.
struct CoverDisplayView: View {
    let info: CoverDisplayInfo
    var hint: String?
    /// true = Cover füllt das ganze Display (Ränder des Bilds werden beschnitten),
    /// false = ganzes Cover von Kante zu Kante, der Rest wird mit dem Cover selbst gefüllt.
    @AppStorage("coverFill") private var fill = true

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let image = info.image {
                    // Hintergrund aus dem Cover selbst, damit nirgends eine leere Fläche bleibt
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: 36, opaque: true)
                        .overlay(Color.black.opacity(0.18))
                        .clipped()
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: fill ? .fill : .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .shadow(color: .black.opacity(fill ? 0 : 0.5), radius: 18, y: 6)
                } else {
                    GeneratedCover(title: info.title, author: info.author)
                }

                // Leichter Glanz wie auf einem echten Einband
                LinearGradient(colors: [.white.opacity(0.10), .clear, .black.opacity(0.16)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .allowsHitTesting(false)

                VStack(spacing: 10) {
                    Spacer(minLength: 0)
                    if let hint {
                        Text(hint)
                            .font(.system(.footnote, design: .serif).weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.45), in: Capsule())
                    }
                    // Schmaler Lesefortschritt am unteren Rand
                    Capsule()
                        .fill(.white.opacity(0.28))
                        .frame(width: min(160, geo.size.width * 0.4), height: 3)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(.white.opacity(0.92))
                                .frame(width: min(160, geo.size.width * 0.4) * min(1, max(0, info.progress)), height: 3)
                        }
                        .shadow(color: .black.opacity(0.5), radius: 2)
                }
                .padding(.bottom, max(14, geo.safeAreaInsets.bottom + 6))
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
    }
}

struct DuoSupport: ViewModifier {
    let info: CoverDisplayInfo
    /// Cover außen zeigen (nur sinnvoll, solange innen gelesen wird).
    let coverActive: Bool
    @Binding var hingeDegrees: Double?
    @Binding var coverAvailable: Bool

    func body(content: Content) -> some View {
        content
            .modifier(HingeBridge(degrees: $hingeDegrees))
            .modifier(CoverBridge(info: info, active: coverActive, available: $coverAvailable))
    }
}

private struct HingeBridge: ViewModifier {
    @Binding var degrees: Double?

    func body(content: Content) -> some View {
        #if DUO_HINGE
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, newContext in
                degrees = newContext.hinge?.angle.degrees
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private struct CoverBridge: ViewModifier {
    let info: CoverDisplayInfo
    let active: Bool
    @Binding var available: Bool

    func body(content: Content) -> some View {
        #if DUO_COVER
        if #available(iOS 27.1, *) {
            content.modifier(CoverAccessoryModifier(info: info, active: active, available: $available))
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// Beim Lesen soll das Buch die ganze Fläche nutzen und der Buchrücken genau auf dem Falz liegen.
/// Deshalb verzichtet der Leser auf die seitliche Leiste des iPhone Duo.
struct ImmersiveBars: ViewModifier {
    func body(content: Content) -> some View {
        #if DUO_BAR
        if #available(iOS 27.1, *) {
            content.toolbarVerticalBehavior(.disabled)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

enum DuoFold {
    /// Lage des Falzes – auch wenn das Duo flach aufgeklappt ist. Zugeklappt und auf anderen Geräten nil.
    static func fold(_ proxy: GeometryProxy) -> FoldInfo? {
        #if DUO_FOLD
        if #available(iOS 27.1, *) {
            guard let region = proxy.reservedRegions(kind: .division, options: [.includeInactive]).first else { return nil }
            return FoldInfo(frame: region.frame, isActive: region.isActive)
        }
        return nil
        #else
        return nil
        #endif
    }

    /// Bereiche, die gerade von Hardware oder Systemelementen verdeckt sind (z. B. die Kamera).
    static func occlusions(_ proxy: GeometryProxy) -> [CGRect] {
        #if DUO_FOLD
        if #available(iOS 27.1, *) {
            return proxy.reservedRegions(kind: .occlusion).map { $0.frame }
        }
        return []
        #else
        return []
        #endif
    }

    /// Alle bekannten Bereiche als Text, für die Diagnose.
    static func describe(_ proxy: GeometryProxy) -> [String] {
        #if DUO_FOLD
        if #available(iOS 27.1, *) {
            func text(_ rect: CGRect) -> String {
                "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height))"
            }
            var lines: [String] = []
            for region in proxy.reservedRegions(kind: .division, options: [.includeInactive]) {
                lines.append("Falz: \(text(region.frame)) \(region.isActive ? "aktiv" : "flach")")
            }
            for region in proxy.reservedRegions(kind: .occlusion, options: [.includeInactive]) {
                lines.append("Verdeckt: \(text(region.frame)) \(region.isActive ? "aktiv" : "inaktiv")")
            }
            return lines.isEmpty ? ["Falz: keiner gemeldet"] : lines
        }
        return ["Falz: braucht iOS 27.1"]
        #else
        return ["Falz: in dieser Version nicht enthalten"]
        #endif
    }
}

enum DuoFeatures {
    /// Ob diese Version der App die Außendisplay-Funktion überhaupt enthält.
    static var coverCompiled: Bool {
        #if DUO_COVER
        if #available(iOS 27.1, *) { return true }
        return false
        #else
        return false
        #endif
    }

    static var hingeCompiled: Bool {
        #if DUO_HINGE
        if #available(iOS 27.1, *) { return true }
        return false
        #else
        return false
        #endif
    }
}

#if DUO_COVER
/// iOS erlaubt Inhalte auf dem Außendisplay eines aufgeklappten Duo nur, während die Kamera läuft.
/// Deshalb startet hier eine Kamerasitzung ohne Aufnahme: Es wird nichts gespeichert oder angezeigt.
@available(iOS 27.1, *)
private struct CoverAccessoryModifier: ViewModifier {
    let info: CoverDisplayInfo
    let active: Bool
    @Binding var available: Bool

    @State private var isEnabled = false
    @State private var camera = IdleCamera()

    func body(content: Content) -> some View {
        content
            .sceneAccessory {
                CameraCaptureAccessory(isEnabled: $isEnabled) {
                    CoverDisplayView(info: info)
                }
                .onAvailabilityChange { isAvailable in
                    available = isAvailable
                }
            }
            .task(id: active) {
                isEnabled = active
                if active {
                    await camera.start()
                } else {
                    camera.stop()
                }
            }
            .onDisappear {
                camera.stop()
            }
    }
}

/// Kamerasitzung in niedrigster Qualität, deren Bilder sofort verworfen werden.
private final class IdleCamera: @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "lesen.cover.camera")
    private var configured = false

    func start() async {
        guard AVCaptureDevice.default(for: .video) != nil else { return }
        guard await AVCaptureDevice.requestAccess(for: .video) else { return }
        queue.async { [self] in
            if !configured {
                session.beginConfiguration()
                session.sessionPreset = .low
                if let device = AVCaptureDevice.default(for: .video),
                   let input = try? AVCaptureDeviceInput(device: device),
                   session.canAddInput(input) {
                    session.addInput(input)
                }
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                if session.canAddOutput(output) {
                    session.addOutput(output)
                }
                session.commitConfiguration()
                configured = true
            }
            if !session.isRunning {
                session.startRunning()
            }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }
}
#endif
