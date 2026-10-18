# Changelog

All notable changes to this project are documented in this file.
The format follows Keep a Changelog and this project uses semantic versioning.

## [Unreleased]

### Added
- instrument the parser assembly with AFL++ edges for real coverage

### Fixed
- address PR #5 review feedback (TOCTOU, sendfile, FD leak, CPUID)

### Docs
- document afl-clang-fast and QEMU coverage limitation
- add CONTRIBUTING.md and translate repo to English

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
