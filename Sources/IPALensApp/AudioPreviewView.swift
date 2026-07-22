import AVFoundation
import AVKit
import IPALensCore
import SwiftUI

struct AudioPreviewView: View {
    let preview: AudioPreview

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 20)
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(Color.accentColor)
            VStack(spacing: 5) {
                Text(preview.originalFileName)
                    .font(.headline)
                    .lineLimit(2)
                Text(ByteCountFormatter.string(fromByteCount: preview.fileSize, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            NativeMediaPlayer(fileURL: preview.fileURL)
                .frame(maxWidth: 520)
                .frame(height: 86)
            Text("Playback availability depends on the audio formats and codecs supported by this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 20)
        }
        .padding(24)
    }
}

struct VideoPreviewView: View {
    let preview: VideoPreview

    var body: some View {
        VStack(spacing: 12) {
            NativeMediaPlayer(fileURL: preview.fileURL)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Label(preview.originalFileName, systemImage: "film")
                    .lineLimit(1)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: preview.fileSize, countStyle: .file))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("Playback availability depends on the video formats and codecs supported by this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }
}

private struct NativeMediaPlayer: NSViewRepresentable {
    let fileURL: URL

    final class Coordinator {
        var loadedURL: URL?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        view.showsSharingServiceButton = false
        view.videoGravity = .resizeAspect
        load(fileURL, into: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        guard context.coordinator.loadedURL != fileURL else { return }
        view.player?.pause()
        load(fileURL, into: view, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        view.player?.pause()
        view.player?.replaceCurrentItem(with: nil)
        view.player = nil
        coordinator.loadedURL = nil
    }

    private func load(_ url: URL, into view: AVPlayerView, coordinator: Coordinator) {
        view.player = AVPlayer(playerItem: AVPlayerItem(url: url))
        coordinator.loadedURL = url
    }
}
