import SwiftUI
import AppKit

/// SwiftUI field that lets the user "record" a hot key by pressing the
/// combination they want. The raw NSEvent is captured via a local key-
/// down monitor while the field is active; we don't touch the global
/// hot key system here — the registered manager picks up the persisted
/// descriptor through a separate observer.
struct HotkeyRecorderField: View {

    @Binding var descriptor: HotkeyDescriptor
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Text(recording ? "Press shortcut…" : descriptor.displayString)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(recording ? .orange : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(minWidth: 140, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.thinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(recording ? Color.orange : Color.clear, lineWidth: 1)
                )

            Button(recording ? "Cancel" : "Record") {
                if recording {
                    stopRecording()
                } else {
                    startRecording()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if !recording && !descriptor.isEmpty {
                Button("Clear") {
                    descriptor = .empty
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        recording = true
        // Local monitor: only fires while *our* app has key focus, which
        // is exactly what we want (Settings window is in front during
        // recording). The closure returns nil to swallow the event so it
        // doesn't reach text fields underneath.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == kVK_Escape_UInt16 {
                stopRecording()
                return nil
            }
            if let captured = HotkeyDescriptor(nsEvent: event) {
                descriptor = captured
                stopRecording()
                return nil
            }
            // No modifier yet: ignore the bare key but still swallow it
            // so it doesn't type into a focused text field.
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

// `kVK_Escape` is `Int` from Carbon; NSEvent.keyCode is `UInt16` — wrap once.
private let kVK_Escape_UInt16: UInt16 = 0x35
