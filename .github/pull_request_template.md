## Summary

Describe the behavior changed and the user or maintainer impact.

## Validation

- [ ] Added or updated automated tests first for changed behavior
- [ ] `npm run check`
- [ ] `npm run build`
- [ ] Cross-platform implications reviewed
- [ ] Documentation and changelog updated when behavior changed
- [ ] No credentials, local databases, generated builds, or temporary publication files included

## Architecture

- [ ] Domain rules remain independent of Electron, HTTP, storage, and provider SDK details
- [ ] Application services coordinate use cases without importing infrastructure
- [ ] Renderer remains sandboxed and uses only the preload capability bridge
