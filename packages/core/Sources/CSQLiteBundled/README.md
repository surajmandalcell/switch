# CSQLiteBundled

Vendored SQLite amalgamation, used only on Windows. `Package.swift` publishes it under the module name
`CSQLite`, so `import CSQLite` resolves here on Windows and to the system library on macOS and Linux.

SQLite is in the public domain (https://sqlite.org/copyright.html).

| Item | Value |
|---|---|
| Version | 3.54.1 (`sqlite-amalgamation-3540100.zip`, from https://sqlite.org/2026/) |
| Zip size | 2 990 966 bytes |
| Zip SHA3-256 (as listed on sqlite.org/download.html) | `92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30` |
| Zip SHA-256 | `0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9` |
| `sqlite3.c` SHA-256 | `0c657666d819f261cc4007526ad57e1669de9949df7a8ea847aa284a2bf0ee52` |
| `include/sqlite3.h` SHA-256 | `d6c84557261893439b341d2e6c35187ae3ea24fbfd843ad94616f72d89242b8c` |

Build settings (in `Package.swift`): `SQLITE_THREADSAFE=1`, `SQLITE_OMIT_LOAD_EXTENSION`.
Files are unmodified from the zip. To update, replace both files and this table.
