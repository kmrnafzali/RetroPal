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

/// Das, was auf dem Außendisplay erscheint, während innen gelesen wird.
struct CoverDisplayView: View {
    let info: CoverDisplayInfo

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image = info.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 50)
                    .opacity(0.45)
                    .ignoresSafeArea()
            }
            VStack(spacing: 18) {
                Spacer(minLength: 0)
                CoverArt(image: info.image, title: info.title, author: info.author)
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .padding(.horizontal, 44)
                Spacer(minLength: 0)
                VStack(spacing: 8) {
                    Text(info.title)
                        .font(.system(.headline, design: .serif))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    if !info.author.isEmpty {
                        Text(info.author)
                            .font(.subheadline)
                            .opacity(0.7)
                    }
                    ProgressView(value: min(1, max(0, info.progress)))
                        .tint(.white)
                        .frame(width: 140)
                        .padding(.top, 4)
                }
                .foregroundStyle(.white)
                .padding(.bottom, 28)
            }
            .padding(.top, 28)
        }
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
    /// Lage des Falzes, solange das Duo halb aufgeklappt ist. Sonst nil.
    static func division(_ proxy: GeometryProxy) -> CGRect? {
        #if DUO_FOLD
        if #available(iOS 27.1, *) {
            return proxy.reservedRegions(kind: .division).first?.frame
        }
        return nil
        #else
        return nil
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
