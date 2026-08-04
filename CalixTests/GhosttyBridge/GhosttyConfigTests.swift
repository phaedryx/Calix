// GhosttyConfigTests.swift
// CalixTests
//
// Tests for GhosttyConfigManager preset template and migration helpers.
// Verifies deprecated keys are removed from preset and existing configs.

import Testing
@testable import Calix

@MainActor
@Suite("GhosttyConfig Tests")
struct GhosttyConfigTests {

    // MARK: - Preset Template Tests

    @Test("Glass preset template does not contain cursor-click-to-move")
    func glassPresetTemplateDoesNotContainCursorClickToMove() {
        let template = GhosttyConfigManager.glassPresetTemplate
        #expect(!template.contains("cursor-click-to-move"),
                "Glass preset template should not contain cursor-click-to-move (ghostty default is used)")
    }

    @Test("Glass preset template does not contain font-thicken")
    func glassPresetTemplateDoesNotContainFontThicken() {
        let template = GhosttyConfigManager.glassPresetTemplate
        #expect(!template.contains("font-thicken"),
                "Glass preset template should not contain font-thicken (ghostty default is used)")
    }

    @Test("Glass preset template does not contain minimum-contrast")
    func glassPresetTemplateDoesNotContainMinimumContrast() {
        let template = GhosttyConfigManager.glassPresetTemplate
        #expect(!template.contains("minimum-contrast"),
                "Glass preset template should not contain minimum-contrast (ghostty default is used)")
    }

    // MARK: - Migration Tests

    @Test("removeCursorClickToMoveLine removes 'cursor-click-to-move = true'")
    func removeCursorClickToMoveLineRemovesTrue() {
        let input = """
        # --- Calix Glass Preset (managed) ---
        background-opacity = 0.82
        cursor-click-to-move = true
        # --- End Calix Glass Preset ---
        """
        let result = GhosttyConfigManager.removeCursorClickToMoveLine(from: input)
        #expect(!result.contains("cursor-click-to-move"))
        #expect(result.contains("background-opacity = 0.82"))
        #expect(result.contains("# --- Calix Glass Preset (managed) ---"))
        #expect(result.contains("# --- End Calix Glass Preset ---"))
    }

    @Test("removeCursorClickToMoveLine removes 'cursor-click-to-move = false'")
    func removeCursorClickToMoveLineRemovesFalse() {
        let input = """
        # --- Calix Glass Preset (managed) ---
        background-opacity = 0.82
        cursor-click-to-move = false
        # --- End Calix Glass Preset ---
        """
        let result = GhosttyConfigManager.removeCursorClickToMoveLine(from: input)
        #expect(!result.contains("cursor-click-to-move"))
        #expect(result.contains("background-opacity = 0.82"))
    }

    @Test("removeCursorClickToMoveLine is no-op when line is absent")
    func removeCursorClickToMoveLineNoOpWhenAbsent() {
        let input = """
        # --- Calix Glass Preset (managed) ---
        background-opacity = 0.82
        # --- End Calix Glass Preset ---
        """
        let result = GhosttyConfigManager.removeCursorClickToMoveLine(from: input)
        #expect(result == input)
    }

    @Test("removeCursorClickToMoveLine handles extra whitespace")
    func removeCursorClickToMoveLineHandlesExtraWhitespace() {
        let input = "  cursor-click-to-move = true  \nbackground-opacity = 0.82\n"
        let result = GhosttyConfigManager.removeCursorClickToMoveLine(from: input)
        #expect(!result.contains("cursor-click-to-move"))
        #expect(result.contains("background-opacity = 0.82"))
    }

    // MARK: - removeConfigKeys Tests

    @Test("removeConfigKeys removes exact key matches")
    func removeConfigKeysRemovesExactKeyMatch() {
        let input = """
        background-opacity = 0.82
        font-thicken = true
        background-blur = macos-glass-regular
        minimum-contrast = 1.5
        background-opacity-cells = false
        """
        let result = GhosttyConfigManager.removeConfigKeys(
            ["font-thicken", "minimum-contrast"], from: input
        )
        #expect(!result.contains("font-thicken"))
        #expect(!result.contains("minimum-contrast"))
        #expect(result.contains("background-opacity = 0.82"))
        #expect(result.contains("background-blur = macos-glass-regular"))
        #expect(result.contains("background-opacity-cells = false"))
    }

    @Test("removeConfigKeys preserves comment lines containing key names")
    func removeConfigKeysPreservesCommentLines() {
        let input = """
        # font-thicken = true
        background-opacity = 0.82
        """
        let result = GhosttyConfigManager.removeConfigKeys(
            ["font-thicken"], from: input
        )
        #expect(result.contains("# font-thicken = true"))
        #expect(result.contains("background-opacity = 0.82"))
    }

    @Test("removeConfigKeys handles leading and trailing whitespace")
    func removeConfigKeysHandlesLeadingTrailingWhitespace() {
        let input = "  font-thicken = true  \nbackground-opacity = 0.82\n"
        let result = GhosttyConfigManager.removeConfigKeys(
            ["font-thicken"], from: input
        )
        #expect(!result.contains("font-thicken"))
        #expect(result.contains("background-opacity = 0.82"))
    }

    @Test("removeConfigKeys is no-op when target keys are absent")
    func removeConfigKeysNoOpWhenKeysAbsent() {
        let input = """
        background-opacity = 0.82
        background-blur = macos-glass-regular
        """
        let result = GhosttyConfigManager.removeConfigKeys(
            ["font-thicken", "minimum-contrast"], from: input
        )
        #expect(result == input)
    }

    @Test("removeConfigKeys preserves blank lines")
    func removeConfigKeysPreservesBlankLines() {
        let input = "background-opacity = 0.82\n\nbackground-blur = macos-glass-regular\n"
        let result = GhosttyConfigManager.removeConfigKeys(
            ["font-thicken"], from: input
        )
        #expect(result == input)
    }

    // MARK: - File-Backed Migration Test

    @Test("removeConfigKeys migrates old format file correctly")
    func removeConfigKeysMigratesOldFormatFile() {
        let input = """
        # --- Calix Glass Preset (managed) ---
        background-opacity = 0.82
        background-blur = macos-glass-regular
        font-thicken = true
        minimum-contrast = 1.5
        # --- End Calix Glass Preset ---
        """
        let result = GhosttyConfigManager.removeConfigKeys(
            ["font-thicken", "minimum-contrast", "cursor-click-to-move"], from: input
        )
        #expect(!result.contains("font-thicken"))
        #expect(!result.contains("minimum-contrast"))
        #expect(result.contains("background-opacity = 0.82"))
        #expect(result.contains("background-blur = macos-glass-regular"))
        #expect(result.contains("# --- Calix Glass Preset (managed) ---"))
        #expect(result.contains("# --- End Calix Glass Preset ---"))
    }

    // MARK: - Managed Keys Tests

    @Test("managedKeys contains all expected keys")
    func managedKeysContainsExpectedKeys() {
        let expectedKeys = [
            "background-opacity",
            "background-blur",
            "background-opacity-cells",
            "font-codepoint-map",
            "foreground",
        ]
        let managed = GhosttyConfigManager.managedKeys
        for key in expectedKeys {
            #expect(managed.contains(key), "managedKeys should contain '\(key)'")
        }
    }

    @Test("managedKeys has no duplicates")
    func managedKeysHasNoDuplicates() {
        let managed = GhosttyConfigManager.managedKeys
        let uniqueSet = Set(managed)
        #expect(managed.count == uniqueSet.count,
                "managedKeys has \(managed.count - uniqueSet.count) duplicate(s)")
    }

    @Test("managedKeys covers all keys from glassPresetTemplate")
    func managedKeysCoverGlassPresetTemplate() {
        let template = GhosttyConfigManager.glassPresetTemplate
        let managed = Set(GhosttyConfigManager.managedKeys)

        // Parse key=value lines from the template (skip comments and blank lines)
        let templateKeys = template
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .compactMap { line -> String? in
                guard let eqIndex = line.firstIndex(of: "=") else { return nil }
                return line[line.startIndex..<eqIndex].trimmingCharacters(in: .whitespaces)
            }

        #expect(!templateKeys.isEmpty, "Should have parsed at least one key from glassPresetTemplate")
        for key in templateKeys {
            #expect(managed.contains(key),
                    "managedKeys should contain glass preset key '\(key)'")
        }
    }

    @Test("managedKeys covers all keys from applyRuntimeOverrides output")
    func managedKeysCoverRuntimeOverrides() {
        // The runtime override text is generated inside applyRuntimeOverrides.
        // We verify against the known keys it produces. These are the key names
        // that appear as "key = value" lines in the runtime override block.
        let runtimeKeys = [
            "background-opacity",
            "background-blur",
            "background-opacity-cells",
            "font-codepoint-map",
        ]

        let managed = Set(GhosttyConfigManager.managedKeys)
        for key in runtimeKeys {
            #expect(managed.contains(key),
                    "managedKeys should contain runtime override key '\(key)'")
        }
    }
}

// MARK: - foregroundOverrideLine Tests

@MainActor
@Suite("GhosttyConfigManager.foregroundOverrideLine Tests")
struct GhosttyConfigForegroundOverrideTests {

    @Test("Dark preset returns foreground = #FFFFFF")
    func darkPresetReturnsWhiteForeground() {
        let result = GhosttyConfigManager.foregroundOverrideLine(
            preset: "original",
            customHex: "#000000",
            glassOpacity: 0.7
        )
        #expect(result == "foreground = #FFFFFF",
                "Dark preset 'original' at default opacity should return white foreground")
    }

    @Test("Light custom color returns foreground = #000000")
    func lightCustomReturnsBlackForeground() {
        let result = GhosttyConfigManager.foregroundOverrideLine(
            preset: "custom",
            customHex: "#F0F0F0",
            glassOpacity: 0.7
        )
        #expect(result == "foreground = #000000",
                "Light custom #F0F0F0 at default opacity should return black foreground")
    }

    @Test("Ghostty preset returns nil (no override)")
    func ghosttyPresetReturnsNil() {
        let result = GhosttyConfigManager.foregroundOverrideLine(
            preset: "ghostty",
            customHex: "#AABBCC",
            glassOpacity: 0.5
        )
        #expect(result == nil,
                "Ghostty preset should return nil (foreground managed by user's ghostty config)")
    }

    @Test("Opacity affects foreground decision for light color")
    func opacityAffectsForegroundDecision() {
        // At opacity 0.0, the effective tint is nearly transparent over a dark base,
        // so the result should differ from opacity 1.0 where the color is fully opaque.
        let resultAtZero = GhosttyConfigManager.foregroundOverrideLine(
            preset: "custom",
            customHex: "#F0F0F0",
            glassOpacity: 0.0
        )
        let resultAtOne = GhosttyConfigManager.foregroundOverrideLine(
            preset: "custom",
            customHex: "#F0F0F0",
            glassOpacity: 1.0
        )
        #expect(resultAtZero != resultAtOne,
                "Opacity 0.0 vs 1.0 should produce different foreground decisions for #F0F0F0")
    }
}
