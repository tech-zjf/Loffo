import AppKit
import LoffoDesignSystem
import LoffoDomain
import SwiftUI

struct CommitSummary: View {
    let commits: [FileCommit]
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("Last commit")).font(.system(size: 13, weight: .medium))
            if let first = commits.first {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(LoffoPalette.accent)
                    Text(first.subject).help(first.subject).font(.system(size: 12)).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(first.id, forType: .string)
                    } label: {
                        HStack(spacing: 4) {
                            Text(first.id).font(.system(size: 10, design: .monospaced))
                            Image(systemName: "square.on.square").font(.system(size: 8))
                        }.padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.black.opacity(0.025), in: RoundedRectangle(cornerRadius: 4))
                    }.buttonStyle(.plain).help(L10n.text("Copy commit ID"))
                        .accessibilityLabel(L10n.text("Copy commit ID"))
                    if let date = first.committedAt {
                        Text("·")
                        CommitTime(date: date)
                    }
                }.font(.system(size: 10)).foregroundStyle(LoffoPalette.secondary).padding(.leading, 24)
            } else {
                Text(error ?? L10n.text("No local history")).foregroundStyle(LoffoPalette.secondary)
            }
        }
    }
}

struct FileHistoryList: View {
    let commits: [FileCommit]
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label(L10n.text("File history"), systemImage: "clock")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 9))
                    .foregroundStyle(LoffoPalette.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(commits.enumerated()), id: \.element.id) { index, commit in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 0) {
                            Circle().fill(
                                index == 0 ? LoffoPalette.accent : LoffoPalette.secondary.opacity(0.45)
                            )
                            .frame(width: index == 0 ? 9 : 5, height: index == 0 ? 9 : 5)
                            .frame(width: 12, height: 12)
                            Rectangle().fill(LoffoPalette.border.opacity(0.8)).frame(width: 0.5)
                                .opacity(index < commits.count - 1 ? 1 : 0)
                        }.frame(width: 12)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(commit.id) — \(commit.subject)").help(commit.subject).font(
                                .system(size: 11)
                            ).lineLimit(3)
                            if let date = commit.committedAt { CommitTime(date: date) }
                        }.padding(.bottom, index < commits.count - 1 ? 12 : 0)
                    }.fixedSize(horizontal: false, vertical: true)
                }
                if commits.isEmpty {
                    Text(error ?? L10n.text("No local history")).font(.system(size: 11))
                        .foregroundStyle(LoffoPalette.secondary)
                }
            }
        }
    }
}

private struct CommitTime: View {
    let date: Date
    var body: some View {
        Text(
            date,
            format: .relative(presentation: .numeric, unitsStyle: .abbreviated).locale(
                Locale(identifier: "en"))
        )
        .font(.system(size: 10)).foregroundStyle(LoffoPalette.secondary)
        .help(date.formatted(date: .abbreviated, time: .standard))
        .environment(\.locale, Locale(identifier: "en"))
    }
}
