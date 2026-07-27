# Release process

## Preconditions

- The default branch contains only the product source.
- The repository contains no staging or transfer files.
- The repository contains no generated package output.
- The package version agrees with the changelog.
- The lockfile is current.
- The public text describes implemented behavior.
- The ASD-STE100 project check passes.

## Local release gate

```bash
npm ci
npm run build
npm audit --omit=dev --audit-level=high
npm run dist:dir
```

Inspect the unpacked app. Test startup, provider edits, account edits, server restart, authentication, API routes, usage data, and the website.

## CI gate

Desktop CI does these tasks:

1. Install exact dependencies.
2. Check the repository.
3. Check the ASD-STE100 project profile.
4. Run tests and coverage gates.
5. Check documentation links.
6. Build the renderer and website.
7. Audit production dependencies.
8. Build unpacked packages on all supported systems.

CodeQL checks JavaScript. The website is published in `surajmandalcell.github.io`. Its path is `/subscription-proxy-inator/`.

## Create a tag

Create an annotated `vMAJOR.MINOR.PATCH` tag after the default-branch checks pass.

The release workflow builds platform packages and checksum files.

Unsigned packages are for development and test use. Public end-user packages should use platform signing.

Required signing work:

- Apple Developer ID signing
- Apple notarization
- Windows Authenticode signing
- Maintainer-controlled release secrets
- Installation tests on each platform

Do not reduce security settings or CI checks to complete packaging.
