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
    } catch {
        c.expect(false, "valid YAML failed: \(error)")
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
        let profiles = try SSHProfileConfiguration.parse("""
        profiles:
          - name: first
            hostname: first
            path: /first
          - name: second
            hostname: second
            path: /second
        """)
        c.equal(
            SSHProfileConfiguration.favoriteProfile(in: profiles)?.name,
            "first",
            "first profile is fallback favorite"
        )
    } catch {
        c.expect(false, "fallback favorite fixture failed: \(error)")
    }

    do {
        _ = try SSHProfileConfiguration.parse("profiles:\n")
        c.expect(false, "empty profile list should fail")
    } catch SSHProfileConfigurationError.noProfiles {
        c.expect(true, "empty profile list rejected")
    } catch {
        c.expect(false, "empty profile list returned wrong error: \(error)")
    }

    do {
        _ = try SSHProfileConfiguration.parse("""
        profiles:
          - name: bad
            hostname: test
            path: /workspace
            favorite: yes
        """)
        c.expect(false, "non-boolean favorite should fail")
    } catch SSHProfileConfigurationError.invalidFavorite {
        c.expect(true, "non-boolean favorite rejected")
    } catch {
        c.expect(false, "non-boolean favorite returned wrong error: \(error)")
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
