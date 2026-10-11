# pi-anyway

**Restricted conditions. Still pi.**

You want to use pi. Your Windows development environment can't reach npm repositories or GitHub Releases because of some bullshit corporate proxy settings or internal open-source library policies. But luckily, it can clone Git repositories.

That should be enough.

pi-anyway makes official pi releases available through a Git repository your environment can access, so you can install and update pi without reaching its usual distribution channels.

Just clone the repo, run the deploy script, and you've got pi.

## Install on Windows x64

You need Git and PowerShell 5.1 or later. Run:

```powershell
git clone https://github.com/ChenAuCarre/pi-anyway.git
cd pi-anyway
.\deploy.ps1 -Version v1.1.0
```

Pick a version from the repository's `dist/windows-x64/<tag>` branches. If the version you want is missing, run **Actions → Sync official pi release** with the exact upstream tag, then wait for it to finish. You'll need repository write access.

The script pulls the release from `origin`, checks it, and installs everything into **`$HOME\pi`**. No ZIP to prepare. No extra clone.


## Update and backups

Close pi. Run the deploy command again with the version you want.

Already have `$HOME\pi`? The script backs up the whole directory, hidden files included, before replacing it:

```text
$HOME\pi-backup-<timestamp>-<unique-id>.zip
```

If deployment fails, the script preserves the old installation.
