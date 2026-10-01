import Foundation

/// The update check's logic (Foundation only): reading GitHub's latest-release answer and comparing
/// versions. The network request itself is tried by hand (Check for Updates…).
@main struct UpdateChecks {
    static func main() {
        precondition(UpdateCheck.isNewer("1.0", than: "0.9"))
        precondition(UpdateCheck.isNewer("0.10", than: "0.9"), "Numbers, not text")
        precondition(UpdateCheck.isNewer("1.0.1", than: "1.0"))
        precondition(!UpdateCheck.isNewer("1.0", than: "1"), "1.0 is the same as 1")
        precondition(!UpdateCheck.isNewer("0.9", than: "0.9") && !UpdateCheck.isNewer("0.8", than: "0.9"))
        precondition(UpdateCheck.isNewer("2.0 beta", than: "1.9"))

        func json(_ tag: String, draft: Bool = false, prerelease: Bool = false) -> Data {
            Data("""
            {"tag_name": "\(tag)", "html_url": "https://github.com/rahulraogrr/Tidepad/releases/tag/\(tag)",
             "body": "Notes", "draft": \(draft), "prerelease": \(prerelease), "assets": []}
            """.utf8)
        }
        let release = UpdateCheck.release(from: json("v1.0"))
        precondition(release?.version == "1.0" && release?.page.absoluteString.hasSuffix("/tag/v1.0") == true && release?.notes == "Notes", "v1.0")
        precondition(UpdateCheck.release(from: json("1.2"))?.version == "1.2", "Without a v")
        precondition(UpdateCheck.release(from: json("v1.0", draft: true)) == nil, "Drafts are ignored")
        precondition(UpdateCheck.release(from: json("v1.0", prerelease: true)) == nil, "Pre-releases are ignored")
        for page in ["https://github.com/rahulraogrr/Tidepad/releases/tag/v2", "https://GitHub.com/rahulraogrr/Tidepad/releases/latest"] {
            precondition(UpdateCheck.isReleasePage(URL(string: page)!), "TidePad's release page: \(page)")
        }
        for page in ["http://github.com/rahulraogrr/Tidepad/releases/tag/v2", "https://evil.example/rahulraogrr/Tidepad/releases/x",
                     "https://github.com/someone/else/releases/x", "file:///Applications/Calculator.app",
                     "https://github.com.evil.example/rahulraogrr/Tidepad/releases/x", "https://user@github.com/rahulraogrr/Tidepad/releases/x"] {
            precondition(!UpdateCheck.isReleasePage(URL(string: page)!), "Not opened: \(page)")
        }
        precondition(UpdateCheck.release(from: Data("not json".utf8)) == nil && UpdateCheck.release(from: json("v")) == nil, "Bad answers")
        print("Update checks passed: only TidePad's release pages opened, versions compared by number, GitHub's latest release read (tags with and without v, drafts and pre-releases ignored, bad answers).")
    }
}
