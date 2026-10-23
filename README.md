# Quill

A minimal, iA Writer–style Markdown editor for macOS 13+: a library of plain-text files, focus mode, and typewriter scrolling.

## Build

    ./build.sh          # → build/Quill-1.0.0.dmg (universal; notarized when a Developer ID certificate is present)

Open the DMG and drag Quill to Applications. Set `VERSION=1.1.0 ./build.sh` to stamp a different version. The build also writes `Quill.zip` and `appcast.xml`, the in-app update and its feed: installed copies check for updates daily through [Sparkle](https://sparkle-project.org). See `CLAUDE.md` for the release steps.

## iPhone and iPad

    iOS/build.sh        # builds, installs and launches on a connected iPhone (needs `brew install xcodegen`)

On first launch, choose the Mac library in iCloud Drive (Documents › Quill) to edit the same files on both; or keep a separate library on the device (Files › On My iPhone › Quill). `INSTALL=0` builds without installing; `DEVICE=<name>` picks a device.

## Layout


- `Sources/Quill/Library.swift`: app state, the folder library, file operations, FSEvents watcher
- `Sources/Quill/EditorView.swift`: loading, autosave, and syncing settings into the editor
- `Sources/Quill/FocusTextView.swift`: centered column, focus dimming, typewriter scrolling, list continuation
- `Sources/Quill/MarkdownHighlighter.swift`: inline Markdown styling
- `Sources/Quill/Shared`: shared by both apps: Markdown highlighting, editing commands, fonts, the file model
- `iOS/Sources`: the iOS app (library screens, editor, settings); `iOS/project.yml` is the Xcode project spec
- `Resources/Fonts`: iA Writer Quattro (Sans) and Mono (SIL Open Font License); Serif is the system serif
