param(
    [string]$ReleaseName = "alb-nginx",
    [string]$ChartPath   = "./helm-proj",
    [string]$Namespace   = "helm-poc",
    [string]$ValuesFile  = "./helm-proj/values.yaml",
    [switch]$Wait,                # Adds --wait to Helm install
    [switch]$DebugMode,           # Verbose output
    [switch]$Validate             # Runs lint and dry‑run before install
)

function Write-Info ($msg)  { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-OK   ($msg)  { Write-Host "[OK]   $msg" -ForegroundColor Green }
function Write-Warn ($msg)  { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Err  ($msg)  { Write-Host "[ERR]  $msg" -ForegroundColor Red }

function Require-Command ($cmd) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Err "Command '$cmd' not found. Please install it first."
        exit 1
    }
}

# --- Pre‑flight checks -----------------------------------------------------
Require-Command kubectl
Require-Command helm

if ($DebugMode) { $VerbosePreference = "Continue" }

# --- Ensure namespace exists ----------------------------------------------
Write-Info "Checking if namespace '$Namespace' exists..."
$ns = kubectl get namespace $Namespace -o jsonpath='{.metadata.name}' 2>$null
if (-not $ns) {
    Write-Info "Namespace not found. Creating..."
    kubectl create namespace $Namespace | Out-Null
    Write-OK "Namespace '$Namespace' created."
} else {
    Write-OK "Namespace '$Namespace' already exists."
}

# --- Always start fresh: uninstall existing release if present -------------
Write-Info "Checking for existing Helm release '$ReleaseName'..."
$releaseExists = helm list -n $Namespace --short | Where-Object { $_ -eq $ReleaseName }
if ($releaseExists) {
    Write-Warn "Existing release found. Uninstalling..."
    helm uninstall $ReleaseName -n $Namespace
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Failed to uninstall existing release '$ReleaseName'."
        exit 1
    }
    Start-Sleep -Seconds 3
    Write-OK "Previous release '$ReleaseName' uninstalled."
} else {
    Write-OK "No existing release found."
}

# --- Optional validation (lint + dry‑run) ---------------------------------
if ($Validate) {
    Write-Info "Running 'helm lint'..."
    helm lint $ChartPath
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Helm lint failed. Aborting."
        exit 1
    }
    Write-OK "Helm lint passed."

    Write-Info "Running 'helm install --dry-run'..."
    $dryRunArgs = @(
        "install", $ReleaseName, $ChartPath,
        "--namespace", $Namespace,
        "--values", $ValuesFile,
        "--dry-run",
        "--debug"
    )
    helm @dryRunArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Helm dry‑run failed. Aborting deployment."
        exit 1
    }
    Write-OK "Dry‑run successful."
}

# --- Fresh install ---------------------------------------------------------
Write-Info "Installing Helm release '$ReleaseName'..."
$helmInstallArgs = @(
    "install", $ReleaseName, $ChartPath,
    "--namespace", $Namespace,
    "--values", $ValuesFile
)
if ($Wait) { $helmInstallArgs += "--wait" }

helm @helmInstallArgs
if ($LASTEXITCODE -ne 0) {
    Write-Err "Helm install failed."
    exit $LASTEXITCODE
}
Write-OK "Helm release '$ReleaseName' installed successfully."

# --- Post‑deploy summary ---------------------------------------------------
Write-Info "Listing resources in namespace '$Namespace'..."
kubectl get all -n $Namespace
