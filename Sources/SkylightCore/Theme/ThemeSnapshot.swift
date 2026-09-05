import Foundation

/// Everything an import is allowed to overwrite, captured immediately before
/// it does.
///
/// The ratified rule is that **an import wins**: choosing a theme means "make
/// it look like this", so it overrides palette, opacity, font, appearance and
/// chrome even where the user had set those by hand. That is only a
/// defensible rule if getting back is one click, which is what this is.
///
/// Every field the import lane can touch has to be in here. A snapshot that
/// captures most of them restores most of what someone had and quietly keeps
/// the rest — worse than offering no revert at all, because it looks like it
/// worked.
public struct ThemeSnapshot: Codable, Equatable, Sendable {
    public var appearance: String?          // system | light | dark
    public var windowBackground: String?    // glass | flat
    public var terminalOpacity: Double?
    public var terminalFontSize: Int?
    public var fontFamily: String?
    public var lightTheme: String?
    public var darkTheme: String?
    /// Preserve the actual palettes when importing another theme with the
    /// same name. Older snapshots have only names and remain readable.
    public var lightThemeValues: SkylightTheme?
    public var darkThemeValues: SkylightTheme?

    public init(appearance: String?, windowBackground: String?,
                terminalOpacity: Double?, terminalFontSize: Int?,
                fontFamily: String?, lightTheme: String?, darkTheme: String?,
                lightThemeValues: SkylightTheme? = nil, darkThemeValues: SkylightTheme? = nil) {
        self.appearance = appearance
        self.windowBackground = windowBackground
        self.terminalOpacity = terminalOpacity
        self.terminalFontSize = terminalFontSize
        self.fontFamily = fontFamily
        self.lightTheme = lightTheme
        self.darkTheme = darkTheme
        self.lightThemeValues = lightThemeValues
        self.darkThemeValues = darkThemeValues
    }

    enum CodingKeys: String, CodingKey {
        case appearance, windowBackground, terminalOpacity, terminalFontSize
        case fontFamily, lightTheme, darkTheme
        case lightThemeValues, darkThemeValues
    }

    /// Nils are written EXPLICITLY, which the synthesized encoder would not do.
    /// On disk, `"lightTheme": null` says "captured, and it was unset"; an
    /// absent key says "this field was never captured at all". Those are
    /// different bugs and a snapshot file should not blur them — this is the
    /// one artifact someone will read when a revert did not restore what they
    /// expected.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(appearance, forKey: .appearance)
        try container.encode(windowBackground, forKey: .windowBackground)
        try container.encode(terminalOpacity, forKey: .terminalOpacity)
        try container.encode(terminalFontSize, forKey: .terminalFontSize)
        try container.encode(fontFamily, forKey: .fontFamily)
        try container.encode(lightTheme, forKey: .lightTheme)
        try container.encode(darkTheme, forKey: .darkTheme)
        try container.encodeIfPresent(lightThemeValues, forKey: .lightThemeValues)
        try container.encodeIfPresent(darkThemeValues, forKey: .darkThemeValues)
    }
}

/// One slot, and the rules around it.
///
/// Revert undoes the latest successful import. Later hand edits retain that
/// undo point; another import replaces it. This is one slot, not an undo stack.
public struct ThemeSnapshotStore: Equatable, Sendable {
    private var snapshot: ThemeSnapshot?

    public init(snapshot: ThemeSnapshot? = nil) {
        self.snapshot = snapshot
    }

    public var canRevert: Bool { snapshot != nil }

    /// The stored snapshot, for persisting it beside the themes.
    public var stored: ThemeSnapshot? { snapshot }

    /// Called immediately before an import applies. A second import replaces
    /// the first — see the type's note on why there is no stack.
    public mutating func capture(_ values: ThemeSnapshot) {
        snapshot = values
    }

    /// A hand edit made after an import. It is the newest deliberate act and
    /// stands on its own, but it must NOT cost the ability to undo the import
    /// — someone nudging the opacity slider has not agreed to keep the theme.
    ///
    /// It does NOTHING today, deliberately and visibly: "keep the snapshot" is
    /// already what happens if nobody calls anything. The method exists so the
    /// call sites state the intent, and so the test that pins it has something
    /// to call — but nobody should read `store.noteHandEdit()` and believe a
    /// rule is being enforced here. The day a hand edit needs to affect the
    /// snapshot, this is where it goes and the test is already written.
    public mutating func noteHandEdit() {}

    /// Restore, and consume. Offering "revert" again once everything is back
    /// would restore the values the revert itself just replaced.
    public mutating func revert() -> ThemeSnapshot? {
        defer { snapshot = nil }
        return snapshot
    }
}
