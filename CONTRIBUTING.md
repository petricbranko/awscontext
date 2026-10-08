# Contributing

Thanks for helping out! AWSContext aims to stay **small and simple**, so please open an issue to discuss bigger features before you send a pull request.

## Development

Requirements: macOS 13+ and Xcode 15+ (or the matching Swift toolchain).

```sh
make test   # run unit tests
make run    # build build/AWSContext.app and launch it
```

You can also open `Package.swift` in Xcode and run the `AWSContext` scheme.

To try the app without touching your real files, point it at scratch copies:

```sh
AWS_SHARED_CREDENTIALS_FILE=/tmp/aws/credentials AWS_CONFIG_FILE=/tmp/aws/config \
  build/AWSContext.app/Contents/MacOS/AWSContext
```

## Layout

| Path | What lives there |
| --- | --- |
| `Sources/AWSContextCore` | UI-free logic: INI editing, profile switching, clipboard parsing. Fully unit tested. |
| `Sources/AWSContext` | The SwiftUI menu bar app. |
| `Tests/AWSContextCoreTests` | Tests for the core library. |
| `scripts/` | App bundling and icon generation. |

## Guidelines

- Keep changes to the user's AWS files minimal and format-preserving. Add a test for any new file-editing behavior.
- Never log or display secrets.
- Run `make test` before opening a PR.

## Releasing

Push a tag like `v0.2.0`. GitHub Actions builds a universal app and attaches the zip to a GitHub release.
