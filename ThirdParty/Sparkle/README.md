# Sparkle

Automatic updates use [Sparkle 2.10.1](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.1), an MIT-licensed macOS update framework. SwiftPM pins and verifies its binary distribution in `Package.resolved`. Corresponding source: https://github.com/sparkle-project/Sparkle/tree/2.10.1.

Release bundles include the framework's licenses and original signatures. Update ZIP files are signed with a dedicated Ed25519 key held in the maintainer's login Keychain; only the public key is committed. See [update publishing](../../docs/development.md).
