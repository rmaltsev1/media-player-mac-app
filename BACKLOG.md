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

## Auto-update (Sparkle) + public release distribution

**Goal:** ship updates that install themselves — the app checks a feed and prompts (or
silently installs) when a new DMG is published. No manual re-download.

**How [Sparkle](https://sparkle-project.org) works:** the app polls an `appcast.xml` feed
(a public URL) listing the latest version + DMG link + release notes + an EdDSA signature.
When a newer version appears it prompts *"Install / Later / Skip"*, then downloads, verifies
the signature, swaps the app, and relaunches. Can be configured to auto-install silently.

**Hard requirement — releases must be PUBLIC.** Sparkle's appcast + DMG must be downloadable
without auth. Our source repo is **private** and GitHub ties release visibility to repo
visibility, so we need one of:

- **Option A — separate public "dist" repo (all-GitHub, simplest):**
  - Create a public repo (e.g. `rmaltsev1/rezkaplayer-dist`) with no source — just Releases + `appcast.xml`.
  - Private repo's CI builds the DMG and cross-publishes to the public repo via
    `gh release create --repo <public>` using an Actions secret `RELEASE_TOKEN` (a PAT with
    `repo` scope on the public repo — the default `GITHUB_TOKEN` can't reach another repo).
  - Host `appcast.xml` in the public repo (raw URL or GitHub Pages); app's feed points there.
- **Option B — object storage (no second repo):** push DMG + `appcast.xml` to a public bucket
  (Cloudflare R2 / Backblaze B2 / S3). Source stays fully private; app's feed points at the bucket.

**Steps when we do it:**
1. Pick Option A or B (lean A).
2. Add Sparkle SPM dependency to the app; embed the EdDSA public key; set `SUFeedURL`.
3. Generate an EdDSA keypair (Sparkle's `generate_keys`); keep the private key as a CI secret.
4. Extend `.github/workflows/release.yml`: after building, sign the update, generate/append the
   appcast entry, and publish DMG + appcast to the public destination.
5. Add a "Check for Updates…" menu item.

**Dependency / caveat:** smoothest paired with **Apple notarization** (Developer ID, $99/yr — the
same upgrade discussed for first-launch friction). Without notarization, Sparkle auto-update still
works but macOS may re-show the "unidentified developer" prompt on each updated version. Flip
`ENABLE_HARDENED_RUNTIME` back ON and add the notarize+staple step when going that route.

**Status:** deferred (decided 2026-06-03). Current distribution is a manual ad-hoc DMG via
`scripts/package.sh` + a private GitHub Release (share the `.dmg` directly).
