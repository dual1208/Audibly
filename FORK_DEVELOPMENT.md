# Fork development on Windows

The fork adds a deterministic command surface around the .NET 8 / WinUI 3
solution.

## Local workflow

```powershell
./eng/windows-dev.ps1 Bootstrap
./eng/windows-dev.ps1 Verify
./eng/windows-dev.ps1 Package
./eng/windows-dev.ps1 Install
./eng/windows-dev.ps1 Update
./eng/windows-dev.ps1 CI       # verify → signed MSIX → install/upgrade → smoke
```

The versioned MSIX has isolated identity `dual1208.AudiblyFork` and publisher
`CN=dual1208`. `Package` requires the reusable current-user certificate named
`Codex Local App Package Signing`; private key material remains in the Windows
certificate store. Generate and trust its public certificate once through the
elevated `codex-admin` session:

```powershell
C:\Users\anfan\windows_fun\powershell\scripts\Ensure-LocalAppPackageSigningCertificate.ps1
```

`Install` and `Update` use `Add-AppxPackage` and cannot overwrite the upstream
Store identity. Each package derives a four-part version from UTC time so the
update step exercises an actual in-place AppX deployment.

Rollback only the app:

```powershell
./eng/windows-dev.ps1 Uninstall
```

Remove the shared certificate only when no other local package needs it:

```powershell
C:\Users\anfan\windows_fun\powershell\scripts\Ensure-LocalAppPackageSigningCertificate.ps1 -Remove
```

Artifacts live under `.artifacts/windows-x64` and are ignored by Git.

## Local CI

`./eng/windows-dev.ps1 CI` is the workstation CI entry point. It verifies the
solution, builds and signs a versioned MSIX, installs or upgrades the exact fork
identity, launches it through its AUMID, and requires the process to remain
healthy for ten seconds. There is intentionally no GitHub Actions workflow.

## Format scope

The fork accepts `.m4b`, `.m4a`, and `.mp3` through the single-file picker,
multi-file picker, watched-folder scan, and package file associations. Keep
those four surfaces aligned whenever another audio extension is added.

## Architecture

See `docs/ARCHITECTURE.md` for the MVVM map and tutorials. `MEMORY.md` is the
compact future-agent index.

## Syncing upstream

```powershell
git fetch upstream
git rebase upstream/main
git push origin HEAD
```
