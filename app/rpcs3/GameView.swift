import SwiftUI
import UIKit
import QuartzCore

/// The surface RPCS3 renders into. Its layer is a CAMetalLayer, which MoltenVK presents to.
final class MetalRenderView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateSize()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateSize()
    }

    private func updateSize() {
        guard let window else { return }
        let scale = window.screen.nativeScale
        contentScaleFactor = scale
        metalLayer.contentsScale = scale
        let pixels = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        metalLayer.drawableSize = pixels
        let refresh = Double(window.screen.maximumFramesPerSecond)
        core_set_render_view(Unmanaged.passUnretained(self).toOpaque(), Int32(pixels.width), Int32(pixels.height), refresh)
    }
}

struct MetalRenderViewRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> MetalRenderView { MetalRenderView(frame: .zero) }
    func updateUIView(_ uiView: MetalRenderView, context: Context) {}
}

struct TouchControllerRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> TouchControllerView { TouchControllerView(frame: .zero) }
    func updateUIView(_ uiView: TouchControllerView, context: Context) {}
    static func dismantleUIView(_ uiView: TouchControllerView, coordinator: ()) { uiView.releaseAll() }
}

/// Full-screen game with the on-screen controller over it, and a small bar to hide the
/// controller or stop the game.
struct GameScreen: View {
    let game: Emulator.Game
    let onClose: () -> Void
    @State private var error: String?
    @State private var booted = false
    @State private var showTouch = !PadBridge.shared.hasPhysicalController

    var body: some View {
        ZStack(alignment: .bottom) {
            MetalRenderViewRepresentable()
                .ignoresSafeArea()

            if showTouch {
                TouchControllerRepresentable()
                    .ignoresSafeArea()
            }

            HStack(spacing: 18) {
                Button {
                    showTouch.toggle()
                } label: {
                    Image(systemName: showTouch ? "gamecontroller.fill" : "gamecontroller")
                }
                .accessibilityLabel(showTouch ? "Hide on-screen controller" : "Show on-screen controller")

                Button {
                    Emulator.shared.stop()
                    onClose()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .accessibilityLabel("Stop game")
            }
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.white.opacity(0.08), in: Capsule())
            .padding(.bottom, 4)
        }
        .background(.black)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onChange(of: showTouch) { _, visible in
            PadBridge.shared.touchVisible = visible
            if !visible { PadBridge.shared.touch = PadState() }
        }
        .onAppear {
            OrientationLock.set(.landscape)
            PadBridge.shared.touchVisible = showTouch
            PadBridge.shared.start()
        }
        .onDisappear {
            PadBridge.shared.stop()
            OrientationLock.set(.allButUpsideDown)
        }
        .task {
            // Let the view get its window, rotate to landscape and settle its size first:
            // the renderer reads the size at boot.
            try? await Task.sleep(for: .milliseconds(600))
            guard !booted else { return }
            booted = true
            if let reason = Emulator.shared.boot(game) {
                error = reason
            }
        }
        .alert("Could not start the game", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil; onClose() } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }
}
