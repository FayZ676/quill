# Quill

## Shipping a Mac update

When asked to "ship" or "release" a version, do all of this without further prompting.

1. **Get everything onto `main`.** Commit any uncommitted work, merge feature branches into
   `main` (fast-forward), push, and delete the merged branches. `swift build` must pass first.
2. **Pick the version.** Find the latest tag with `gh release list`. Bump the patch number for
   fixes and polish and the minor number for new features, unless the user names a version.
   Never reuse a version or go backwards: Sparkle only offers versions newer than the installed one.
3. **Build:**

       VERSION=X.Y.Z NOTES="One or two plain sentences for users." ./build.sh

   This compiles a universal binary, embeds and signs Sparkle, notarizes and staples, and writes
   three files to `build/`: `Quill-X.Y.Z.dmg`, `Quill.zip` (the in-app update) and `appcast.xml`
   (the update feed). Notarization takes a few minutes. If it fails, the script prints
   Apple's log.
4. **Publish the release**, tagged `vX.Y.Z` on `main`, with the same notes:

       cp build/Quill-X.Y.Z.dmg build/Quill.dmg
       gh release create vX.Y.Z build/Quill.dmg build/Quill.zip build/appcast.xml \
         --target main --title "Quill X.Y.Z" --notes "<same text as NOTES>"

   All three files must keep exactly these names:
   - The website's download button points at `releases/latest/download/Quill.dmg`.
   - The app's update feed (`SUFeedURL` in `Resources/Info.plist`) is
     `releases/latest/download/appcast.xml`.
   - The feed links to `releases/download/vX.Y.Z/Quill.zip`.
5. **Verify** that both the download link and the feed redirect to the new release:

       curl -sIL -o /dev/null -w "%{http_code}\n" https://github.com/FayZ676/quill/releases/latest/download/Quill.dmg
       curl -sL https://github.com/FayZ676/quill/releases/latest/download/appcast.xml | grep sparkle:version

The personal website (`~/workspace/faizififita`) needs no change: it always serves the
latest release.

### Release notes

Write them for users, not developers. Say what changed in the app in one or two plain
sentences, and leave out file names and internals. They appear on the GitHub release and in
Sparkle's "update available" prompt.

### Keys and credentials

- **Sparkle EdDSA key:** `build.sh` signs each update with the private key saved in the login
  keychain under the account `quill`. The matching public key is `SUPublicEDKey` in
  `Resources/Info.plist`. If the private key is lost, installed copies can never update again,
  so keep a backup:
  `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account quill -x <file>`.
  Never commit that file.
- **Notarization:** uses the `quill-notary` notarytool keychain profile and the Developer ID
  Application certificate in the keychain.

## Shipping the iOS app

    VERSION=X.Y.Z UPLOAD=1 iOS/build.sh

This archives the app and uploads it to App Store Connect. It needs `ASC_KEY_ID` and
`ASC_ISSUER_ID` (see the comment at the top of `iOS/build.sh`). Ship iOS only when asked:
a Mac release doesn't imply an iOS upload. Keep iOS on the same version number as the Mac
app when both ship.

## Conventions

- Commit messages are one imperative sentence describing the change for a user ("Give the
  icon a glowing caret…"). Add a short body when the reason isn't obvious.
- `Sources/Quill/Shared` is compiled into the iOS app too, so keep AppKit-only and
  Sparkle-only code out of it.
