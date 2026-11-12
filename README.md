# gg_one_core

Kernel, checks and publish configuration of the gg_one tool family - state caching, command bases, verification steps and gg-publish.json handling.

## Per-repo settings

`GgRc` reads `.gg/gg_rc.jsonc` and creates it with its defaults when missing:

```jsonc
{
  "upgradeMajorVersions": true, // false: upgrades stay within major versions
  "enableChecks": true          // false: skippable check clusters are skipped
}
```
