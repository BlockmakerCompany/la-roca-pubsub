# Changelog

Todas las modificaciones notables de este proyecto se documentan en este archivo.
El formato sigue Keep a Changelog y este proyecto usa versionado semántico.

## [Unreleased]

### Added
- syscall macros, register topology map, and AVX2 mpub hot loop

### Changed
- add post-stress stability suite and make benchmark fail on errors

### Fixed
- align callee-saved register restore in handle_mpub epilogue
