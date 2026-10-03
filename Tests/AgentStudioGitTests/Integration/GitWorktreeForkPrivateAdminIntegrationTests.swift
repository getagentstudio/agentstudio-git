import AgentStudioGit
import Darwin
import Foundation
import Testing

@testable import AgentStudioGitLocal

/// A nested linked worktree's configuration can name files in its own private administration. Re-homing
/// re-aims those values at the node's destination administration, so the files they name must exist there:
/// Git silently ignores a missing include or signer file.
@Suite("Git worktree fork private administration integration", .serialized)
struct GitWorktreeForkPrivateAdminIntegrationTests {
    private static let probeAttributeName = "com.example.forklab"

    @Test("files a nested worktree's config names in its private administration are cloned with their metadata")
    func privateAdministrationTargetsAreClonedWithMetadata() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-private-targets")
        let agent = fixture.source.appending(path: ".claude/worktrees/agent")
        let destinationAgent = fixture.destination().appending(path: ".claude/worktrees/agent")
        defer {
            for administration in [fixture.source.appending(path: ".git/worktrees/agent"), destinationAgent] {
                _ = chmod(administration.appending(path: "allowed_signers").path, 0o644)
            }
            fixture.remove()
        }
        try ignore(".claude/", fixture: fixture)
        try fixture.git.run("worktree", "add", "-q", "-b", "agent", agent.path)
        let privateAdministration = try canonical(fixture.source.appending(path: ".git/worktrees/agent"))
        let signers = privateAdministration.appending(path: "allowed_signers")
        let extra = privateAdministration.appending(path: "extra.conf")
        try "agent@example.com ssh-ed25519 AAAAexample\n".write(to: signers, atomically: false, encoding: .utf8)
        try "[agentstudio]\n\tprobe = from-private\n".write(to: extra, atomically: false, encoding: .utf8)
        try #require(setxattr(signers.path, Self.probeAttributeName, "x", 1, 0, XATTR_NOFOLLOW) == 0)
        try #require(chmod(signers.path, 0o444) == 0)
        try fixture.git.run("config", "gpg.ssh.allowedSignersFile", signers.path)
        try fixture.git.run("config", "include.path", extra.path)

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let destinationAdministration = try canonical(destinationAgent.appending(path: ".git"))
        let destinationSigners = destinationAdministration.appending(path: "allowed_signers")
        let destinationExtra = destinationAdministration.appending(path: "extra.conf")
        #expect(try Data(contentsOf: destinationSigners) == Data(contentsOf: signers))
        #expect(try Data(contentsOf: destinationExtra) == Data(contentsOf: extra))
        let signersInfo = try #require(GitWorktreeForkFileProbe.info(destinationSigners))
        #expect(signersInfo.st_mode & 0o7777 == 0o444)
        #expect(getxattr(destinationSigners.path, Self.probeAttributeName, nil, 0, 0, XATTR_NOFOLLOW) == 1)
        #expect(try configValue("gpg.ssh.allowedSignersFile", at: destinationAgent, fixture) == destinationSigners.path)
        #expect(try configValue("agentstudio.probe", at: destinationAgent, fixture) == "from-private")

        // Act: the source files change after the fork.
        try #require(chmod(signers.path, 0o644) == 0)
        try "changed@example.com ssh-ed25519 AAAAchanged\n".write(to: signers, atomically: false, encoding: .utf8)
        try "[agentstudio]\n\tprobe = changed-in-source\n".write(to: extra, atomically: false, encoding: .utf8)

        // Assert: the destination owns its own copies.
        #expect(try String(contentsOf: destinationSigners, encoding: .utf8).hasPrefix("agent@example.com"))
        #expect(try configValue("agentstudio.probe", at: destinationAgent, fixture) == "from-private")
    }

    @Test("a private target wins over a common file of the same name in a flattened node's administration")
    func privateTargetWinsOverSameNamedCommonFile() async throws {
        // Arrange: the flattened node's administration is cloned from the common directory, which holds its own
        // extra.conf and allowed_signers. Git reads the worktree-private files the config names.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-private-wins")
        let agent = fixture.source.appending(path: ".claude/worktrees/agent")
        let destinationAgent = fixture.destination().appending(path: ".claude/worktrees/agent")
        defer {
            for administration in [fixture.source.appending(path: ".git/worktrees/agent"), destinationAgent] {
                _ = chmod(administration.appending(path: "allowed_signers").path, 0o644)
            }
            fixture.remove()
        }
        try ignore(".claude/", fixture: fixture)
        try fixture.git.run("worktree", "add", "-q", "-b", "agent", agent.path)
        let commonAdministration = try canonical(fixture.source.appending(path: ".git"))
        try "common@example.com ssh-ed25519 AAAAcommon\n".write(
            to: commonAdministration.appending(path: "allowed_signers"), atomically: false, encoding: .utf8)
        try "[agentstudio]\n\tprobe = from-common\n".write(
            to: commonAdministration.appending(path: "extra.conf"), atomically: false, encoding: .utf8)
        let privateAdministration = commonAdministration.appending(path: "worktrees/agent")
        let signers = privateAdministration.appending(path: "allowed_signers")
        let extra = privateAdministration.appending(path: "extra.conf")
        try "agent@example.com ssh-ed25519 AAAAprivate\n".write(to: signers, atomically: false, encoding: .utf8)
        try "[agentstudio]\n\tprobe = from-private\n".write(to: extra, atomically: false, encoding: .utf8)
        try #require(setxattr(signers.path, Self.probeAttributeName, "x", 1, 0, XATTR_NOFOLLOW) == 0)
        try #require(chmod(signers.path, 0o444) == 0)
        try fixture.git.run("config", "gpg.ssh.allowedSignersFile", signers.path)
        try fixture.git.run("config", "include.path", extra.path)

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let destinationAdministration = try canonical(destinationAgent.appending(path: ".git"))
        let destinationSigners = destinationAdministration.appending(path: "allowed_signers")
        #expect(try Data(contentsOf: destinationSigners) == Data(contentsOf: signers))
        #expect(
            try Data(contentsOf: destinationAdministration.appending(path: "extra.conf")) == Data(contentsOf: extra))
        let signersInfo = try #require(GitWorktreeForkFileProbe.info(destinationSigners))
        #expect(signersInfo.st_mode & 0o7777 == 0o444)
        #expect(getxattr(destinationSigners.path, Self.probeAttributeName, nil, 0, 0, XATTR_NOFOLLOW) == 1)
        #expect(try configValue("agentstudio.probe", at: destinationAgent, fixture) == "from-private")
    }

    @Test("A58-02: a common file of the same name never stands in for the private include it names")
    func commonFileNeverStandsInForPrivateInclude() async throws {
        // Arrange: the root .git/extra.conf says common-file; the nested worktree's private extra.conf says
        // private-file, and the shared config includes the private one.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-a58-02")
        defer { fixture.remove() }
        try ignore(".claude/", fixture: fixture)
        let agent = fixture.source.appending(path: ".claude/worktrees/agent")
        try fixture.git.run("worktree", "add", "-q", "-b", "agent", agent.path)
        let commonAdministration = try canonical(fixture.source.appending(path: ".git"))
        try "[agentstudio]\n\tmarker = common-file\n".write(
            to: commonAdministration.appending(path: "extra.conf"), atomically: false, encoding: .utf8)
        let privateExtra = commonAdministration.appending(path: "worktrees/agent/extra.conf")
        try "[agentstudio]\n\tmarker = private-file\n".write(to: privateExtra, atomically: false, encoding: .utf8)
        try fixture.git.run("config", "include.path", privateExtra.path)
        #expect(try configValue("agentstudio.marker", at: agent, fixture) == "private-file")
        let sourceConfiguration = try Data(contentsOf: commonAdministration.appending(path: "config"))

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let destinationAgent = fixture.destination().appending(path: ".claude/worktrees/agent")
        #expect(try configValue("agentstudio.marker", at: destinationAgent, fixture) == "private-file")
        #expect(try Data(contentsOf: commonAdministration.appending(path: "config")) == sourceConfiguration)
    }

    @Test(
        "values naming both a flattened node's common and private file of one name need them to agree",
        arguments: CollidingAdministrationContent.allCases)
    func commonAndPrivateReferencesToOneNameMustAgree(content: CollidingAdministrationContent) async throws {
        // Arrange: an external repository's linked worktree nested in the tree is flattened, so its common and
        // private administration both land in one destination .git, and its config includes both extra.conf.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-private-collision")
        defer { fixture.remove() }
        try ignore(".build/", fixture: fixture)
        let upstream = fixture.repository.root.appending(path: "upstream")
        try FileManager.default.createDirectory(at: upstream, withIntermediateDirectories: true)
        try fixture.git.run(["init", "-q"], currentDirectory: upstream)
        try fixture.write("up.txt", "up\n", in: upstream)
        try fixture.git.run(["add", "."], currentDirectory: upstream)
        try fixture.git.run(["commit", "-qm", "initial"], currentDirectory: upstream)
        let linked = fixture.source.appending(path: ".build/linked")
        try fixture.git.run(["worktree", "add", "-q", "-b", "linked", linked.path], currentDirectory: upstream)
        let commonAdministration = try canonical(upstream.appending(path: ".git"))
        let commonExtra = commonAdministration.appending(path: "extra.conf")
        let privateExtra = commonAdministration.appending(path: "worktrees/linked/extra.conf")
        try "[agentstudio]\n\tmarker = shared\n".write(to: commonExtra, atomically: false, encoding: .utf8)
        let privateText =
            content == .identical ? "[agentstudio]\n\tmarker = shared\n" : "[agentstudio]\n\tmarker = private\n"
        try privateText.write(to: privateExtra, atomically: false, encoding: .utf8)
        for include in [commonExtra, privateExtra] {
            try fixture.git.run(["config", "--add", "include.path", include.path], currentDirectory: upstream)
        }
        let sourceConfiguration = try Data(contentsOf: commonAdministration.appending(path: "config"))
        let branchesBefore = try fixture.branchNames()

        // Act
        let failure: GitWorktreeForkError?
        do {
            _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())
            failure = nil
        } catch {
            failure = error
        }

        // Assert
        let destinationLinked = fixture.destination().appending(path: ".build/linked")
        switch content {
        case .different:
            #expect(
                failure
                    == .entryFailed(
                        relativePath: ".build/linked/.git/extra.conf", reason: .unresolvableGitAdministration,
                        errorNumber: nil))
            #expect(!GitWorktreeForkFileProbe.exists(fixture.destination()))
            #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration()))
            #expect(try fixture.branchNames() == branchesBefore)
        case .identical:
            #expect(failure == nil)
            #expect(try configValue("agentstudio.marker", at: destinationLinked, fixture) == "shared")
        }
        #expect(try Data(contentsOf: commonAdministration.appending(path: "config")) == sourceConfiguration)
        #expect(try String(contentsOf: privateExtra, encoding: .utf8) == privateText)
    }

    @Test("a private included config whose path values re-homing rewrites passes validation with its rewritten values")
    func rewrittenPrivateIncludePassesValidation() async throws {
        // Arrange: private extra.conf includes private deeper.conf by absolute source path and names a source-tree
        // lfs.storage, so its destination copy must differ from its source by exactly those relocations.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-private-rewritten")
        defer { fixture.remove() }
        try fixture.write(".gitignore", ".claude/\nlarge-file-store/\n")
        try fixture.git.run("add", ".gitignore")
        try fixture.git.run("commit", "-qm", "ignore agents and storage")
        try fixture.write("large-file-store/objects/placeholder", "stored\n")
        let agent = fixture.source.appending(path: ".claude/worktrees/agent")
        try fixture.git.run("worktree", "add", "-q", "-b", "agent", agent.path)
        let privateAdministration = try canonical(fixture.source.appending(path: ".git/worktrees/agent"))
        let extra = privateAdministration.appending(path: "extra.conf")
        let deeper = privateAdministration.appending(path: "deeper.conf")
        let storage = try canonical(fixture.source.appending(path: "large-file-store"))
        try "[agentstudio]\n\tmarker = private-original\n".write(to: deeper, atomically: false, encoding: .utf8)
        try "[include]\n\tpath = \(deeper.path)\n[lfs]\n\tstorage = \(storage.path)\n".write(
            to: extra, atomically: false, encoding: .utf8)
        try fixture.git.run("config", "include.path", extra.path)
        #expect(try configValue("agentstudio.marker", at: agent, fixture) == "private-original")
        let extraBytes = try Data(contentsOf: extra)

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let destinationAgent = fixture.destination().appending(path: ".claude/worktrees/agent")
        #expect(try configValue("agentstudio.marker", at: destinationAgent, fixture) == "private-original")
        #expect(
            try configValue("lfs.storage", at: destinationAgent, fixture)
                == canonical(fixture.destination().appending(path: "large-file-store")).path)
        #expect(try Data(contentsOf: extra) == extraBytes)
        try "[agentstudio]\n\tmarker = changed-in-source\n".write(to: deeper, atomically: false, encoding: .utf8)
        #expect(try configValue("agentstudio.marker", at: destinationAgent, fixture) == "private-original")
    }

    @Test("a relocated path value repeated around an unrelated one keeps its order and multiplicity")
    func repeatedRelocatedValueKeepsOrderAndMultiplicity() async throws {
        // Arrange: private extra.conf lists one source-tree path, an outside path, and the source-tree path again.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-private-repeated")
        defer { fixture.remove() }
        try fixture.write(".gitignore", ".claude/\nlarge-file-store/\n")
        try fixture.git.run("add", ".gitignore")
        try fixture.git.run("commit", "-qm", "ignore agents and storage")
        try fixture.write("large-file-store/objects/placeholder", "stored\n")
        let agent = fixture.source.appending(path: ".claude/worktrees/agent")
        try fixture.git.run("worktree", "add", "-q", "-b", "agent", agent.path)
        let extra = try canonical(fixture.source.appending(path: ".git/worktrees/agent")).appending(path: "extra.conf")
        let storage = try canonical(fixture.source.appending(path: "large-file-store")).path
        let outside = try canonical(fixture.repository.root).appending(path: "outside-store").path
        try "[agentstudio]\n\tstore = \(storage)\n\tstore = \(outside)\n\tstore = \(storage)\n".write(
            to: extra, atomically: false, encoding: .utf8)
        try fixture.git.run("config", "include.path", extra.path)

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let destinationAgent = fixture.destination().appending(path: ".claude/worktrees/agent")
        let destinationStorage = try canonical(fixture.destination().appending(path: "large-file-store")).path
        #expect(
            try fixture.git.run(["config", "--get-all", "agentstudio.store"], currentDirectory: destinationAgent)
                .split(separator: "\n").map(String.init) == [destinationStorage, outside, destinationStorage])
        #expect(try configValue("agentstudio.store", at: destinationAgent, fixture) == destinationStorage)
    }

    @Test("a private include two nested worktrees reach is realized once and keeps its re-homed values")
    func privateIncludeReachedTwiceIsRealizedOnce() async throws {
        // Arrange: worktrees a and b share the common config, which includes a's private extra.conf; that file
        // names a source-tree lfs.storage the re-homer must relocate in the realized copy.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-private-twice")
        defer { fixture.remove() }
        try fixture.write(".gitignore", ".claude/\nlarge-file-store/\n")
        try fixture.git.run("add", ".gitignore")
        try fixture.git.run("commit", "-qm", "ignore agents and storage")
        try fixture.write("large-file-store/objects/placeholder", "stored\n")
        for name in ["a", "b"] {
            try fixture.git.run(
                "worktree", "add", "-q", "-b", name, fixture.source.appending(path: ".claude/worktrees/\(name)").path)
        }
        let extra = try canonical(fixture.source.appending(path: ".git/worktrees/a")).appending(path: "extra.conf")
        let storage = try canonical(fixture.source.appending(path: "large-file-store"))
        try "[lfs]\n\tstorage = \(storage.path)\n".write(to: extra, atomically: false, encoding: .utf8)
        try fixture.git.run("config", "include.path", extra.path)

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let destinationStorage = try canonical(fixture.destination().appending(path: "large-file-store")).path
        for name in ["a", "b"] {
            let destinationWorktree = fixture.destination().appending(path: ".claude/worktrees/\(name)")
            #expect(try configValue("lfs.storage", at: destinationWorktree, fixture) == destinationStorage, "\(name)")
        }
        try "[lfs]\n\tstorage = /changed-in-source\n".write(to: extra, atomically: false, encoding: .utf8)
        #expect(
            try configValue(
                "lfs.storage", at: fixture.destination().appending(path: ".claude/worktrees/a"), fixture)
                == destinationStorage)
    }

    @Test("a reference to only the common file passes validation beside an unrelated same-named private file")
    func commonOnlyReferenceIgnoresUnrelatedPrivateFile() async throws {
        // Arrange: an external repository's linked worktree under vendor/ is flattened; its config includes only
        // the common extra.conf, while its private administration holds an unreferenced extra.conf.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-common-only")
        defer { fixture.remove() }
        try ignore("vendor/", fixture: fixture)
        let upstream = fixture.repository.root.appending(path: "upstream")
        try FileManager.default.createDirectory(at: upstream, withIntermediateDirectories: true)
        try fixture.git.run(["init", "-q"], currentDirectory: upstream)
        try fixture.write("up.txt", "up\n", in: upstream)
        try fixture.git.run(["add", "."], currentDirectory: upstream)
        try fixture.git.run(["commit", "-qm", "initial"], currentDirectory: upstream)
        let linked = fixture.source.appending(path: "vendor/linked")
        try fixture.git.run(["worktree", "add", "-q", "-b", "linked", linked.path], currentDirectory: upstream)
        let commonAdministration = try canonical(upstream.appending(path: ".git"))
        let commonExtra = commonAdministration.appending(path: "extra.conf")
        try "[agentstudio]\n\tmarker = required-common\n".write(to: commonExtra, atomically: false, encoding: .utf8)
        try "[agentstudio]\n\tmarker = unreferenced-private\n".write(
            to: commonAdministration.appending(path: "worktrees/linked/extra.conf"), atomically: false,
            encoding: .utf8)
        try fixture.git.run(["config", "include.path", commonExtra.path], currentDirectory: upstream)
        #expect(try configValue("agentstudio.marker", at: linked, fixture) == "required-common")

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let destinationLinked = fixture.destination().appending(path: "vendor/linked")
        #expect(try configValue("agentstudio.marker", at: destinationLinked, fixture) == "required-common")
        #expect(
            try Data(contentsOf: canonical(destinationLinked.appending(path: ".git")).appending(path: "extra.conf"))
                == Data(contentsOf: commonExtra))
    }

    @Test(
        "a private counterpart replaced or removed after re-homing fails validation and leaves nothing behind",
        arguments: TamperedCounterpart.allCases)
    func tamperedPrivateCounterpartFailsValidation(tampering: TamperedCounterpart) async throws {
        // Arrange: re-homing clones both private files; a fault then breaks one before validation runs.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-private-tampered")
        defer { fixture.remove() }
        try ignore(".claude/", fixture: fixture)
        let agent = fixture.source.appending(path: ".claude/worktrees/agent")
        try fixture.git.run("worktree", "add", "-q", "-b", "agent", agent.path)
        let privateAdministration = try canonical(fixture.source.appending(path: ".git/worktrees/agent"))
        let signers = privateAdministration.appending(path: "allowed_signers")
        let extra = privateAdministration.appending(path: "extra.conf")
        try "agent@example.com ssh-ed25519 AAAAexample\n".write(to: signers, atomically: false, encoding: .utf8)
        // A repeated key: Git's effective value is the last occurrence, so dropping it changes behavior.
        try "[agentstudio]\n\tprobe = one\n\tprobe = two\n\tprobe = one\n".write(
            to: extra, atomically: false, encoding: .utf8)
        try fixture.git.run("config", "gpg.ssh.allowedSignersFile", signers.path)
        try fixture.git.run("config", "include.path", extra.path)
        let destinationAdministration = fixture.destination().appending(path: ".claude/worktrees/agent/.git")
        let faults = WorktreeForkFaultInjector { point throws(GitWorktreeForkError) in
            guard point == .afterGitStateRehomed else {
                return
            }
            switch tampering {
            case .wrongBytes:
                try? Data("stranger@example.com ssh-ed25519 AAAAstranger\n".utf8)
                    .write(to: destinationAdministration.appending(path: "allowed_signers"))
            case .missing:
                try? FileManager.default.removeItem(at: destinationAdministration.appending(path: "extra.conf"))
            case .includedEntriesChanged:
                try? Data("[agentstudio]\n\tprobe = tampered\n".utf8)
                    .write(to: destinationAdministration.appending(path: "extra.conf"))
            case .repeatedEntryDropped:
                try? Data("[agentstudio]\n\tprobe = one\n\tprobe = two\n".utf8)
                    .write(to: destinationAdministration.appending(path: "extra.conf"))
            }
        }
        let client = LibGit2AgentStudioGitLocalClient(worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults))
        let branchesBefore = try fixture.branchNames()

        // Act
        let failure: GitWorktreeForkError?
        do {
            _ = try await client.forkWorktree(fixture.request())
            failure = nil
        } catch {
            failure = error
        }

        // Assert
        #expect(
            failure
                == .validationFailed(
                    reason: .nestedRepositoryUnusable, relativePath: ".claude/worktrees/agent/.git/config"))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination()))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration()))
        #expect(try fixture.branchNames() == branchesBefore)
    }

    @Test("a nested repository's source administration that cannot be searched at validation fails typed")
    func unsearchableSourceAdministrationFailsValidation() async throws {
        // Arrange: after the destination is built, the nested repository's source .git loses search permission,
        // so its configuration closure can no longer be looked up, let alone read.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-source-unsearchable")
        let sourceAdministration = fixture.source.appending(path: "vendor/tool/.git")
        defer {
            _ = chmod(sourceAdministration.path, 0o755)
            fixture.remove()
        }
        try ignore("vendor/", fixture: fixture)
        try makeNestedRepository(at: fixture.source.appending(path: "vendor/tool"), fixture: fixture)
        let faults = WorktreeForkFaultInjector { point throws(GitWorktreeForkError) in
            if point == .afterIndexesBuilt {
                _ = chmod(sourceAdministration.path, 0o600)
            }
        }
        let client = LibGit2AgentStudioGitLocalClient(worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults))
        let branchesBefore = try fixture.branchNames()

        // Act
        let failure: GitWorktreeForkError?
        do {
            _ = try await client.forkWorktree(fixture.request())
            failure = nil
        } catch {
            failure = error
        }

        // Assert: the walk reaches the node's worktree-scoped root first; either root is unverifiable here.
        #expect(
            failure
                == .validationFailed(
                    reason: .nestedRepositoryUnusable, relativePath: "vendor/tool/.git/config.worktree"))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination()))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration()))
        #expect(try fixture.branchNames() == branchesBefore)
    }

    @Test("a nested repository without config.worktree forks, its absent worktree configuration requiring nothing")
    func nestedRepositoryWithoutWorktreeConfigurationForks() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-no-config-worktree")
        defer { fixture.remove() }
        try ignore("vendor/", fixture: fixture)
        let tool = fixture.source.appending(path: "vendor/tool")
        try makeNestedRepository(at: tool, fixture: fixture)
        #expect(!GitWorktreeForkFileProbe.exists(tool.appending(path: ".git/config.worktree")))

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let destinationTool = fixture.destination().appending(path: "vendor/tool")
        #expect(try fixture.blobID("HEAD", at: destinationTool) == fixture.blobID("HEAD", at: tool))
        #expect(try fixture.statusLines(at: destinationTool).isEmpty)
    }

    @Test("a private administration target that cannot be cloned fails typed and leaves nothing behind")
    func uncloneablePrivateAdministrationTargetFails() async throws {
        // Arrange: the named signer file is a FIFO, which has no CoW payload to give the destination.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-private-special")
        defer { fixture.remove() }
        try ignore(".claude/", fixture: fixture)
        let agent = fixture.source.appending(path: ".claude/worktrees/agent")
        try fixture.git.run("worktree", "add", "-q", "-b", "agent", agent.path)
        let signers = try canonical(fixture.source.appending(path: ".git/worktrees/agent"))
            .appending(path: "allowed_signers")
        try #require(mkfifo(signers.path, 0o644) == 0)
        try fixture.git.run("config", "gpg.ssh.allowedSignersFile", signers.path)
        let branchesBefore = try fixture.branchNames()

        // Act
        let failure: GitWorktreeForkError?
        do {
            _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())
            failure = nil
        } catch {
            failure = error
        }

        // Assert
        #expect(
            failure
                == .entryFailed(
                    relativePath: ".claude/worktrees/agent/.git/allowed_signers", reason: .unsupportedEntryKind,
                    errorNumber: nil))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination()))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration()))
        #expect(try fixture.branchNames() == branchesBefore)
    }

    private func makeNestedRepository(at path: URL, fixture: GitWorktreeForkFixture) throws {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try fixture.git.run(["init", "-q"], currentDirectory: path)
        try fixture.write("tool.txt", "tool\n", in: path)
        try fixture.git.run(["add", "."], currentDirectory: path)
        try fixture.git.run(["commit", "-qm", "initial"], currentDirectory: path)
    }

    private func ignore(_ pattern: String, fixture: GitWorktreeForkFixture) throws {
        try fixture.write(".gitignore", "\(pattern)\n")
        try fixture.git.run("add", ".gitignore")
        try fixture.git.run("commit", "-qm", "ignore \(pattern)")
    }

    private func configValue(_ key: String, at worktree: URL, _ fixture: GitWorktreeForkFixture) throws -> String {
        try fixture.git.run(["config", "--get", key], currentDirectory: worktree)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func canonical(_ url: URL) throws -> URL {
        let resolved = try #require(realpath(url.path, nil))
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }
}

/// Whether a flattened node's common and private file of one name hold the same thing.
enum CollidingAdministrationContent: String, CaseIterable, Sendable {
    case different
    case identical
}

/// How a fault breaks a cloned private counterpart before validation.
enum TamperedCounterpart: String, CaseIterable, Sendable {
    /// A referenced non-configuration file holds different bytes.
    case wrongBytes
    /// A referenced included configuration file is gone.
    case missing
    /// A referenced included configuration file holds entries no authorized relocation explains.
    case includedEntriesChanged
    /// A referenced included configuration file lost a repeated entry, changing the key's effective value.
    case repeatedEntryDropped
}
