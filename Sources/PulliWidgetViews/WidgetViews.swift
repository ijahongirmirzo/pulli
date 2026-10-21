import Foundation
public import PulliProtocol
public import SwiftUI
public import WidgetKit

/// An 18 pt rounded-square mark with accent fill and a white downward arrow.
public struct WidgetMark: View {
    var accent: Color

    public init(accent: Color) {
        self.accent = accent
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(accent)
                .widgetAccentable()
            Image(systemName: "arrow.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 18, height: 18)
    }
}

/// A 6 pt progress bar capsule.
public struct ProgressBar: View {
    var fraction: Double
    var tint: WidgetSnapshot.Copy.Tint
    var dark: Bool

    @Environment(\.widgetRenderingMode) private var renderingMode

    public init(fraction: Double, tint: WidgetSnapshot.Copy.Tint, dark: Bool) {
        self.fraction = fraction
        self.tint = tint
        self.dark = dark
    }

    public var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let clamped = min(max(fraction, 0), 1)
            let barWidth = clamped > 0 ? max(6, width * clamped) : 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(renderingMode == .accented ? WidgetTheme.textPrimary(dark: dark).opacity(0.18) : WidgetTheme.track(dark: dark))
                if barWidth > 0 {
                    Capsule()
                        .fill(tint == .paused ? WidgetTheme.pausedAmber : WidgetTheme.accent(dark: dark))
                        .frame(width: barWidth)
                        .widgetAccentable(tint != .paused)
                }
            }
        }
        .frame(height: 6)
    }
}

/// An action pill with accent fill, white text and an arrow icon.
public struct AccentPill: View {
    var title: String
    var dark: Bool
    var actionURL: String

    public init(title: String, dark: Bool, actionURL: String = "pulli://copy-new") {
        self.title = title
        self.dark = dark
        self.actionURL = actionURL
    }

    public var body: some View {
        Link(destination: URL(string: actionURL)!) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            // Dark ink on the light dark-mode accent: white on #7C93F7 is too faint to read.
            .foregroundStyle(dark ? Color(red: 0.071, green: 0.078, blue: 0.165) : .white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(WidgetTheme.accent(dark: dark))
                    .widgetAccentable()
            )
        }
        .buttonStyle(.plain)
    }
}

/// A subtle quiet pill button for opening the app.
public struct QuietPill: View {
    var title: String
    var dark: Bool
    var actionURL: String

    @Environment(\.widgetRenderingMode) private var renderingMode

    public init(title: String = "Open Pulli", dark: Bool, actionURL: String = "pulli://open") {
        self.title = title
        self.dark = dark
        self.actionURL = actionURL
    }

    public var body: some View {
        Link(destination: URL(string: actionURL)!) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(WidgetTheme.textPrimary(dark: dark))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(renderingMode == .accented ? WidgetTheme.textPrimary(dark: dark).opacity(0.10) : WidgetTheme.quietFill(dark: dark))
                )
        }
        .buttonStyle(.plain)
    }
}

/// The small desktop widget: phone status, running copy, or a prompt to connect.
public struct SmallView: View {
    public var snapshot: WidgetSnapshot?

    @Environment(\.colorScheme) private var colorScheme

    public init(snapshot: WidgetSnapshot?) {
        self.snapshot = snapshot
    }

    private var dark: Bool { colorScheme == .dark }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: rounded mark + "Pulli"
            HStack(spacing: 6) {
                WidgetMark(accent: WidgetTheme.accent(dark: dark))
                Text("Pulli")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(WidgetTheme.textPrimary(dark: dark))
                Spacer()
            }

            Spacer(minLength: 8)

            // Content sits at the bottom
            if let copies = snapshot?.copies, let copy = copies.first {
                // State 2: Copying
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(Int((copy.fraction * 100).rounded()))%")
                        .font(.system(size: 26, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(WidgetTheme.textPrimary(dark: dark))
                        .lineLimit(1)

                    Text("\(copy.title) · \(copy.detail)")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(WidgetTheme.textSecondary(dark: dark))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    ProgressBar(fraction: copy.fraction, tint: copy.tint, dark: dark)
                        .padding(.top, 2)
                }
            } else if let phone = snapshot?.phone {
                // State 1: Phone connected, nothing copying
                VStack(alignment: .leading, spacing: 2) {
                    Text(phone)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(WidgetTheme.textPrimary(dark: dark))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    let subtitle: String = {
                        if let newPhotos = snapshot?.newPhotos {
                            if newPhotos > 0 {
                                return "\(newPhotos) new \(newPhotos == 1 ? "photo" : "photos")"
                            } else {
                                return "Everything is copied"
                            }
                        } else if let photos = snapshot?.photos {
                            return "\(photos) \(photos == 1 ? "photo" : "photos")"
                        } else {
                            return "Connected"
                        }
                    }()

                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(WidgetTheme.textSecondary(dark: dark))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    if let newPhotos = snapshot?.newPhotos, newPhotos > 0 {
                        AccentPill(title: "Copy new", dark: dark, actionURL: "pulli://copy-new")
                            .padding(.top, 6)
                    }
                }
            } else {
                // State 3: No phone
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "cable.connector")
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(WidgetTheme.accent(dark: dark))
                        .widgetAccentable()

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Plug in your phone")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(WidgetTheme.textPrimary(dark: dark))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)

                        if let lastCopy = snapshot?.lastCopy {
                            Text("Last copy: \(WidgetTheme.relativeDay(for: lastCopy.date))")
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(WidgetTheme.textSecondary(dark: dark))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// The medium desktop widget: copies with progress bars, ready state with actions, or cable guidance.
public struct MediumView: View {
    public var snapshot: WidgetSnapshot?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode

    public init(snapshot: WidgetSnapshot?) {
        self.snapshot = snapshot
    }

    private var dark: Bool { colorScheme == .dark }

    public var body: some View {
        let copies = snapshot?.copies ?? []
        let isCopying = !copies.isEmpty

        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                WidgetMark(accent: WidgetTheme.accent(dark: dark))

                let headerTitle: String = {
                    if isCopying {
                        return snapshot?.phone.map { "Pulli · copying from \($0)" } ?? "Pulli · copying"
                    } else {
                        return "Pulli"
                    }
                }()

                Text(headerTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(WidgetTheme.textPrimary(dark: dark))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 4)

                if let hint = snapshot?.hint, !hint.isEmpty {
                    Text(hint)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(renderingMode == .accented ? WidgetTheme.textPrimary(dark: dark) : WidgetTheme.hintText(dark: dark))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(renderingMode == .accented ? WidgetTheme.textPrimary(dark: dark).opacity(0.12) : WidgetTheme.hintFill(dark: dark))
                        )
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            Spacer(minLength: 8)

            // Content
            if isCopying {
                // State 2: Copying
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(copies.prefix(2)) { copy in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(copy.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(WidgetTheme.textPrimary(dark: dark))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)

                                Spacer(minLength: 8)

                                Text(WidgetTheme.copyDetail(copy))
                                    .font(.system(size: 12, weight: .regular))
                                    .monospacedDigit()
                                    .foregroundStyle(WidgetTheme.textSecondary(dark: dark))
                                    .lineLimit(1)
                            }

                            ProgressBar(fraction: copy.fraction, tint: copy.tint, dark: dark)
                        }
                    }

                    QuietPill(title: "Open Pulli", dark: dark, actionURL: "pulli://open")
                        .padding(.top, 2)
                }
            } else if let phone = snapshot?.phone {
                // State 1: Phone connected, nothing copying
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(phone) is ready")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(WidgetTheme.textPrimary(dark: dark))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)

                            let subtitle: String = {
                                if let photos = snapshot?.photos, let newPhotos = snapshot?.newPhotos {
                                    let photoCount = "\(photos) \(photos == 1 ? "photo" : "photos")"
                                    if newPhotos > 0 {
                                        return "\(photoCount) · \(newPhotos) new since your last copy"
                                    } else {
                                        return "\(photoCount) · everything is copied"
                                    }
                                } else if let photos = snapshot?.photos {
                                    return "\(photos) \(photos == 1 ? "photo" : "photos")"
                                } else {
                                    return "Ready to copy"
                                }
                            }()

                            Text(subtitle)
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(WidgetTheme.textSecondary(dark: dark))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }

                        HStack(spacing: 8) {
                            if let newPhotos = snapshot?.newPhotos, newPhotos > 0 {
                                AccentPill(title: "Copy \(newPhotos) new", dark: dark, actionURL: "pulli://copy-new")
                            }
                            QuietPill(title: "Open Pulli", dark: dark, actionURL: "pulli://open")
                        }
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 40, weight: .regular))
                        .foregroundStyle(WidgetTheme.accent(dark: dark))
                        .widgetAccentable()
                }
            } else {
                // State 3: No phone
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Plug in your phone")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(WidgetTheme.textPrimary(dark: dark))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)

                        let subtitle: String = {
                            let mode = Edition.isAppStore ? "Transferring images" : "File transfer"
                            if let lastCopy = snapshot?.lastCopy {
                                let countStr = lastCopy.files == 1 ? "1 file" : "\(lastCopy.files) files"
                                return "Then choose \(mode) on it. Last copy: \(lastCopy.title), \(WidgetTheme.relativeDay(for: lastCopy.date)), \(countStr)."
                            } else {
                                return "Then choose \(mode) on it."
                            }
                        }()

                        Text(subtitle)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(WidgetTheme.textSecondary(dark: dark))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "cable.connector")
                        .font(.system(size: 40, weight: .regular))
                        .foregroundStyle(WidgetTheme.accent(dark: dark))
                        .widgetAccentable()
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// The widget container body that switches between small and medium views.
public struct WidgetBody: View {
    public var snapshot: WidgetSnapshot?
    public var familyOverride: WidgetFamily?

    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme

    public init(snapshot: WidgetSnapshot?, family: WidgetFamily? = nil) {
        self.snapshot = snapshot
        self.familyOverride = family
    }

    public var body: some View {
        let activeFamily = familyOverride ?? family
        Group {
            if activeFamily == .systemSmall {
                SmallView(snapshot: snapshot)
            } else {
                MediumView(snapshot: snapshot)
            }
        }
        .containerBackground(for: .widget) {
            WidgetTheme.surface(dark: scheme == .dark)
        }
        .widgetURL(URL(string: "pulli://open"))
    }
}
