# labelle-web

Web platform package for the Labelle toolkit.

## Status

Repository scaffold only. Provider commands and runtime services are not implemented or released yet. Do not add this repository as a working game dependency until the first usable release.

## Planned responsibilities

- Web toolchain provisioning and build orchestration through the generic provider contract.
- Local serving, export tooling, default browser shell, download progress, compression, and size reporting.
- Browser storage services through the engine's storage interface.

The provider target remains `wasm`. Backend-specific rendering and emscripten linking remain with backend packages. Custom game pages must remain supported. A default package selection is registry/scaffold data, not a hardcoded CLI package name.

## Implementation references

- [Provider architecture: CLI #406](https://github.com/labelle-toolkit/labelle-cli/issues/406)
- [Contract decisions before implementation: CLI #411](https://github.com/labelle-toolkit/labelle-cli/issues/411)
- [Manifest-declared texture capabilities: CLI #407](https://github.com/labelle-toolkit/labelle-cli/issues/407)
- [Default loading shell: CLI #402](https://github.com/labelle-toolkit/labelle-cli/issues/402)
- [Fullscreen canvas sizing: bgfx #130](https://github.com/labelle-toolkit/labelle-bgfx/issues/130)
- [Persistent browser saves: engine #893](https://github.com/labelle-toolkit/labelle-engine/issues/893)

Migration is breaking: existing web projects explicitly add and pin the provider. Introduce the package manifest after the contract decisions are settled. Verify browser startup, resize/fullscreen, custom-shell behavior, and save persistence when those features land.
