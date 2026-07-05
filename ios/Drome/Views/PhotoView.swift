//
//  PhotoView.swift
//  Drome
//
//  Progress-photo tile detail: today's done/not state, a big check-off
//  button, and an optional photo attachment via PhotosPicker. Attached
//  images are saved into the app's private container (Application
//  Support/photos/YYYY-MM-DD.jpg) and only the filename travels as the
//  photoRef. Photos stay on this device and never appear in share cards.
//  No gallery/browsing UI (fast-follow).
//

import PhotosUI
import SwiftUI
import UIKit

struct PhotoView: View {
    @Environment(AppModel.self) private var appModel

    /// The SAME client instance that backs the AppModel. Needed to pass a
    /// photoRef, which AppModel's `logPhotoDone()` does not accept.
    /// Integration must pass the shared instance.
    private let client: any DromeCoreClient

    @State private var pickerItem: PhotosPickerItem?
    @State private var thumbnail: UIImage?
    @State private var attachFailed = false

    init(client: any DromeCoreClient) {
        self.client = client
    }

    private var photoDone: Bool { appModel.todayState?.day.photoDone ?? false }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DromeSpacing.l) {
                Text("Progress photo")
                    .dromeTitle()

                statusRow

                // Thumbnail is gated on photoDone: a revoked or failed log
                // must never keep displaying "today's photo" while the task
                // honestly reads not-done.
                if photoDone, let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityLabel("Today's progress photo")
                }

                if !photoDone {
                    Button {
                        appModel.logPhotoDone()
                    } label: {
                        Text("Mark photo taken")
                    }
                    .buttonStyle(PhotoPrimaryButtonStyle())
                }

                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label(
                        thumbnail == nil ? "Attach today's photo" : "Replace today's photo",
                        systemImage: "photo"
                    )
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.dromeClay)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.dromeClay, lineWidth: 2)
                    )
                }

                if attachFailed {
                    Text("Couldn't attach that photo. Try another.")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.dromeMiss)
                }

                Text("Photos stay on this device. They never appear in share cards.")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.dromeInk.opacity(0.55))
            }
            .padding(DromeSpacing.m)
        }
        .background(Color.dromeSand.ignoresSafeArea())
        .onAppear {
            appModel.refresh()
            syncThumbnail()
        }
        // A revoke elsewhere can flip photoDone false while this view is up;
        // re-sync so the stale file is deleted and the thumbnail drops.
        .onChange(of: photoDone) {
            syncThumbnail()
        }
        .onChange(of: pickerItem) {
            guard let item = pickerItem else { return }
            pickerItem = nil
            Task { await attach(item) }
        }
    }

    private var statusRow: some View {
        Group {
            if photoDone {
                Label("Photo done today", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.dromeDone)
            } else {
                Label("Not done yet", systemImage: "circle.dashed")
                    .foregroundStyle(Color.dromeInk.opacity(0.65))
            }
        }
        .font(.system(size: 17, weight: .bold))
    }

    // MARK: - Attach flow

    private func attach(_ item: PhotosPickerItem) async {
        attachFailed = false
        guard let date = appModel.todayState?.date else {
            attachFailed = true
            return
        }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let jpeg = image.jpegData(compressionQuality: 0.85) else {
            attachFailed = true
            return
        }
        let filename = "\(date).jpg"
        let fileURL: URL
        do {
            let directory = try Self.photosDirectory()
            fileURL = directory.appendingPathComponent(filename)
            try jpeg.write(to: fileURL, options: .atomic)
        } catch {
            attachFailed = true
            return
        }
        do {
            // AppModel has no photoRef-carrying intent, so log through the
            // shared client and hand the result back for the standard
            // completion-moment/refresh handling.
            let result = try client.logPhotoDone(photoRef: filename, effectiveDate: nil)
            appModel.noteExternalLog(result)
            thumbnail = image
        } catch {
            // The log never landed: don't leave an orphaned JPEG behind that
            // would masquerade as "today's photo".
            try? FileManager.default.removeItem(at: fileURL)
            thumbnail = nil
            attachFailed = true
        }
    }

    /// Loads today's photo when the task is done; when it is NOT done (never
    /// logged, log failed, or the event was revoked) any file for today is an
    /// orphan — delete it and show nothing.
    private func syncThumbnail() {
        guard let date = appModel.todayState?.date,
              let directory = try? Self.photosDirectory() else { return }
        let url = directory.appendingPathComponent("\(date).jpg")
        guard photoDone else {
            try? FileManager.default.removeItem(at: url)
            thumbnail = nil
            return
        }
        guard thumbnail == nil else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let image = UIImage(contentsOfFile: url.path) {
            thumbnail = image
        }
    }

    /// App-private photo store: Application Support/photos/.
    private static func photosDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

// MARK: - Button style

private struct PhotoPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 20, weight: .black))
            .tracking(-0.3)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 64)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.dromeClay)
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

// MARK: - Previews

#Preview("Photo — not done") {
    let core = MockDromeCore()
    return PhotoView(client: core)
        .environment(AppModel(core: core))
}

#Preview("Photo — done") {
    let core = MockDromeCore()
    _ = try? core.logPhotoDone(photoRef: nil, effectiveDate: nil)
    return PhotoView(client: core)
        .environment(AppModel(core: core))
}
