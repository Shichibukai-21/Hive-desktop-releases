# Updates the Hive server (the Cloudflare Worker in worker/) from the latest Hive code.
# Run it with the one line Claude gives you. It finds the Hive folder, updates it, signs in to Cloudflare if needed,
# and deploys. Nothing else on the PC changes.

$ErrorActionPreference = "Continue"
function Say($t) { Write-Host "`n== $t" -ForegroundColor Yellow }
function Done($t) { Write-Host $t -ForegroundColor Green }
function Fail($t) { Write-Host "`n$t" -ForegroundColor Red; Read-Host "`nPress Enter to close"; exit 1 }

$home_ = $env:USERPROFILE
$android = Join-Path $home_ "Android"
$env:Path = "$android\gh\bin;$env:ProgramFiles\nodejs;$env:ProgramFiles\Git\cmd;$env:APPDATA\npm;$env:Path"

Say "Checking the tools"
$missing = @("git", "node", "npx") | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) }
if ($missing) { Fail "Not found on this PC: $($missing -join ', '). Install Node.js (nodejs.org, the LTS button) and Git, then run this again." }
Done "git and node are here."

Say "Finding the Hive folder"
$isRepo = { param($d) Test-Path (Join-Path $d "worker\wrangler.toml") }
$repo = @("$home_\Hive", "$home_\Documents\Hive", "$home_\Desktop\Hive", "$home_\source\repos\Hive", "$home_\Documents\GitHub\Hive", "C:\Hive", "D:\Hive") |
  Where-Object { & $isRepo $_ } | Select-Object -First 1
if (-not $repo) {
  $repo = Get-ChildItem $home_, "C:\", "D:\" -Directory -Recurse -Depth 3 -Filter "worker" -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName "wrangler.toml") } | ForEach-Object { $_.Parent.FullName } | Select-Object -First 1
}
if (-not $repo) { Fail "No Hive folder with the server code was found on this PC. Run the PC release once (it downloads Hive), then this again." }
Done "Hive is at $repo"

Say "Getting the latest Hive code"
Set-Location $repo
git stash --include-untracked | Out-Null
git checkout main 2>&1 | Out-Null
git pull --ff-only origin main
if ($LASTEXITCODE -ne 0) { Fail "Couldn't update the Hive folder. Copy the red text above and send it to Claude." }
Done "Up to date."

Set-Location (Join-Path $repo "worker")
Say "Checking the Cloudflare sign-in"
npx --yes wrangler@3.99.0 whoami 2>&1 | Tee-Object -Variable who | Out-Null
if (($who | Out-String) -match "not authenticated|You are not logged in") {
  Say "Cloudflare needs you to sign in once: a browser window opens, press Allow"
  npx --yes wrangler@3.99.0 login
  if ($LASTEXITCODE -ne 0) { Fail "The Cloudflare sign-in didn't finish. Run this again and press Allow in the browser." }
}
Done "Signed in to Cloudflare."

Say "Updating the Hive server"
npx --yes wrangler@3.99.0 deploy
if ($LASTEXITCODE -ne 0) { Fail "The server didn't update. Copy the red text above and send it to Claude. Hive keeps working as before." }
Done "`nThe Hive server is updated: reaction notifications and faster files are on."
Read-Host "`nPress Enter to close"
