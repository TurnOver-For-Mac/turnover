// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

func logRedactorTests() {
    let a = String(repeating: "Ab1", count: 10)
    test("log mask: each known key shape is masked") {
        let keys = ["sk-proj-" + a, "sk-ant-" + a, "sk-" + a, "ghp_" + a, "gho_" + a, "ghu_" + a, "ghs_" + a, "ghr_" + a,
                    "github_pat_" + a, "xoxb-" + a, "xoxa-" + a, "xoxp-" + a, "xoxr-" + a, "xoxs-" + a,
                    "AKIA" + String(repeating: "A1", count: 8), "AIza" + String(repeating: "Ab1", count: 12) + "x"]
        for k in keys {
            let m = LogRedactor.mask("said \(k) here")
            check(m == "said \(k.prefix(8))…[masked \(k.count - 8)] here", "masked: \(k.prefix(8)) -> \(m)")
        }
    }
    test("log mask: private key line, JWT and long mixed run are masked") {
        check(LogRedactor.mask("pem -----BEGIN RSA PRIVATE KEY-----MIIEvQIBADAN").hasPrefix("pem -----BEG…[masked "), "private key marker")
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        check(LogRedactor.mask("t \(jwt) e") == "t eyJhbGci…[masked \(jwt.count - 8)] e", "jwt")
        let run = String(repeating: "aB3", count: 12)
        check(LogRedactor.mask("k \(run)") == "k aB3aB3aB…[masked \(run.count - 8)]", "long mixed run")
    }
    test("log mask: spoken-text line keeps the rest") {
        let line = "IO speak: \"Your key is sk-proj-\(a) copy it\" (web)"
        let m = LogRedactor.mask(line)
        check(m == "IO speak: \"Your key is sk-proj-…[masked \(a.count)] copy it\" (web)", "rest kept: \(m)")
    }
    test("log mask: ordinary text is unchanged") {
        for s in ["id 123E4567-E89B-12D3-A456-426614174000 ok", "hash da39a3ee5e6b4b0d3255bfef95601890afd80709 ok",
                  "da39a3ee5e6b4b0d3255bfef95601890afd80709abcdef12",
                  "/Users/someone/Library/Application Support/TurnOver/logs/turnover-2026-11-19T101112Z.log",
                  "/Users/someone/Library/Developer/TurnOver/wt-log-mask1/Sources/Core/Support/LogRedactor2.swift",
                  "com.example.SomeVeryLongBundleIdentifier.Helper2.extension.plugin", "task-force sk-short",
                  "The quick brown fox jumps over the lazy dog, then sleeps for a very long time.", ""] {
            check(LogRedactor.mask(s) == s, "unchanged: \(s.prefix(30))")
        }
    }
    test("log mask: masking twice equals masking once") {
        let line = "a sk-proj-\(a) b eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CV c \(String(repeating: "aB3", count: 12)) -----BEGIN PRIVATE KEY-----xyz"
        let once = LogRedactor.mask(line)
        check(once != line && LogRedactor.mask(once) == once, "idempotent")
    }
}
