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
        ["image.png", "assets/diagram one.webp", "../shared/chart.svg", "images/logo.png"],
        "relative image extraction"
    )
    c.equal(
        RemoteMarkdownAssets.relativePaths(in: """
        ![query](images/plot.png?raw=1#chart)
        ![query duplicate](images/plot.png)
        ![reserved](images/plot%231%3Ffinal.png)
        ![bad encoding](images/100%.png)
        ![mailto](mailto:test@example.com)
        """),
        ["images/plot.png", "images/plot#1?final.png", "images/100%.png"],
        "paths normalize, deduplicate, and reject URL schemes"
    )

    let document = SSHTarget(userHostPath: "test:/workspace/book/README.md")!
    c.equal(
        RemoteMarkdownAssets.target(for: "image.png", from: document)?.canonical,
        "test:/workspace/book/image.png",
        "sibling image target"
    )
    c.equal(
        RemoteMarkdownAssets.target(for: "../shared/chart.svg", from: document)?.canonical,
        "test:/workspace/shared/chart.svg",
        "parent image target"
    )

    let cache = URL(fileURLWithPath: "/tmp/mindle-ssh-cache", isDirectory: true)
    c.equal(
        document.proxyURL(cacheDir: cache).path,
        cache
            .appendingPathComponent(SSHTarget.fnv1a("test"))
            .appendingPathComponent("workspace/book/README.md")
            .path,
        "remote mirror preserves directory layout"
    )

    if c.failures == 0 { print("✓ RemoteMarkdownAssets: \(c.passed) checks passed") }
    return c.failures
}
