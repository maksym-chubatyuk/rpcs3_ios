import SwiftUI

/// Arranging the on-screen controls, in landscape as in a game: drag a group to move it, pinch it
/// to resize it, and set the overall size, opacity and vibration. For all games, or for one game.
struct TouchLayoutEditor: View {
    /// nil: the layout for all games.
    let gameID: String?
    let gameTitle: String?

    @State private var layout: TouchLayout
    /// For a game: whether it gets a layout of its own (else the one for all games is edited)
    @State private var ownLayout: Bool
    @State private var panelOpen = true
    @Environment(\.dismiss) private var dismiss

    init(gameID: String? = nil, gameTitle: String? = nil) {
        self.gameID = gameID
        self.gameTitle = gameTitle
        let own = gameID.map(TouchLayout.hasOwn) ?? false
        _ownLayout = State(initialValue: gameID == nil || own)
        _layout = State(initialValue: TouchLayout.load(for: gameID))
    }

    var body: some View {
        ZStack {
            // Something like a game picture behind, to judge the opacity
            LinearGradient(colors: [Color(white: 0.25), Color(red: 0.12, green: 0.18, blue: 0.3)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            TouchControllerRepresentable(layout: layout, editing: true) { layout = $0 }
                .ignoresSafeArea()

            if panelOpen {
                panel
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else {
                Button("Show Options", systemImage: "slider.horizontal.3") {
                    withAnimation { panelOpen = true }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onChange(of: ownLayout) { _, own in
            // Back to the shared layout; a game's own starts from what is shown
            if !own { layout = TouchLayout.load(for: nil) }
        }
        .onAppear { OrientationLock.set(.landscape) }
        .onDisappear { OrientationLock.set(.allButUpsideDown) }
    }

    private var panel: some View {
        VStack(spacing: 10) {
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Text(scopeTitle).font(.headline).lineLimit(1)
                Spacer()
                Button("Save") { save() }.bold()
            }

            Text("Drag a group of buttons to move it; pinch it to resize it.")
                .font(.caption).foregroundStyle(.secondary)

            if gameID != nil {
                Picker("Layout", selection: $ownLayout) {
                    Text("All Games").tag(false)
                    Text("This Game Only").tag(true)
                }
                .pickerStyle(.segmented)
            }

            LabeledContent("Size") {
                Slider(value: $layout.size, in: TouchLayout.sizes)
                    .frame(width: 180)
            }
            LabeledContent("Opacity") {
                Slider(value: $layout.opacity, in: TouchLayout.opacities)
                    .frame(width: 180)
            }
            Toggle("Vibrate on Press", isOn: $layout.haptics)

            HStack {
                Button("Reset", systemImage: "arrow.counterclockwise", role: .destructive) {
                    layout = TouchLayout()
                }
                Spacer()
                Button("Hide Options", systemImage: "chevron.down") {
                    withAnimation { panelOpen = false }
                }
            }
            .font(.subheadline)
        }
        .padding(14)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var scopeTitle: String {
        guard let gameTitle else { return "On-Screen Controls" }
        return ownLayout ? gameTitle : "All Games"
    }

    private func save() {
        if let gameID, ownLayout {
            TouchLayout.save(layout, for: gameID)
        } else {
            TouchLayout.save(layout, for: nil)
            // Edited from a game page with "All Games": that game follows the shared layout again
            if let gameID { TouchLayout.removeOwn(gameID) }
        }
        dismiss()
    }
}
