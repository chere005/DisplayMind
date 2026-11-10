# displayplacer

Source: https://github.com/jakehilborn/displayplacer

Version: v1.4.0, revision `ca8a7e80d0f536b3331dcf1fe86a9726d5b5556e`.

The MIT license is included in LICENSE. Sources are compiled into a bundled helper; no Homebrew installation is required. Display rotation uses Apple's private MonitorPanel framework and may depend on macOS and display support.

Local changes: zero-initialize parsed configurations; sleep briefly while waiting for a rotation to avoid a busy loop. The build command is maintained in `tools/build.sh`.
