import AppKit
import MoobilityCore
import SwiftUI

/// A tile's picture and name, shared by photos and seasons.
private struct TileChrome<Content: View>: View {
    @ObservedObject var background: BackgroundController
    let candidate: Candidate
    @ViewBuilder let content: Content

    private var isShowing: Bool { background.current.id == candidate.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CandidateThumbnail(background: background, candidate: candidate)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipped()
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(candidate.title).fontWeight(.semibold).lineLimit(1)
                    Spacer()
                    if isShowing { Text("showing now").font(.caption2).foregroundStyle(.secondary) }
                }
                content
            }
            .padding(8)
        }
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isShowing ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isShowing ? 2 : 1))
    }
}

struct SeasonTile: View {
    @ObservedObject var background: BackgroundController
    let season: Season

    var body: some View {
        let dates = season.dates(southern: background.library.southern)
        TileChrome(background: background, candidate: .season(season)) {
            Text(TimingRule.yearly(start: dates.start, end: dates.end).chipText(from: today).replacingOccurrences(of: "Every year", with: "Built-in"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Show today") { background.override(Candidate.season(season).id) }
        }
    }
}

struct PhotoTile: View {
    @ObservedObject var background: BackgroundController
    let photo: Photo
    @State private var adding = false
    @State private var editing: EditedRule?
    @State private var renaming = false
    @State private var newTitle = ""

    var body: some View {
        TileChrome(background: background, candidate: .photo(photo)) {
            if background.unreadable.contains(photo.file) {
                Text("Can't read this image").font(.caption).foregroundStyle(.red)
            }
            ChipFlow(spacing: 4) {
                ForEach(Array(photo.rules.enumerated()), id: \.offset) { index, rule in
                    Button { editing = EditedRule(index: index, rule: rule) } label: {
                        Text(rule.chipText(from: today))
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Button { adding = true } label: {
                    Text("+ When")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .overlay(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3])).foregroundStyle(.tertiary))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $adding, arrowEdge: .bottom) {
                    WhenPopover(photoTitle: photo.title, southern: background.library.southern) { rule in
                        setRules(WhenPresets.apply(rule, to: photo.rules))
                        adding = false
                    }
                }
            }
        }
        .draggable(background.store.url(of: photo.file))
        .dropDestination(for: URL.self) { urls, _ in
            background.drop(urls, onto: photo)
            return true
        }
        .contextMenu {
            Button("Show today") { background.override(Candidate.photo(photo).id) }
            Button("Rename…") { newTitle = photo.title; renaming = true }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([background.store.url(of: photo.file)]) }
            Divider()
            Button("Remove") {
                background.store.remove(photo.file)
                background.refresh()
            }
        }
        .sheet(item: $editing) { edited in
            RuleEditorSheet(initial: edited.rule, onSave: { rule in
                var rules = photo.rules
                rules[edited.index] = rule
                setRules(rules)
            }, onRemove: {
                var rules = photo.rules
                rules.remove(at: edited.index)
                setRules(rules)
            })
        }
        .alert("Rename photo", isPresented: $renaming) {
            TextField("Name", text: $newTitle)
            Button("Rename") {
                background.store.setTitle(newTitle, for: photo.file)
                background.refresh()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func setRules(_ rules: [TimingRule]) {
        background.store.setRules(rules, for: photo.file)
        background.refresh()
    }
}

struct EditedRule: Identifiable {
    let index: Int
    let rule: TimingRule
    var id: Int { index }
}

/// Today as a civil day, for chip text.
var today: CivilDay { CivilDay(Date(), timeZone: .current) }

/// Wraps chips onto as many lines as they need.
struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 240
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            row = max(row, size.height)
        }
        return CGSize(width: min(widest, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
