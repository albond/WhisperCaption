# Releasing WhisperCaption

Cutting a new release is split across two surfaces — **GitHub Actions** creates the Release page with a changelog, and **your local Mac** builds and signs the `.dmg`. Signing happens locally on purpose: the brand Apple ID's developer certificate lives only in your local keychain and never touches CI.

## TL;DR

```sh
# 1. Tag and push
git tag v1.0.0
git push origin v1.0.0

# 2. Build the signed .dmg locally
./scripts/build-release.sh 1.0.0

# 3. Upload it to the draft release that GitHub Actions just created
gh release upload v1.0.0 build/WhisperCaption-1.0.0.dmg

# 4. Publish
gh release edit v1.0.0 --draft=false
```

## Step-by-step

### Pre-flight

- [ ] All work for this version is merged to `main`.
- [ ] [CI](https://github.com/albond/WhisperCaption/actions) is green on the head commit.
- [ ] Any machine-local notes or configs are ignored — sanity-check with `git status` (nothing personal in **Untracked files**) and `git check-ignore -v <path>` on each file you intentionally keep out of the repo.
- [ ] `WhisperCaption/Local.xcconfig` has `DEVELOPMENT_TEAM` filled in. Sanity check:
  ```sh
  grep DEVELOPMENT_TEAM WhisperCaption/Local.xcconfig
  ```
- [ ] Your login keychain has exactly one **`Apple Development: albond.dev@proton.me`** identity and nothing else for code signing:
  ```sh
  security find-identity -v -p codesigning
  ```
  If you see a second identity that belongs to a personal Apple ID, remove it before building — it must not be possible to accidentally sign a published binary under a personal cert.

### 1. Tag and push

Tags must follow **SemVer with a `v` prefix**: `v1.0.0`, `v1.2.3`, `v2.0.0-rc.1`.

```sh
git tag v1.0.0
git push origin v1.0.0
```

The push triggers `.github/workflows/release.yml`, which creates a **draft** GitHub Release with an auto-generated changelog from commits since the previous tag.

### 2. Build the signed `.dmg` locally

```sh
./scripts/build-release.sh 1.0.0
```

What this does:
1. Archives a Release build (`xcodebuild archive`).
2. Reads `DEVELOPMENT_TEAM` from `Local.xcconfig`, generates a temporary `ExportOptions.plist` in `build/` (never committed), exports a signed `.app`.
3. Prints the codesign Authority chain so you can audit it before publishing — make sure the first Authority line says **`Apple Development: albond.dev@proton.me`** and nothing else.
4. Packages the `.app` into `build/WhisperCaption-1.0.0.dmg` with a drag-to-Applications layout, prints the SHA-256.

If the Authority line shows any other identity — **stop**. Don't upload the `.dmg`. Diagnose what your build setup picked up before continuing.

### 3. Upload the `.dmg` to the draft release

```sh
gh release upload v1.0.0 build/WhisperCaption-1.0.0.dmg
```

If `gh` is not installed: `brew install gh && gh auth login`. Alternatively, drag-and-drop the `.dmg` onto the draft Release page in GitHub's web UI.

### 4. Publish

Open the draft release in the web UI to double-check the changelog text reads cleanly, then:

```sh
gh release edit v1.0.0 --draft=false
```

This flips the release from draft to published. Subscribers get notified, the `Latest release` badge on the README flips to `v1.0.0`, the `Downloads` badge starts counting.

## What CI does (and doesn't) do

**Does:**
- Verifies that every push to `main` and every pull request **builds clean and passes tests** on a fresh `macos-15` runner.
- On every tag push matching `v*`, **creates a draft GitHub Release with a generated changelog**.

**Does NOT:**
- Build the `.dmg`.
- Sign anything (CI uses ad-hoc signing for the verification build).
- Touch your Apple Developer credentials — they're not in GitHub secrets and shouldn't be.

The reason signing stays off CI: the brand developer certificate's private key lives only on your local keychain. Putting it on GitHub-hosted runners would mean exporting the private key and storing it as a GitHub secret — a much larger blast radius than the current setup, with no real win.

## Versioning policy

WhisperCaption uses [Semantic Versioning](https://semver.org/) (`MAJOR.MINOR.PATCH`):

| Bump | When |
|-|-|
| `PATCH` (`1.0.0` → `1.0.1`) | Bug fixes, no user-visible behaviour changes |
| `MINOR` (`1.0.x` → `1.1.0`) | New features, settings, engines — backward-compatible for existing users |
| `MAJOR` (`1.x.x` → `2.0.0`) | Breaking changes: removed settings, breaking changes to chat-history file format, etc. |

`MARKETING_VERSION` is set by the build script via `xcodebuild MARKETING_VERSION=`, so what shows in **About → WhisperCaption** matches the tag.

## Yanking a bad release

If a release has a critical issue and you want to take it offline before users see it:

```sh
gh release delete v1.0.0 --yes
git push --delete origin v1.0.0
git tag -d v1.0.0
```

Then fix, re-tag with a bumped patch (`v1.0.1`), and ship the fix. Don't reuse a tag — even if `git push --delete` removes it from the remote, mirrors and clones still hold it.
