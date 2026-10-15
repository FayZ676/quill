# Quill

A minimal, iA Writer–style Markdown editor for macOS 13+: a library of plain-text files, focus mode, and typewriter scrolling.

## Build

    ./build.sh          # → build/Quill-1.0.0.dmg (universal; notarized when a Developer ID certificate is present)

Open the DMG and drag Quill to Applications. Set `VERSION=1.1.0 ./build.sh` to stamp a different version.

## Layout

- `Sources/Quill/Library.swift`: app state, the folder library, file operations, FSEvents watcher
- `Sources/Quill/EditorView.swift`: loading, autosave, and syncing settings into the editor
- `Sources/Quill/FocusTextView.swift`: centered column, focus dimming, typewriter scrolling, list continuation
- `Sources/Quill/MarkdownHighlighter.swift`: inline Markdown styling
- `Resources/Fonts`: iA Writer Mono/Duo/Quattro (SIL Open Font License)
