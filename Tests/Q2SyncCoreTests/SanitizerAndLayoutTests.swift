//
//  SanitizerAndLayoutTests.swift
//  Q2-Sync › Tests
//
//  PURPOSE
//  Tests for FAT/exFAT-safe names and the card folder layout.
//

import Foundation
import Testing
@testable import Q2SyncCore

@Suite("Filename sanitizer")
struct FilenameSanitizerTests {

    @Test("Forbidden characters become underscores")
    func forbidden() {
        #expect(FilenameSanitizer.sanitizeComponent("AC/DC", fallback: "X") == "AC_DC")
        #expect(FilenameSanitizer.sanitizeComponent(#"a\b:c*d?e"f<g>h|i"#, fallback: "X") == "a_b_c_d_e_f_g_h_i")
        #expect(FilenameSanitizer.sanitizeComponent("tab\there\nnew", fallback: "X") == "tab_here_new")
    }

    @Test("Trailing dots and spaces are removed; leading dot is replaced")
    func ends() {
        #expect(FilenameSanitizer.sanitizeComponent("  Album. . ", fallback: "X") == "Album")
        #expect(FilenameSanitizer.sanitizeComponent("...And Justice", fallback: "X") == "_..And Justice")
        #expect(FilenameSanitizer.sanitizeComponent(".hidden", fallback: "X") == "_hidden")
    }

    @Test("DOS device names get an underscore")
    func deviceNames() {
        #expect(FilenameSanitizer.sanitizeComponent("CON", fallback: "X") == "CON_")
        #expect(FilenameSanitizer.sanitizeComponent("nul.txt", fallback: "X") == "nul.txt_")
        #expect(FilenameSanitizer.sanitizeComponent("Console", fallback: "X") == "Console")
    }

    @Test("Empty or all-junk names use the fallback")
    func fallback() {
        #expect(FilenameSanitizer.sanitizeComponent("", fallback: "Unknown Artist") == "Unknown Artist")
        #expect(FilenameSanitizer.sanitizeComponent(" . . ", fallback: "Unknown Album") == "Unknown Album")
    }

    @Test("Unicode is normalised to NFC")
    func nfc() {
        let decomposed = "Beyonce\u{0301}" // e + combining acute
        let result = FilenameSanitizer.sanitizeComponent(decomposed, fallback: "X")
        #expect(result == "Beyonc\u{00E9}")
        #expect(Array(result.utf8) == Array("Beyoncé".precomposedStringWithCanonicalMapping.utf8))
    }

    @Test("Long names are cut by UTF-8 bytes without splitting characters")
    func truncation() {
        let long = String(repeating: "é", count: 80) // 160 bytes
        let result = FilenameSanitizer.sanitizeComponent(long, fallback: "X")
        #expect(result.utf8.count <= FilenameSanitizer.maximumComponentBytes)
        #expect(result == String(repeating: "é", count: 50))
        let emoji = String(repeating: "🎸", count: 30) // 4 bytes each
        #expect(FilenameSanitizer.truncate(emoji, maximumBytes: 10) == "🎸🎸")
    }

    @Test("File names keep a lowercase extension within the limit")
    func fileNames() {
        let name = FilenameSanitizer.sanitizeFileName(base: String(repeating: "x", count: 200), fileExtension: "MP3")
        #expect(name.hasSuffix(".mp3"))
        #expect(name.utf8.count == FilenameSanitizer.maximumComponentBytes)
        #expect(FilenameSanitizer.sanitizeFileName(base: "01 What?", fileExtension: "m4a") == "01 What_.m4a")
    }
}

@Suite("Card layout")
struct CardLayoutTests {

    let layout = CardLayout(profile: .q2Pod)

    /// A track with a real-looking file URL (never opened in these tests).
    func track(title: String = "Hello", artist: String = "Adele", album: String = "25",
               number: Int = 1, disc: Int = 1, discs: Int = 1, ext: String = "m4a") -> Track {
        Track(id: "T", title: title, artist: artist, albumArtist: artist, album: album, genre: nil,
              trackNumber: number, discNumber: disc, discCount: discs, isCompilation: false,
              durationSeconds: 1, fileSize: 1, fileURL: URL(filePath: "/tmp/x.\(ext)"),
              fileKind: nil, modifiedDate: nil, availability: .available)
    }

    @Test("Single-disc albums use “01 Title.ext”")
    func singleDisc() {
        #expect(layout.preferredPath(for: track()) == "Music/Adele/25/01 Hello.m4a")
    }

    @Test("Multi-disc albums add the disc number")
    func multiDisc() {
        #expect(layout.preferredPath(for: track(number: 3, disc: 2, discs: 2, ext: "MP3"))
                == "Music/Adele/25/2-03 Hello.mp3")
    }

    @Test("Unknown track numbers have no prefix; unsafe tags are cleaned")
    func noNumber() {
        #expect(layout.preferredPath(for: track(title: "Why?", artist: "AC/DC", album: "Live.", number: 0))
                == "Music/AC_DC/Live/Why_.m4a")
    }

    @Test("Variants number the file name and are recognised again")
    func variants() {
        let path = "Music/A/B/01 Intro.mp3"
        let second = CardLayout.variant(of: path, number: 2)
        #expect(second == "Music/A/B/01 Intro (2).mp3")
        #expect(CardLayout.isSameOrVariant(second, of: path))
        #expect(CardLayout.isSameOrVariant("music/a/b/01 INTRO.mp3", of: path))
        #expect(!CardLayout.isSameOrVariant("Music/A/B/01 Outro (2).mp3", of: path))
        #expect(!CardLayout.isSameOrVariant("Music/A/C/01 Intro (2).mp3", of: path))
    }

    @Test("Device paths use the Q2's mount point")
    func devicePath() {
        #expect(layout.devicePath(for: "Music/A/B/01 X.mp3") == "/mnt/mmc/Music/A/B/01 X.mp3")
    }
}
