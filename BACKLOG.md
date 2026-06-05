# Backlog

Deferred work, to pick up later.

## Follow series + new-episode notifications

Let users "Follow" a series (toggle on the detail page) and get a local notification when a new
episode appears. Needs: a FollowStore (series pageURL → last-known episode count), a Follow toggle in
DetailView, and a periodic/on-launch check that calls `/info` for each followed series and notifies
when the episode count grows. Deferred from the Track-3 batch (download-finished notifications shipped;
this one needs the polling subsystem). Decided 2026-06-03.

## iOS port (pure-Swift core)

Run on iPhone for personal + a few friends. **Not a recompile** — iOS forbids spawning the Python
sidecar subprocess, so the scraping must run in-process: realistically a **pure-Swift port** (SwiftSoup
for HTML + an in-process local HTTP relay server for the proxy, since AVPlayer still can't SOCKS). That
core would also run on macOS (simplifies/notarizes the Mac app — the nested Python helper is what
complicates notarization). Distribution without the App Store: **Apple Developer Program ($99/yr) + Ad
Hoc** (register device UDIDs, hand out a signed .ipa, no Apple review) is the best fit for a few users;
TestFlight is smoother but requires Apple beta review (risky for this content). EU sideloading doesn't
apply in the UK. Decided 2026-06-03.

## Auto-update (Sparkle) — SHIPPED (v0.4.0, 2026-06-05)

Done. The repo went public, so we took the all-GitHub path (no second repo / bucket): the app
embeds Sparkle (SPM) with `SUFeedURL` pointing at GitHub's stable
`releases/latest/download/appcast.xml`. CI EdDSA-signs each DMG (`sign_update -f` with the
`SPARKLE_ED_PRIVATE_KEY` repo secret; public key in Info.plist) and uploads `appcast.xml` as a
release asset. "Check for Updates…" lives under the app menu + a Settings → Updates toggle for
automatic checks. `scripts/package.sh` signs Sparkle's nested helpers (Updater.app, the XPC
services, Autoupdate) inside-out.

**Remaining follow-up — notarization (deferred):** still ad-hoc / not notarized, so an updated
version may re-trigger Gatekeeper's "unidentified developer" prompt on first launch after an
update. To remove that: join the Apple Developer Program ($99/yr), flip `ENABLE_HARDENED_RUNTIME`
back ON, sign with a Developer ID, and add a notarize+staple step to the release workflow.
