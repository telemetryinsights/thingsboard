# ============================
# Enterprise Build & Deploy Script
# ============================

$ErrorActionPreference = "Stop"
$logFile = "build-deploy-log.txt"

# Step 1: Ask to check-in latest code
$checkin = Read-Host "Do you want to check-in your latest code into the TB repo? (yes/no)"
if ($checkin -eq "yes") {
    Set-Location "C:\GitHub\ti\thingsboard"
    git status | Tee-Object -FilePath $logFile -Append
    git add . | Tee-Object -FilePath $logFile -Append
    $commitMessage = Read-Host "Enter release notes or commit message"
    git commit -m "$commitMessage" | Tee-Object -FilePath $logFile -Append
    git push | Tee-Object -FilePath $logFile -Append
}

# Step 2: Log environment versions
"==== Environment Snapshot (Before Build) ====" | Tee-Object -FilePath $logFile -Append
yarn --version | Tee-Object -FilePath $logFile -Append
node --version | Tee-Object -FilePath $logFile -Append
npm --version | Tee-Object -FilePath $logFile -Append
mvn -v | Tee-Object -FilePath $logFile -Append

# Step 3: Capture dependencies
"==== package.json ====" | Tee-Object -FilePath $logFile -Append
Get-Content package.json | Tee-Object -FilePath $logFile -Append

"==== yarn.lock ====" | Tee-Object -FilePath $logFile -Append
Get-Content yarn.lock | Tee-Object -FilePath $logFile -Append

"==== Maven dependency tree ====" | Tee-Object -FilePath $logFile -Append
mvn dependency:tree -Dverbose | Tee-Object -FilePath $logFile -Append

# Step 4: Build Frontend
"==== Running: yarn install ====" | Tee-Object -FilePath $logFile -Append
yarn install 2>&1 | Tee-Object -FilePath $logFile -Append

"==== Running: yarn build ====" | Tee-Object -FilePath $logFile -Append
yarn build 2>&1 | Tee-Object -FilePath $logFile -Append

# Step 5: Build Backend
"==== Running: mvn clean install ====" | Tee-Object -FilePath $logFile -Append
mvn clean install -DskipTests 2>&1 | Tee-Object -FilePath $logFile -Append

# Step 6: Snapshot versions again
"==== Environment Snapshot (After Build) ====" | Tee-Object -FilePath $logFile -Append
yarn --version | Tee-Object -FilePath $logFile -Append
node --version | Tee-Object -FilePath $logFile -Append
npm --version | Tee-Object -FilePath $logFile -Append
mvn -v | Tee-Object -FilePath $logFile -Append

# Step 7: Backup local repo and re-clone to validate clean env
Set-Location "C:\GitHub\ti"
Rename-Item -Path "thingsboard" -NewName "thingsboard_backup_20250528" -Force

git clone https://github.com/your-org/thingsboard.git thingsboard | Tee-Object -FilePath $logFile -Append
Set-Location "C:\GitHub\ti\thingsboard"
yarn install | Tee-Object -FilePath $logFile -Append
yarn start   | Tee-Object -FilePath $logFile -Append

"==== Build & Verification Complete ====" | Tee-Object -FilePath $logFile -Append
