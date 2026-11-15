# Builds Hive for PC, signs it, and publishes it to Hive-desktop-releases, where every PC's Hive updates from.
# Double-click "Release Hive.cmd" next to it, or run:  powershell -ExecutionPolicy Bypass -File <this file>
# It finds the Hive folder (or downloads it), checks the tools and secret files, builds, then asks before publishing.

# Windows PowerShell 5 treats git's and gh's progress messages as errors under "Stop", so exit codes are checked instead.
$ErrorActionPreference = "Continue"
function Say($t) { Write-Host "`n== $t" -ForegroundColor Yellow }
function Done($t) { Write-Host $t -ForegroundColor Green }
function Fail($t) { Write-Host "`n$t" -ForegroundColor Red; Read-Host "`nPress Enter to close"; exit 1 }

$home_ = $env:USERPROFILE
$android = Join-Path $home_ "Android"
$keys = Join-Path $android "keys"
# The tools installed by install-android.ps1 and rustup aren't always on PATH in a fresh window.
$env:Path = "$android\gh\bin;$home_\.cargo\bin;$env:ProgramFiles\nodejs;$env:ProgramFiles\Git\cmd;$env:Path"

Say "Checking the tools"
$missing = @("git", "node", "npm", "cargo", "gh") | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) }
if ($missing) { Fail "Not found on this PC: $($missing -join ', '). Install them (Node.js, Rust from rustup.rs, Git, GitHub CLI), then run this again." }
gh auth status | Out-Null
if ($LASTEXITCODE -ne 0) { Say "GitHub needs you to sign in once"; gh auth login --web; if ($LASTEXITCODE -ne 0) { Fail "GitHub sign-in didn't finish." } }
Done "git, node, npm, cargo and gh are here."

Say "Finding the Hive folder"
$isRepo = { param($d) Test-Path (Join-Path $d "desktop\src-tauri\tauri.conf.json") }
$repo = @("$home_\Hive", "$home_\Documents\Hive", "$home_\Desktop\Hive", "$home_\source\repos\Hive", "$home_\Documents\GitHub\Hive", "C:\Hive", "D:\Hive") |
  Where-Object { & $isRepo $_ } | Select-Object -First 1
if (-not $repo) {
  $repo = Get-ChildItem $home_, "C:\", "D:\" -Directory -Recurse -Depth 3 -Filter "src-tauri" -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName "tauri.conf.json") } | ForEach-Object { $_.Parent.Parent.FullName } |
    Where-Object { & $isRepo $_ } | Select-Object -First 1
}
if (-not $repo) {
  $repo = "$home_\Hive"
  Say "No Hive folder on this PC, so it's being downloaded to $repo"
  gh repo clone Shichibukai-21/Hive $repo
  if ($LASTEXITCODE -ne 0) { Fail "Couldn't download Hive's code from GitHub." }
}
Done "Hive is at $repo"
Set-Location $repo

Say "Getting the newest code"
# Building rewrites the lock files (npm and cargo note what they installed). They're put back, or the update can't come in.
git checkout -- "desktop/package-lock.json" "desktop/src-tauri/Cargo.lock" "desktop/src-tauri/icons"
# Anything else changed by hand is set aside, never thrown away. "git stash list" shows it, "git stash pop" brings it back.
if (git status --porcelain --untracked-files=no) {
  git -c user.name="Hive release" -c user.email="release@hive.local" stash push -m "Set aside by the Hive release script, $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
  Write-Host "Files you had changed in $repo were set aside with git stash, not deleted." -ForegroundColor Yellow
}
git fetch origin main
if ($LASTEXITCODE -ne 0) { Fail "Couldn't reach GitHub to get the newest code. Check the internet connection." }
git checkout main
if ($LASTEXITCODE -ne 0) { Fail "Couldn't switch to main. Copy the text above and send it to Claude." }
git merge --ff-only origin/main
if ($LASTEXITCODE -ne 0) {
  # This PC's main has commits GitHub doesn't. They're kept on a backup branch, and main matches GitHub.
  $backup = "backup-$(Get-Date -Format 'yyyyMMdd-HHmm')"
  git branch $backup
  git reset --hard origin/main
  if ($LASTEXITCODE -ne 0) { Fail "Couldn't update to the newest code. Copy the text above and send it to Claude." }
  Write-Host "This PC's own commits are kept on the branch $backup." -ForegroundColor Yellow
}
$version = (Get-Content "desktop\src-tauri\tauri.conf.json" -Raw | ConvertFrom-Json).version
Done "Version $version"

Say "Checking the secret files"
# They never go to GitHub. They're copied from Documents\Hive when they aren't in the Hive folder yet.
$secrets = @(@{ want = "drive-client.json"; name = "drive-client.json" }, @{ want = "app\google-services.json"; name = "google-services.json" })
foreach ($s in $secrets) {
  $at = Join-Path $repo $s.want
  if (-not (Test-Path $at)) {
    $from = @("$home_\Documents\Hive\$($s.name)", "$home_\Downloads\$($s.name)", "$home_\Desktop\$($s.name)") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($from) { Copy-Item $from $at; Done "Copied $($s.name) from $from" }
    else { Fail "$($s.name) is missing. Put it in $at (it's on the PC that built Hive before), then run this again." }
  }
}
$keyFile = Join-Path $keys "hive-desktop.key"
$passFile = Join-Path $keys "hive-desktop.pass"
if (-not (Test-Path $keyFile)) { Fail "The signing key isn't at $keyFile. Without it, PCs can't update. Copy it from the PC that made 1.1.0." }
$env:TAURI_SIGNING_PRIVATE_KEY = Get-Content $keyFile -Raw
$env:TAURI_SIGNING_PRIVATE_KEY_PASSWORD = if (Test-Path $passFile) { (Get-Content $passFile -Raw).Trim() } else { "" }
Done "Secret files and signing key found."

Say "Building Hive $version (the first build takes 5 to 15 minutes)"
Set-Location (Join-Path $repo "desktop")
npm install
if ($LASTEXITCODE -ne 0) { Fail "npm install failed. Copy the red text above and send it to Claude." }
npx tauri build
if ($LASTEXITCODE -ne 0) { Fail "The build failed. Copy the red text above and send it to Claude." }

$nsis = Join-Path $repo "desktop\src-tauri\target\release\bundle\nsis"
$setup = Get-ChildItem $nsis -Filter "*_$version*-setup.exe" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $setup) { Fail "The build finished but no setup for $version is in $nsis." }
$sig = "$($setup.FullName).sig"
if (-not (Test-Path $sig)) { Fail "The setup wasn't signed ($sig is missing), so PCs couldn't update to it. Check the signing key's password." }

$out = Join-Path $repo "releases\desktop-$version"
New-Item -ItemType Directory -Force $out | Out-Null
Copy-Item $setup.FullName (Join-Path $out "Hive-Setup.exe") -Force
# ReadAllText, not Get-Content: Get-Content's text carries PowerShell's own properties, and ConvertTo-Json
# wrote them out as {"value": ..., "PSPath": ...}. The updater couldn't read that, so 2.0.0 and 2.0.1 never reached anyone.
$notes = [IO.File]::ReadAllText((Join-Path $repo "desktop\whatsnew.md"))
$latest = [ordered]@{
  version = $version
  notes = $notes
  pub_date = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
  platforms = [ordered]@{ "windows-x86_64" = [ordered]@{
    signature = ([IO.File]::ReadAllText($sig)).Trim()
    url = "https://github.com/Shichibukai-21/Hive-desktop-releases/releases/download/v$version/Hive-Setup.exe"
  } }
}
# Without a byte-order mark: the updater can't read JSON that starts with one, which is what PowerShell 5's utf8 writes.
[IO.File]::WriteAllText((Join-Path $out "latest.json"), ($latest | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
$check = Get-Content (Join-Path $out "latest.json") -Raw | ConvertFrom-Json
if (-not ($check.notes -is [string]) -or -not ($check.platforms."windows-x86_64".signature -is [string])) { Fail "latest.json came out wrong, so PCs couldn't update. Send this window to Claude." }
Done "Built: $out\Hive-Setup.exe"

Say "Try it before everyone gets it"
Write-Host "The new setup is opening. Install it, then check: sending a photo, scrolling with your touchpad or mouse,"
Write-Host "clicking a notification, and right-click a file > Send to > Hive."
Start-Process (Join-Path $out "Hive-Setup.exe")
$go = Read-Host "`nType yes to publish $version to everyone, or anything else to stop here"
if ($go -ne "yes") { Write-Host "Not published. The files are in $out. Run this again when you're ready."; Read-Host "Press Enter to close"; exit 0 }

Say "Publishing $version"
Set-Location $out
gh release create "v$version" "Hive-Setup.exe" "latest.json" -R Shichibukai-21/Hive-desktop-releases --title "Hive for Windows $version" --notes-file (Join-Path $repo "desktop\whatsnew.md") --latest
if ($LASTEXITCODE -ne 0) { Fail "Publishing failed. Copy the red text above and send it to Claude." }
# The server half of a release (worker/). Not fatal: the PCs are already updating.
$w = Read-Host "`nType yes to also update the Hive server (needs the Cloudflare login on this PC), or press Enter to skip"
if ($w -eq "yes") {
  Set-Location (Join-Path $repo "worker")
  npx wrangler@3.99.0 deploy
  if ($LASTEXITCODE -ne 0) { Write-Host "The server didn't update. Hive still works; send this window to Claude." -ForegroundColor Yellow } else { Done "The server is updated." }
}
# Hive 3.5: the database rules switch on end-to-end encryption. Phones on 3.5 send readably until these are live, then
# seal everything by themselves; apps older than 3.5 can no longer send once they are. Needs firebase-admin.json here.
if (Test-Path (Join-Path $repo "firebase-admin.json")) {
  $r = Read-Host "`nType yes to switch on end-to-end encryption now (updates the database rules), or press Enter to skip"
  if ($r -eq "yes") {
    Set-Location $repo
    node tools/deploy-rules.mjs
    if ($LASTEXITCODE -ne 0) { Write-Host "The rules didn't update. Nothing is broken; send this window to Claude." -ForegroundColor Yellow } else { Done "Encryption is on." }
  }
} else { Write-Host "firebase-admin.json isn't in $repo, so encryption stays off for now. Copy it there and run this again." -ForegroundColor Yellow }
Done "`nHive $version is out. PCs running Hive find it within a few minutes of starting, or every 6 hours."
Read-Host "Press Enter to close"
