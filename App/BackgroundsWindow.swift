import AppKit
import MoobilityCore
import SwiftUI
import UniformTypeIdentifiers

/// Layout A: the next 30 days, then a grid of photos whose timing is chips on each tile.
struct BackgroundsWindow: View {
    @ObservedObject var background: BackgroundController
    private let columns = [GridItem(.adaptive(minimum: 250), spacing: 12, alignment: .top)]

    var body: some View {
        VStack(spacing: 0) {
            UpcomingStrip(background: background)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if background.library.photos.isEmpty {
                        emptyState
                    } else {
                        Text("Your photos").font(.headline)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                            ForEach(background.library.photos, id: \.file) { photo in
                                PhotoTile(background: background, photo: photo)
                            }
                        }
                    }
                    Text("Built-in seasons").font(.headline)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(Season.allCases, id: \.self) { season in
                            SeasonTile(background: background, season: season)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .dropDestination(for: URL.self) { urls, _ in
                background.drop(urls, onto: nil)
                return true
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Show folder") { NSWorkspace.shared.open(background.store.folder) }
                Button("+ Add photos", action: choosePhotos).buttonStyle(.borderedProminent)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            background.refresh()
        }
    }

    private var emptyState: some View {
        Text("Seasons are showing automatically. Add a photo to use your own.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5])).foregroundStyle(.tertiary))
    }

    private func choosePhotos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { background.drop(panel.urls, onto: nil) }
    }
}

/// One strip segment per run of days with the same winner.
private struct UpcomingStrip: View {
    @ObservedObject var background: BackgroundController
    private static let days = 30

    var body: some View {
        let plan = background.library.dayPlan(from: Date(), days: Self.days, timeZone: .current)
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Next 30 days")
                Spacer()
                Text("Now: \(background.current.title)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(Array(plan.enumerated()), id: \.offset) { index, segment in
                        StripSegment(background: background, segment: segment, isToday: index == 0,
                                     dayWidth: geo.size.width / CGFloat(Self.days))
                    }
                }
            }
            .frame(height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct StripSegment: View {
    @ObservedObject var background: BackgroundController
    let segment: DaySegment
    let isToday: Bool
    let dayWidth: CGFloat

    private var dayIndexes: [CivilDay] {
        var out: [CivilDay] = []
        var d = segment.start
        while d <= segment.end { out.append(d); d = d.adding(days: 1) }
        return out
    }

    var body: some View {
        let days = dayIndexes
        CandidateThumbnail(background: background, candidate: segment.winner)
            .frame(width: dayWidth * CGFloat(days.count), height: 30)
            .clipped()
            .overlay(alignment: .bottomLeading) {
                Text(segment.winner.title)
                    .font(.system(size: 10))
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 2)
                    .padding(.top, 8)
                    .frame(width: dayWidth * CGFloat(days.count), alignment: .leading)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                    .clipped()
            }
            .overlay(alignment: .topLeading) {
                ForEach(Array(days.enumerated()), id: \.offset) { offset, day in
                    if segment.timedDays.contains(day) {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.white)
                            .shadow(radius: 1)
                            .offset(x: dayWidth * CGFloat(offset) + 1, y: 2)
                    }
                }
            }
            .overlay(alignment: .leading) {
                if isToday {
                    Rectangle().strokeBorder(Color.accentColor, lineWidth: 2).frame(width: dayWidth)
                }
            }
            .overlay(alignment: .trailing) { Rectangle().fill(.black.opacity(0.25)).frame(width: 1) }
            .help(segment.winner.title)
    }
}

/// A candidate's image, reloaded when its file changes.
struct CandidateThumbnail: View {
    @ObservedObject var background: BackgroundController
    let candidate: Candidate
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            }
        }
        .task(id: background.thumbnailKey(for: candidate)) {
            image = await background.thumbnail(for: candidate)
        }
    }
}
