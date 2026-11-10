# Maintaining this repository

This is where desktop work happens from now on. The fork branch that produced
[upstream PR #1246](https://github.com/EverMind-AI/Raven/pull/1246) stays as
it was; nothing needs to be kept in sync between the two.

## Day to day

```sh
cd ~/path/to/Raven-Desktop/macos
./build.sh                 # rebuild ~/Applications/Raven.app
open ~/Applications/Raven.app
```

Changes to `RavenDesktop.swift` (window, menus, shortcuts) only need a
rebuild. Changes to `scripts/launch.sh` need a rebuild too, because the script
is copied into the app bundle. `build/` and `.modulecache/` are ignored.

## When Raven itself changes

The app does not read from this repository at runtime. It calls the installed
`raven` CLI and loads the page that CLI serves, so an upstream update arrives
on its own. The one thing to check is the auth URL: `scripts/launch.sh` calls
`raven.cli.serve_commands._attached_url()` and expects an
`/auth#<nonce>` URL. If upstream renames that, change the launcher and rebuild.

```sh
raven --version
./macos/build.sh
~/Applications/Raven.app/Contents/Resources/scripts/launch.sh   # should print an http://127.0.0.1:<port>/auth#... URL
```

## Before a release

- Rebuild from a clean `build/` and open the app on a Mac that has never seen
  it (Gatekeeper check).
- Update `docs/screenshots/` if the window or page changed. Raw captures are
  taken with WebKit's `takeSnapshot`; the window frame in `00-*.png` and
  `03-*.png` is drawn in code because screen recording is blocked here.
- Write the release notes in plain language: what changed, what still does not
  work.
- Tag the commit and, if a `.dmg` is produced, attach it to the release.

## Ownership

GitHub account: `hyi1233`. Public name on commits: 星耀羽翼
`<xingyueyuyi@users.noreply.github.com>`. Do not put a real home directory or
user name into any file in this repository.
