# Nitrakit for iOS and macOS

A complete video editor for your app: timeline, text, effects, music and MP4 export, in your
brand. iOS 16+ and macOS 13+.

## Install

In Xcode: **File → Add Package Dependencies**, enter
`https://github.com/Nitrakit/nitrakit-swift` and add the `NitrakitUI` product (it brings
`Nitrakit` along). In a `Package.swift`:

```swift
.package(url: "https://github.com/Nitrakit/nitrakit-swift", from: "0.2.0")
```

- `Nitrakit`: the editor engine API (projects, media, export, license).
- `NitrakitUI`: the preview and editor views.

Guides and reference: https://docs.nitrakit.dev

## License

Proprietary: see [LICENSE.md](LICENSE.md). Third-party components: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
