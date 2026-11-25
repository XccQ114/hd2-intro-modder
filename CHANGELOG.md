# Changelog

Versions follow the GitHub Releases (`v1.0.0` … `v1.3.1`). Only user-visible changes are listed.

## v1.3.1 — 2026-11-26

Fixes found by a red-team pass over the v1.3.0 release. No behaviour change on the happy path:
the mod is still refused unless the encoded video carries `flags=0x40012`.

- **The flags report no longer mislabels the source file.** When the resolution guards
  re-encode the input (`<720p` → 1280x720, `>1440p` → 2560x1440, `>60fps` → 60fps), the report
  used to print the intermediate file as `source:` while quoting the *original* resolution next
  to it. It now prints the path you actually passed, the measured resolution/fps, and adds
  `encodedFrom:` when an intermediate re-encode was used.
- **The report no longer decodes bit meanings as if they were proven.** RAD publishes no flags
  bit map; the `/V` → flags numbers were byte-measured, the meanings are inference. The report
  and the docs now say so, bit 4 is reported as set/clear without an explanation, and a
  non-`KB2n` container is reported as "flags bit meanings do not apply" instead of decoding a
  Bink 1 / `KB2m` header with KB2n rules.
- **A stale `video.bk2` can no longer be reused.** The encoder now deletes a left-over output
  file before encoding; previously `encode.ps1` waited for "file exists and stopped growing",
  so an old `.bk2` could be accepted as this run's output and pass the flags check.
- **`[OK] encoder:` is printed after the input check** (a wrong input path no longer shows an
  `[OK]` line before the error).
- Report polish: `quarantine:` line naming where the half-built output went, container magic,
  invariant-culture fps (`59.94`, not `59,94`), one `0x00040010` spelling everywhere, and
  `log\flags-mismatch-*.txt` now rotates (20 kept) instead of accumulating forever.
- Docs: corrected the resolution/fps cap wording (only sources *taller than 1440p* are scaled;
  a >60fps source keeps its resolution), and removed the claim that the encoder version lands in
  `log\build-mod-*.log` (it is printed to the console/GUI panel and, for a flags mismatch,
  written into the report file).

## v1.3.0 — 2026-11-26

- A flags mismatch is now **diagnosable**, not just refused: the tool prints the encoder path +
  file version + SHA256 prefix, the container magic and a bit breakdown, and writes
  `log\flags-mismatch-<timestamp>.txt` for the user to send back.
- Measured `/V` → flags mapping documented (`2248/4296/6344/8392` → `0x40010/…11/…12/…13`).
- `hd2-intro-modder.exe` rebuilt from the unchanged GUI source.

## v1.2.0 — 2026-10-15

- Wwise 2026 support: the project is chosen by the installed Wwise major version, and
  `migrate` runs against a **copy** in the output folder (the in-place upgrade is irreversible).
- Audit fixes: `analyze-bink.ps1` uses `-LiteralPath`, only the encoder processes this run
  started are killed, non-ASCII temp dir falls back to the system drive, GUI probe before
  rebuilding the EXE, reachability colour fix, `--ssl-no-revoke` for probes.

## v1.1.0 — 2026-10-14

- The tool refuses to hand over an unusable mod: a failed rescale, `flags != 0x40012` or a failed
  full-frame decode all stop the build and move the half-built output into `output\failed\`.
- ffmpeg/ffprobe promoted from optional to **required** (without ffprobe the source resolution
  cannot be checked, so a blurry/corrupt in-game result cannot be ruled out).
- Dependency panel + `tools\deps.ps1` can fetch ffmpeg and a portable Python after confirmation.

## v1.0.0 — 2026-08-28

- First release: MP4 → `9ba626afa44a3aa3.patch_0` + `.patch_0.stream`, verified in game.
