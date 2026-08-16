import Foundation

func runRemoteMarkdownAssetsChecks() -> Int {
    let c = Checks("RemoteMarkdownAssets")
    let markdown = """
    ![plain](image.png)
    ![nested](assets/diagram%20one.webp "Diagram")
    ![parent](../shared/chart.svg)
    ![remote](https://example.com/no.png)
    ![absolute](/srv/static/no.png)
    ![brand][logo]
    [logo]: <images/logo.png>
    [ordinary-link]: docs/readme.md
    """
    c.equal(
        RemoteMarkdownAssets.relativePaths(in: markdown),
        [
            "image.png",
            "assets/diagram one.webp",
            "../shared/chart.svg",
            "https://example.com/no.png",
            "/srv/static/no.png",
            "images/logo.png"
        ],
        "image extraction and percent decoding"
    )

    let root = SSHTarget(userHostPath: "test:/workspace")!
    let document = SSHTarget(userHostPath: "test:/workspace/book/README.md")!
    do {
        c.equal(
            try RemoteMarkdownAssets.target(
                for: "image.png",
                from: document,
                confinedTo: root
            ).canonical,
            "test:/workspace/book/image.png",
            "sibling image target"
        )
        c.equal(
            try RemoteMarkdownAssets.target(
                for: "../shared/chart.svg",
                from: document,
                confinedTo: root
            ).canonical,
            "test:/workspace/shared/chart.svg",
            "parent image stays inside root"
        )
        c.equal(
            try RemoteMarkdownAssets.target(
                for: "images/plot%23final%3F2.png",
                from: document,
                confinedTo: root
            ).canonical,
            "test:/workspace/book/images/plot#final?2.png",
            "encoded filename characters preserved"
        )
    } catch {
        c.expect(false, "valid remote image path failed: \(error)")
    }

    let escapingPaths = [
        "../../outside.png",
        "%2e%2e/%2e%2e/outside.png",
        "%252e%252e/%252e%252e/outside.png",
        "..%2f..%2foutside.png",
        "../%2e%2e/outside.png"
    ]
    for path in escapingPaths {
        do {
            _ = try RemoteMarkdownAssets.target(
                for: path,
                from: document,
                confinedTo: root
            )
            c.expect(false, "root escape should fail: \(path)")
        } catch RemoteAssetPathError.outsideProfileRoot {
            c.expect(true, "root escape rejected: \(path)")
        } catch {
            c.expect(false, "root escape returned wrong error for \(path): \(error)")
        }
    }

    for path in ["notes.txt", "diagram.pdf", ".ssh/id_rsa", "image.png.exe"] {
        do {
            _ = try RemoteMarkdownAssets.target(
                for: path,
                from: document,
                confinedTo: root
            )
            c.expect(false, "unsupported image extension should fail: \(path)")
        } catch RemoteAssetPathError.unsupportedExtension {
            c.expect(true, "unsupported image extension rejected: \(path)")
        } catch {
            c.expect(false, "unsupported extension returned wrong error for \(path): \(error)")
        }
    }

    do {
        _ = try RemoteMarkdownAssets.target(
            for: "image.png",
            from: SSHTarget(userHostPath: "test:/outside/README.md")!,
            confinedTo: root
        )
        c.expect(false, "document outside root should fail")
    } catch RemoteAssetPathError.outsideProfileRoot {
        c.expect(true, "document outside root rejected")
    } catch {
        c.expect(false, "document outside root returned wrong error: \(error)")
    }

    c.equal(
        RemoteMarkdownAssets.allowedExtensions,
        ["avif", "gif", "jpeg", "jpg", "png", "svg", "webp"],
        "explicit image extension allowlist"
    )
    c.equal(RemoteMarkdownAssets.maxAssetsPerDocument, 32, "explicit per-document fetch cap")

    if c.failures == 0 { print("✓ RemoteMarkdownAssets: \(c.passed) checks passed") }
    return c.failures
}
