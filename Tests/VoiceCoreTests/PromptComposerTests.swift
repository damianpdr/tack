import Testing
@testable import VoiceCore

struct PromptComposerTests {
    @Test func contractExample() {
        let a = "/Users/damian/.voice/sessions/X/figure-1.png"
        let b = "/Users/damian/.voice/sessions/X/figure-2.png"
        let prompt = PromptComposer.compose([.text("look at this"), .image(path: a), .text("and this"), .image(path: b), .clip("err 42")])
        #expect(prompt.markdown == """
            look at this [figure 1] and this [figure 2] [clip 1]

            [figure 1]: \(a)
            [figure 2]: \(b)

            [clip 1]:
            ```
            err 42
            ```
            """)
        #expect(prompt.richText == """
            look at this [figure 1] and this [figure 2] [clip 1]

            [clip 1]:
            ```
            err 42
            ```
            """)
        #expect(prompt.figures == [a, b])
    }

    @Test func sameImageReusesNumberAndKindsNumberSeparately() {
        let prompt = PromptComposer.compose([
            .image(path: "/a.png"), .file(path: "/x.txt"), .image(path: "/b.png"), .image(path: "/a.png"), .clip("one"), .clip("two"),
        ])
        #expect(prompt.body == "[figure 1] [file 1] [figure 2] [figure 1] [clip 1] [clip 2]")
        #expect(prompt.figures == ["/a.png", "/b.png"])
        #expect(prompt.markdown.contains("[figure 1]: /a.png\n[figure 2]: /b.png\n[file 1]: /x.txt\n\n[clip 1]:"))
    }

    @Test func fenceOutgrowsBackticksInsideClip() {
        let clip = "run ```swift build``` then ````x````"
        let prompt = PromptComposer.compose([.clip(clip)])
        #expect(prompt.markdown == "[clip 1]\n\n[clip 1]:\n`````\n\(clip)\n`````")
    }

    @Test func pathWithWhitespaceIsWrapped() {
        let prompt = PromptComposer.compose([.image(path: "/tmp/Screen Shot 1.png")])
        #expect(prompt.markdown == "[figure 1]\n\n[figure 1]: </tmp/Screen Shot 1.png>")
    }

    @Test func singleTextIsVerbatim() {
        let text = "  indented\n\tcode  "
        let prompt = PromptComposer.compose([.text(text)])
        #expect(prompt.markdown == text)
        #expect(prompt.richText == text)
        #expect(prompt.body == text)
    }

    @Test func emptyAndBlankTextComposeToEmpty() {
        #expect(PromptComposer.compose([]).markdown == "")
        #expect(PromptComposer.compose([.text("  "), .text("\n")]).markdown == "")
    }

    @Test func multilineTextIsSeparatedByBlankLines() {
        let prompt = PromptComposer.compose([.text("first\nsecond"), .image(path: "/a.png"), .text("tail")])
        #expect(prompt.body == "first\nsecond\n\n[figure 1] tail")
    }
}
