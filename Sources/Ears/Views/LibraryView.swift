import AppKit
import SwiftUI

/// Browser for past meetings: search, read, copy, reveal, delete.
struct LibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var library = TranscriptLibrary()
    @State private var query = ""
    @State private var selectedID: URL?
    @State private var contentMatchIDs: Set<URL> = []

    /// Names match instantly; body matches arrive from the debounced
    /// background search below.
    private var filtered: [TranscriptLibrary.Meeting] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return library.meetings }
        return library.meetings.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed) || contentMatchIDs.contains($0.id)
        }
    }

    private var selected: TranscriptLibrary.Meeting? {
        filtered.first { $0.id == selectedID } ?? filtered.first
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Meeting Library")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            TextField("Search transcripts…", text: $query)
                .textFieldStyle(.roundedBorder)
                .task(id: query) {
                    // Full-text search, debounced and off the main thread —
                    // typing must stay instant no matter how big the library.
                    contentMatchIDs = []
                    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.count >= 2 else { return }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled else { return }
                    let meetings = library.meetings
                    let matches = await Task.detached(priority: .userInitiated) {
                        Set(meetings.filter { meeting in
                            ((try? String(contentsOf: meeting.id, encoding: .utf8)) ?? "")
                                .localizedCaseInsensitiveContains(trimmed)
                        }.map(\.id))
                    }.value
                    if !Task.isCancelled { contentMatchIDs = matches }
                }

            if library.meetings.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    meetingList
                        .frame(width: 230)
                    Divider()
                    detailPane
                }
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(16)
        .frame(width: 760, height: 500)
        .onAppear {
            library.reload()
            selectedID = library.meetings.first?.id
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("No saved meetings yet.\nTranscripts land here when you stop a session.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var meetingList: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(filtered) { meeting in
                    Button {
                        selectedID = meeting.id
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(meeting.name)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Text(Self.dateFormatter.string(from: meeting.date))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selected?.id == meeting.id ? Color.white.opacity(0.14) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
                if filtered.isEmpty {
                    Text("No matches.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 20)
                }
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let meeting = selected {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(meeting.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Button {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(library.content(meeting), forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .help("Copy transcript")
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([meeting.id])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.plain)
                    .help("Reveal in Finder")
                    Button {
                        let wasSelected = meeting.id
                        library.delete(meeting)
                        if selectedID == wasSelected {
                            selectedID = library.meetings.first?.id
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .help("Move to Trash")
                }
                .padding(10)
                Divider()
                ScrollView {
                    Text(library.content(meeting))
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
        } else {
            Text("Select a meeting")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
