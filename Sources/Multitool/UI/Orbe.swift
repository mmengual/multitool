import AppKit
import SwiftUI

/// Orbe, the design system shared by Maxime's apps, translated to SwiftUI.
/// Source: https://claude.ai/artifact/KFb1xbo3Wy6JoP2htKS8Pw (tokens v3, theme
/// `sombre`, density `compacte`). Views use these tokens only: no color,
/// size or radius is written anywhere else.
enum Orbe {

    // MARK: Accent

    enum Accent {
        case ambre, or, emeraude, jade, lilas

        var clair: Color {
            switch self {
            case .ambre: return Color(hex: 0xE3B567)
            case .or: return Color(hex: 0xE9C769)
            case .emeraude: return Color(hex: 0x56D1A3)
            case .jade: return Color(hex: 0x7DD0C0)
            case .lilas: return Color(hex: 0xC9B8FF)
            }
        }

        /// Text laid on the light accent.
        var surClair: Color {
            switch self {
            case .ambre: return Color(hex: 0x2A1B05)
            case .or: return Color(hex: 0x382C0C)
            case .emeraude: return Color(hex: 0x103627)
            case .jade: return Color(hex: 0x07362F)
            case .lilas: return Color(hex: 0x1E1544)
            }
        }
    }

    /// Multitool's accent. One per app, so it is recognized at a glance.
    static let appAccent: Accent = .lilas
    static var accent: Color { appAccent.clair }
    static var surAccent: Color { appAccent.surClair }

    // MARK: Colors (theme sombre)

    static let chrome = Color(hex: 0x090807)
    static let chrome2 = Color(hex: 0x13120F)
    static let chromeTexte = Color(hex: 0xEDE6D8)
    static let chromeTexte2 = Color(hex: 0xA9A192)
    static let chromeFilet = Color(hex: 0x26231E)
    static let fond = Color(hex: 0x0F0E0C)
    static let surface = Color(hex: 0x15130F)
    static let surfaceHaute = Color(hex: 0x1C1915)
    static let filet = Color(hex: 0x26231E)
    static let filetFort = Color(hex: 0x3A362F)
    static let texte = Color(hex: 0xEDE6D8)
    static let texte2 = Color(hex: 0xA9A192)
    static let hausse = Color(hex: 0x5FCC74)
    static let baisse = Color(hex: 0xFF8578)
    static let alerte = Color(hex: 0xFF9044)
    static let info = Color(hex: 0x51B8FF)
    static let lagon = Color(hex: 0x88D4D3)
    static let orchidee = Color(hex: 0xEDACDE)

    /// Accent opacities for states.
    enum Etat {
        static let survol = 0.06
        static let selection = 0.10
        static let actif = 0.12
        static let haloBordure = 0.45
    }

    // MARK: Spacing, radii, density

    enum Space {
        static let s1: CGFloat = 2, s2: CGFloat = 4, s3: CGFloat = 8, s4: CGFloat = 12
        static let s5: CGFloat = 16, s6: CGFloat = 20, s7: CGFloat = 24, s8: CGFloat = 32
        static let s9: CGFloat = 40, s10: CGFloat = 56, s11: CGFloat = 80
    }

    enum Rayon {
        static let xs: CGFloat = 6, s: CGFloat = 10, m: CGFloat = 12, l: CGFloat = 16
    }

    /// Density `compacte`.
    enum Densite {
        static let ligne: CGFloat = 34
        static let controle: CGFloat = 32
        static let padPanneau: CGFloat = 20
        static let ecart: CGFloat = 12
        static let marge: CGFloat = 24
    }

    static let navigationWidth: CGFloat = 204

    // MARK: Motion

    enum Duree {
        static let instant = 0.08, rapide = 0.14, standard = 0.22, ample = 0.36
    }

    static func animation(_ duration: Double) -> Animation {
        .timingCurve(0.2, 0.7, 0.2, 1, duration: duration)
    }

    // MARK: Typography

    enum Style {
        case display, titre1, titre2, titre3
        case texteL, texte, texteS
        case label, donneeL, donnee, code
    }

    static func font(_ style: Style) -> Font {
        switch style {
        case .display: return .custom("Outfit-Light", size: 44)
        case .titre1: return .custom("Outfit-Medium", size: 32)
        case .titre2: return .custom("Outfit-Medium", size: 22)
        case .titre3: return .custom("Outfit-Medium", size: 17)
        case .texteL: return .custom("Manrope-Regular", size: 15)
        case .texte: return .custom("Manrope-Regular", size: 14)
        case .texteS: return .custom("Manrope-Medium", size: 12)
        case .label: return .custom("JetBrainsMono-Medium", size: 11)
        case .donneeL: return .custom("JetBrainsMono-Medium", size: 22).monospacedDigit()
        case .donnee: return .custom("JetBrainsMono-Regular", size: 13).monospacedDigit()
        case .code: return .custom("JetBrainsMono-Regular", size: 13)
        }
    }

    /// Medium weight of the interface text, for labels of controls.
    static let texteMedium = Font.custom("Manrope-SemiBold", size: 14)

    static func tracking(_ style: Style) -> CGFloat {
        switch style {
        case .display: return 44 * 0.24
        case .titre1: return -0.32
        case .label: return 11 * 0.16
        default: return 0
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

extension View {
    /// Applies an Orbe text style: family, size, tracking, and capitals for
    /// `display` and `label`.
    func orbe(_ style: Orbe.Style, _ color: Color = Orbe.texte) -> some View {
        self.font(Orbe.font(style))
            .tracking(Orbe.tracking(style))
            .textCase(style == .label || style == .display ? .uppercase : nil)
            .foregroundStyle(color)
    }
}

// MARK: - Mark

/// The Orbe mark: a thin ring with an accent dot on its trajectory.
struct OrbeMark: View {
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            Circle().stroke(Orbe.chromeTexte2, lineWidth: 1.2)
            Circle().fill(Orbe.accent)
                .frame(width: size * 0.28, height: size * 0.28)
                .offset(x: size * 0.36, y: -size * 0.36 * 0.55)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Panels and sections

/// Level 1 panel: opaque surface, 1 px filet, large radius. No shadow.
struct OrbePanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(Orbe.surface, in: RoundedRectangle(cornerRadius: Orbe.Rayon.l))
            .overlay(RoundedRectangle(cornerRadius: Orbe.Rayon.l).strokeBorder(Orbe.filet, lineWidth: 1))
    }
}

/// A titled panel with an optional footnote, the building block of the panes.
struct OrbeSection<Content: View>: View {
    let title: String
    var note: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Orbe.Space.s3) {
            Text(title).orbe(.label, Orbe.texte2)
                .padding(.leading, Orbe.Space.s2)
            OrbePanel { content }
            if let note {
                Text(note).orbe(.texteS, Orbe.texte2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Orbe.Space.s2)
            }
        }
    }
}

/// 1 px separator between the rows of a panel.
struct OrbeFilet: View {
    var inset: CGFloat = Orbe.Densite.padPanneau
    var body: some View {
        Rectangle().fill(Orbe.filet).frame(height: 1).padding(.leading, inset)
    }
}

/// One line of a panel: a title, an optional detail, and a trailing control.
struct OrbeRow<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    var icon: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Orbe.Densite.ecart) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(Orbe.accent)
                    .frame(width: 20)
            }
            VStack(alignment: .leading, spacing: Orbe.Space.s1) {
                Text(title).orbe(.texte)
                if let detail {
                    Text(detail).orbe(.texteS, Orbe.texte2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Orbe.Space.s3)
            trailing
        }
        .frame(minHeight: Orbe.Densite.ligne)
        .padding(.horizontal, Orbe.Densite.padPanneau)
        .padding(.vertical, Orbe.Space.s3)
    }
}

extension OrbeRow where Trailing == EmptyView {
    init(title: String, detail: String? = nil, icon: String? = nil) {
        self.init(title: title, detail: detail, icon: icon) { EmptyView() }
    }
}

// MARK: - Controls

/// Bouton: `plein` for the one main action of a zone, `contour` for the
/// others, `discret` for tertiary ones, `danger` to destroy.
struct OrbeButtonStyle: ButtonStyle {
    enum Variante { case plein, contour, discret, danger }
    var variante: Variante = .contour
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        OrbeButtonBody(configuration: configuration, variante: variante, compact: compact)
    }
}

private struct OrbeButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let variante: OrbeButtonStyle.Variante
    let compact: Bool
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .font(Orbe.texteMedium)
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? Orbe.Space.s3 : Orbe.Space.s4)
            .frame(height: compact ? 26 : Orbe.Densite.controle)
            .background(background, in: RoundedRectangle(cornerRadius: Orbe.Rayon.s))
            .overlay(RoundedRectangle(cornerRadius: Orbe.Rayon.s).strokeBorder(border, lineWidth: 1))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: Orbe.Rayon.s))
            .onHover { hover = $0 }
            .animation(Orbe.animation(Orbe.Duree.rapide), value: hover)
            .animation(Orbe.animation(Orbe.Duree.instant), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch variante {
        case .plein: return Orbe.surAccent
        case .contour: return Orbe.texte
        case .discret: return hover ? Orbe.texte : Orbe.texte2
        case .danger: return Orbe.baisse
        }
    }

    private var background: Color {
        switch variante {
        case .plein: return Orbe.accent
        case .discret: return hover ? Orbe.accent.opacity(Orbe.Etat.survol) : .clear
        case .contour, .danger: return hover ? Orbe.surfaceHaute : .clear
        }
    }

    private var border: Color {
        switch variante {
        case .plein, .discret: return .clear
        case .contour: return hover ? Orbe.accent.opacity(Orbe.Etat.haloBordure) : Orbe.filetFort
        case .danger: return Orbe.baisse.opacity(hover ? 0.7 : 0.45)
        }
    }
}

extension ButtonStyle where Self == OrbeButtonStyle {
    static var orbe: OrbeButtonStyle { OrbeButtonStyle() }
    static var orbePlein: OrbeButtonStyle { OrbeButtonStyle(variante: .plein) }
    static var orbeDiscret: OrbeButtonStyle { OrbeButtonStyle(variante: .discret) }
    static var orbeDanger: OrbeButtonStyle { OrbeButtonStyle(variante: .danger) }
}

/// Interrupteur: a full-radius track, accent when on.
struct OrbeSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Orbe.Space.s3) {
            configuration.label
            Capsule()
                .fill(configuration.isOn ? Orbe.accent : Orbe.filetFort)
                .frame(width: 34, height: 20)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(configuration.isOn ? Orbe.surAccent : Orbe.texte2)
                        .frame(width: 14, height: 14)
                        .padding(3)
                }
                .animation(Orbe.animation(Orbe.Duree.rapide), value: configuration.isOn)
                .onTapGesture { configuration.isOn.toggle() }
        }
    }
}

extension ToggleStyle where Self == OrbeSwitchStyle {
    static var orbe: OrbeSwitchStyle { OrbeSwitchStyle() }
}

/// A switch without a visible label.
struct OrbeSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.orbe)
            .opacity(enabled ? 1 : 0.45)
    }
}

/// Groupe segmenté: mutually exclusive options, the current one veiled in accent.
struct OrbeSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: Orbe.Space.s1) {
            ForEach(options.indices, id: \.self) { i in
                let (value, label) = options[i]
                let active = value == selection
                Text(label)
                    .lineLimit(1)
                    .fixedSize()
                    .font(active ? Orbe.texteMedium : Orbe.font(.texte))
                    .foregroundStyle(active ? Orbe.accent : Orbe.texte2)
                    .padding(.horizontal, Orbe.Space.s4)
                    .frame(height: Orbe.Densite.controle - 6)
                    .background(active ? Orbe.accent.opacity(Orbe.Etat.actif) : .clear,
                                in: RoundedRectangle(cornerRadius: Orbe.Rayon.xs))
                    .contentShape(Rectangle())
                    .onTapGesture { selection = value }
            }
        }
        .padding(3)
        .overlay(RoundedRectangle(cornerRadius: Orbe.Rayon.s).strokeBorder(Orbe.filetFort, lineWidth: 1))
        .animation(Orbe.animation(Orbe.Duree.rapide), value: selection)
    }
}

/// A choice in a drop-down menu, drawn as an outlined control.
struct OrbeMenuPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        Menu {
            ForEach(options.indices, id: \.self) { i in
                Button(options[i].1) { selection = options[i].0 }
            }
        } label: {
            HStack(spacing: Orbe.Space.s3) {
                Text(options.first { $0.0 == selection }?.1 ?? "").orbe(.texte)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Orbe.texte2)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(Orbe.texte)
        .fixedSize()
        .padding(.horizontal, Orbe.Space.s4)
        .frame(height: Orbe.Densite.controle)
        .overlay(RoundedRectangle(cornerRadius: Orbe.Rayon.s).strokeBorder(Orbe.filetFort, lineWidth: 1))
    }
}

/// A state: semantic colored dot and short text. `alerte` and `baisse`
/// always carry an icon, as Orbe requires for risks.
struct OrbeBadge: View {
    enum Ton { case hausse, baisse, alerte, info, neutre }
    let ton: Ton
    let text: String

    var body: some View {
        HStack(spacing: Orbe.Space.s3) {
            switch ton {
            case .alerte:
                Image(systemName: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(color)
            case .baisse:
                Image(systemName: "xmark.octagon").font(.system(size: 11)).foregroundStyle(color)
            default:
                Circle().fill(color).frame(width: 7, height: 7)
            }
            Text(text).orbe(.texteS, Orbe.texte2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var color: Color {
        switch ton {
        case .hausse: return Orbe.hausse
        case .baisse: return Orbe.baisse
        case .alerte: return Orbe.alerte
        case .info: return Orbe.info
        case .neutre: return Orbe.filetFort
        }
    }
}

/// A keyboard key, for shortcut hints.
struct OrbeKey: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Orbe.font(.donnee))
            .foregroundStyle(Orbe.texte)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 20)
            .background(Orbe.surfaceHaute, in: RoundedRectangle(cornerRadius: Orbe.Rayon.xs))
            .overlay(RoundedRectangle(cornerRadius: Orbe.Rayon.xs).strokeBorder(Orbe.filetFort, lineWidth: 1))
    }
}

/// Bloc statistique: a label over a figure.
struct OrbeStat: View {
    let label: String
    let value: String
    var color: Color = Orbe.texte

    var body: some View {
        VStack(alignment: .leading, spacing: Orbe.Space.s2) {
            Text(label).orbe(.label, Orbe.texte2)
            Text(value).orbe(.donneeL, color)
        }
    }
}

/// Number with its noun, plural when needed ("1 élément", "3 éléments").
func compte(_ n: Int, _ singulier: String, _ pluriel: String? = nil) -> String {
    "\(n) \(n > 1 ? (pluriel ?? singulier + "s") : singulier)"
}
