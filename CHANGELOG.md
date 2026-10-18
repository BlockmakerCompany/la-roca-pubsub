# Changelog

Todas las modificaciones notables de este proyecto se documentan en este archivo.
El formato sigue Keep a Changelog y este proyecto usa versionado semántico.

## [Unreleased]

### Added
- instrumentar el parser assembly con edges AFL++ para cobertura real

### Docs
- document afl-clang-fast and QEMU coverage limitation

## [v1.4.0] - 2026-10-18

### Added
- syscall macros, register topology map, and AVX2 mpub hot loop
- zero-copy sys_sendfile delivery on /sub
- extract pure L7 parser and add AFL++ fuzz harness
- expose engine version in /stats

### Changed
- add post-stress stability suite and make benchmark fail on errors

### Fixed
- align callee-saved register restore in handle_mpub epilogue

### Docs
- sync hot-loop, binary size, and project structure to AVX2 reality
- trim internal roadmap to remaining work
