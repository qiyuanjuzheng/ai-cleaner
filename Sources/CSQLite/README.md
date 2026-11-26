# CSQLite

Vendored SQLite amalgamation built as a SwiftPM C target so `AICleanerCore` does not depend on Apple's system `SQLite3` module and compiles identically on macOS, Linux (glibc & static musl), and Windows.

- **Version**: SQLite 3.54.1 (`sqlite-amalgamation-3540100.zip`)
- **Upstream**: https://www.sqlite.org/2026/sqlite-amalgamation-3540100.zip
- **License**: Public Domain (https://www.sqlite.org/copyright.html)
- **SHA-256**:
  - `sqlite-amalgamation-3540100.zip`: `0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9`
  - `sqlite3.c`: `0c657666d819f261cc4007526ad57e1669de9949df7a8ea847aa284a2bf0ee52`
  - `include/sqlite3.h`: `d6c84557261893439b341d2e6c35187ae3ea24fbfd843ad94616f72d89242b8c`
  - `include/sqlite3ext.h`: `48963abfefb41ac329ef9d706acb5eadba952a99a748285c9ded6b5e0942721b`
