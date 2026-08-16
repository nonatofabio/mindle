import Foundation

func runSSHProfileChecks() -> Int {
    let c = Checks("SSHProfile")
    let yaml = """
    profiles:
      - name: "test"
        hostname: 'test'
        path: /workspace
        favorite: true
      - name: docs
        hostname: docs.example
        path: /srv/docs # inline comment
    """

    do {
        let profiles = try SSHProfileConfiguration.parse(yaml)
        c.equal(profiles.count, 2, "profile count")
        c.equal(profiles[0].name, "test", "quoted name")
        c.equal(profiles[0].hostname, "test", "quoted hostname")
        c.equal(profiles[0].rootPath, "/workspace", "root path")
        c.expect(profiles[0].favorite, "favorite parsed")
        c.equal(
            SSHProfileConfiguration.favoriteProfile(in: profiles)?.name,
            "test",
            "favorite selected"
        )
        c.equal(
            SSHProfileConfiguration.profile(
                containing: SSHTarget(userHostPath: "docs.example:/srv/docs/book/README.md")!,
                in: profiles
            )?.name,
            "docs",
            "profile root contains nested target"
        )
        c.expect(
            SSHProfileConfiguration.profile(
                containing: SSHTarget(userHostPath: "docs.example:/srv/private/README.md")!,
                in: profiles
            ) == nil,
            "profile root rejects sibling target"
        )
    } catch {
        c.expect(false, "valid YAML failed: \(error)")
    }

    let activeDefaultLines = SSHProfileConfiguration.defaultYAML
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    c.equal(activeDefaultLines, [], "default profile template is fully disabled")
    c.expect(
        !SSHProfileConfiguration.defaultYAML.contains("hostname: test"),
        "default profile template never activates test hostname"
    )
    do {
        _ = try SSHProfileConfiguration.parse(SSHProfileConfiguration.defaultYAML)
        c.expect(false, "disabled default config should contain no profiles")
    } catch SSHProfileConfigurationError.noProfiles {
        c.expect(true, "disabled default config reports no profiles")
    } catch {
        c.expect(false, "disabled default config returned wrong error: \(error)")
    }

    do {
        _ = try SSHProfileConfiguration.parse("""
        profiles:
          - name: bad
            hostname: test
            path: relative
        """)
        c.expect(false, "relative path should fail")
    } catch SSHProfileConfigurationError.invalidPath {
        c.expect(true, "relative path rejected")
    } catch {
        c.expect(false, "relative path returned wrong error: \(error)")
    }

    do {
        _ = try SSHProfileConfiguration.parse("""
        profiles:
          - name: one
            hostname: one
            path: /one
            favorite: true
          - name: two
            hostname: two
            path: /two
            favorite: true
        """)
        c.expect(false, "multiple favorites should fail")
    } catch SSHProfileConfigurationError.duplicateFavorite {
        c.expect(true, "multiple favorites rejected")
    } catch {
        c.expect(false, "multiple favorites returned wrong error: \(error)")
    }

    do {
        _ = try SSHProfileConfiguration.parse("""
        profiles:
          - name: unsafe
            hostname: -oProxyCommand=bad
            path: /workspace
        """)
        c.expect(false, "option-like hostname should fail")
    } catch SSHProfileConfigurationError.invalidHostname {
        c.expect(true, "option-like hostname rejected")
    } catch {
        c.expect(false, "option-like hostname returned wrong error: \(error)")
    }

    if c.failures == 0 { print("✓ SSHProfile: \(c.passed) checks passed") }
    return c.failures
}
