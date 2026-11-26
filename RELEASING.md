# Pilot releases

Use the private GitHub repository for source and pilot downloads. Before uploading source or build inputs, review both Direct access and Organization access under **Settings → Collaborators & teams**. GitHub organization owners retain access, and Nscale's organization permissions can also grant access to other members.

## Maintain the changelog

Add a user-facing entry to the `Unreleased` section of [CHANGELOG.md](CHANGELOG.md) with each behavior change. Use the categories Added, Changed, Deprecated, Removed, Fixed, and Security as applicable. Describe the effect on the user. Include migration or compatibility notes when a release needs them.

Before cutting a release, review the accumulated changes and decide the next SemVer prerelease. This command moves the current entries into a dated version section and leaves `Unreleased` ready for the next change.

```sh
python3 packaging/changelog.py cut v0.1.0-pilot.1
python3 packaging/changelog.py check
python3 packaging/changelog.py notes v0.1.0-pilot.1
```

Commit the changelog through the normal review flow. Once the release commit is on the default branch, tag that commit and push the tag. Keep published entries in the changelog. Corrections ship in a new release.

```sh
git tag -a v0.1.0-pilot.1 -m 'Agent Commander pilot 1'
git push origin v0.1.0-pilot.1
```

## Supply the private Go build inputs

The Linux and Mac release builds need the pinned `agent-acp` and `agent-acp-transport` Go proxy archives under `dist/sdk`. GitHub-hosted runners use the same archive versions as local builds. The module download checks each mirror against `go.sum`.

When the pins change, pack the six required Go proxy files and publish them to an input prerelease on the approved private repository. This asset contains module source and its audience must be approved for those inputs. The input tag contains both versions and is independent of application release tags.

```sh
input_tag=$(python3 packaging/sdk-inputs.py tag)
python3 packaging/sdk-inputs.py pack dist/go-build-inputs.tar.gz
gh release create "$input_tag" dist/go-build-inputs.tar.gz \
  --target main --prerelease --latest=false \
  --title "Go build inputs $input_tag" \
  --notes 'Pinned Go proxy inputs for Agent Commander CI.'
```

## Build and distribute

[Build and release](.github/workflows/build.yml) checks Go, Swift, and relay configuration. A manual run from a branch produces downloadable Actions artifacts. A prerelease tag on a commit in the default branch builds the same artifacts and publishes a GitHub prerelease with notes drawn from that exact version of the changelog. The publisher downloads the draft's assets and verifies `SHA256SUMS` before publishing.

| Asset | Use |
| --- | --- |
| `Agent-Commander-Multiplayer-Pilot-macOS-universal.zip` | Ad hoc pilot app with both helpers for Intel and Apple silicon on macOS 26 or later. |
| `commander-relay-pilot-linux-amd64.tar.gz` | Docker image archive for the multiplayer pilot relay. |
| `agent-commander-relay-linux-amd64.tar.gz` and `agent-commander-relay-linux-arm64.tar.gz` | Standalone hosted relay bundles for the existing deployment path. |
| `agent-commander-headless-linux-amd64.tar.gz` and `agent-commander-headless-linux-arm64.tar.gz` | The headless Commander service for a Linux server: `agentctl` stamped with the release tag, `VERSION` and a README. |
| `install.sh` | Installs or upgrades the headless service on a Linux server. See [Headless Commander](design/HEADLESS-COMMANDER.md). |
| `SHA256SUMS` | SHA-256 manifest for every other asset. |

After the release publishes, download its headless archive on a test host and check it. Then mark it as the latest release, so `gh release download` without a tag picks it up:

```sh
gh release edit v0.1.0-pilot.5 --prerelease=false --latest
```

The workflow also asks GitHub for a build attestation of the headless archives and `install.sh`. This is optional. GitHub issues attestations for public repositories, and for private ones only on GitHub Enterprise Cloud, so the step may fail without failing the release. A deploy verifies an attestation when one exists.

The ad hoc Mac build is for testing. Use the [Developer ID packaging procedure](design/MULTIPLAYER-PILOT.md#build-the-universal-macos-archive) for the notarized distribution archive.

If macOS reports that Apple cannot check an archive for malicious software, verify which build was copied to the Mac. The ad hoc CI archive does not carry a Developer ID signature or a notarization ticket. For distribution, use the notarized universal archive from the procedure above. Verify the extracted app before sharing it.

```sh
codesign --verify --deep --strict --all-architectures "Agent Commander.app"
xcrun stapler validate "Agent Commander.app"
spctl --assess --type execute --verbose=4 "Agent Commander.app"
```

If macOS says the app will damage the computer, record the exact alert, download source, and archive checksum for investigation. [Apple's guide to opening apps safely](https://support.apple.com/en-us/102445)
