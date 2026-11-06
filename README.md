# Lumenex Vibe — over-the-air updates

The Vibe projector's factory pushes only its own firmware, never our app. So the app (`com.lumenex.tv`) updates
itself from here (OTA-1, lumenexx/projectionmapping-95d215a0#670).

## How a projector updates

1. At app start, when the network first comes up, then every hour, the app reads its channel's manifest:
   `https://github.com/lumenexx/vibe-updates/releases/download/<channel>/update.json`
   - release builds (the factory APK): channel `production`
   - staging builds: channel `staging`
2. If the manifest offers a higher `versionCode`, the app shows its update screen:
   - **optional** update: *Update now* / *Later* (Later waits 24 h);
   - **mandatory** update (the projector is below `minVersionCode`): installs at once, retries every minute.
3. It downloads the APK (resuming), checks size, SHA-256, package, versionCode and signing key, and installs it.
   On the Vibe (Android 14) this needs no press; elsewhere Android shows one *Install* dialog.
4. The new version starts by itself and reports `app_update` notes (TV error reports).

Android refuses any APK not signed with the key of the installed app. Only the holder of the Lumenex release key
can update a projector, whatever this repo says.

## update.json

```json
{
  "schema": 1,
  "packageName": "com.lumenex.tv",
  "channel": "production",
  "versionCode": 45,
  "versionName": "1.3",
  "minVersionCode": 0,
  "rolloutPercent": 100,
  "apkUrl": "https://github.com/lumenexx/vibe-updates/releases/download/production/lumenex-vibe-production-45.apk",
  "sha256": "<64 hex>",
  "size": 12345678,
  "signerSha256": "<64 hex>",
  "notes": "Shown on the update screen",
  "publishedAt": "2026-11-06T10:00:00Z",
  "manifestUrl": "(optional) https URL the app reads from the next check on: how a channel moves"
}
```

## Publishing

```bash
bash tools/publish.sh production path/to/app-release.apk --notes "What's new"
bash tools/publish.sh production app-release.apk --min 45      # force every projector below 45 to update
bash tools/publish.sh production app-release.apk --rollout 10  # offer it to 10 % first
bash tools/unpublish.sh staging                                # offer nothing on a channel
```

`publish.sh` refuses an APK of another package, one not signed with the channel's key, a debuggable APK on
`production`, and a versionCode below the one the channel already offers. It uploads the APK, reads it back from
its public URL, and only then replaces `update.json`.

## Keys

| Channel | Signing certificate SHA-256 |
|---|---|
| production (and any other) | `36fe7f3ae3040bdef8df784c0ac8ff9e871bf0a2e0e88aa7be61526344b6210f` (CN=Lumenex Vibe, created 2026-11-05) |
| staging | `33cb17e33f03b9fc12b9bc63bbb2c4807fdd21981ee746299a9d63c00ba01330` (staging debug key) |

The release keystore is in lumenexx/projectionmapping-95d215a0's secrets (`LUMENEX_RELEASE_KEYSTORE_B64`,
`LUMENEX_RELEASE_KEYSTORE_PASSWORD`) and with the owner. Losing it means no update can ever reach a projector
again.
