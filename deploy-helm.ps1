param(
    [string]$ReleaseName = "helm-appv1",
    [string]$Namespace   = "helm-app",
    [string]$ChartPath   = "./helm-proj"
)

function Write-Info ($msg)  { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-OK   ($msg)  { Write-Host "[OK]   $msg" -ForegroundColor Green }
function Write-Warn ($msg)  { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Err  ($msg)  { Write-Host "[ERR]  $msg" -ForegroundColor Red }

function Require-Command ($cmd) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Err "Command '$cmd' not found. Please install it."
        exit 1
    }
}

Require-Command helm
Require-Command kubectl

# --- CLEANUP STEP ---
Write-Info "Cleaning up namespace '$Namespace' to remove conflicting resources..."
helm uninstall $ReleaseName -n $Namespace | Out-Null
kubectl delete all --all -n $Namespace --ignore-not-found
kubectl delete configmap --all -n $Namespace --ignore-not-found
kubectl delete secret --all -n $Namespace --ignore-not-found

Write-Info "Ensuring namespace '$Namespace' is clean..."
kubectl delete namespace $Namespace --ignore-not-found
kubectl wait --for=delete ns/$Namespace --timeout=60s 2>$null
kubectl create namespace $Namespace
Write-OK "Namespace '$Namespace' cleaned and recreated."

# Step 1: Uninstall existing release
Write-Info "Uninstalling existing release '$ReleaseName' from namespace '$Namespace'..."
helm uninstall $ReleaseName -n $Namespace
if ($LASTEXITCODE -eq 0) {
    Write-OK "Uninstalled release '$ReleaseName'."
} else {
    Write-Info "Release not found or already removed."
}

# Step 2: Helm lint
Write-Info "Running 'helm lint'..."
helm lint $ChartPath
if ($LASTEXITCODE -ne 0) {
    Write-Err "Helm lint failed. Aborting."
    exit 1
}
Write-OK "Helm lint passed."

# Step 3: Dry-run install
Write-Info "Running dry-run Helm install..."
helm install $ReleaseName $ChartPath -n $Namespace --dry-run --debug
if ($LASTEXITCODE -ne 0) {
    Write-Err "Dry-run failed. Aborting."
    exit 1
}
Write-OK "Dry-run successful."

# Step 4: Real Helm install
Write-Info "Performing actual Helm install..."
helm install $ReleaseName $ChartPath -n $Namespace --wait --debug
if ($LASTEXITCODE -ne 0) {
    Write-Err "Helm install failed. Aborting."
    exit 1
}
Write-OK "Helm release '$ReleaseName' installed successfully."

# Step 5: Show pods
Write-Info "Getting pods in namespace '$Namespace'..."
kubectl get pods -n $Namespace

# Step 6: Show services
Write-Info "Getting services in namespace '$Namespace'..."
kubectl get service -n $Namespace

# Step 7: Check if ALB and frontend are accessible
Write-Info "Checking access to NodePort services..."

# Get NodePorts
$albPort = kubectl get svc alb-nginx -n $Namespace -o=jsonpath="{.spec.ports[0].nodePort}" 2>$null
$frontendPort = kubectl get svc frontend -n $Namespace -o=jsonpath="{.spec.ports[0].port}" 2>$null

$nodeIP = "localhost"

# Check ALB
if ($albPort) {
    $albURL = "https://${nodeIP}:${albPort}"
    Write-Info "Testing ALB at $albURL ..."
    try {
        add-type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint srvPoint, X509Certificate certificate, WebRequest request, int certificateProblem) {
        return true;
    }
}
"@
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
        $albResponse = Invoke-WebRequest -Uri $albURL -UseBasicParsing -TimeoutSec 5
        if ($albResponse.Content -match "Hello from Helm Frontend!") {
            Write-OK "ALB responded correctly: Hello from Helm Frontend!"
        } else {
            Write-Warn "ALB responded but did not return expected content:"
            Write-Host $albResponse.Content
        }
    } catch {
        Write-Err "ALB check failed. $_"
    }
} else {
    Write-Warn "ALB NodePort not found."
}

# Check Frontend
if ($frontendPort) {
    Write-Info "Testing Frontend at http://${nodeIP}:${frontendPort} ..."
    try {
        $frontendResponse = Invoke-WebRequest -Uri "http://${nodeIP}:${frontendPort}" -UseBasicParsing -TimeoutSec 5
        if ($frontendResponse.StatusCode -eq 200) {
            Write-OK "Frontend responded with status: $($frontendResponse.StatusCode)"
        } else {
            Write-Warn "Frontend returned unexpected status: $($frontendResponse.StatusCode)"
        }
    } catch {
        Write-Warn "Frontend not accessible at http://${nodeIP}:${frontendPort}"
    }
} else {
    Write-Warn "Frontend NodePort not found."
}

# Step 8: Show logs of API Gateway
Write-Info "Getting logs from API Gateway pods..."

$apiGatewayPods = kubectl get pods -n $Namespace -l app=api-gateway -o jsonpath="{.items[*].metadata.name}"

if (-not $apiGatewayPods) {
    Write-Warn "No API Gateway pods found."
} else {
    foreach ($pod in $apiGatewayPods.Split(" ")) {
        Write-Info "Logs from pod: $pod"
        kubectl logs $pod -n $Namespace
        Write-Host "`n------------------------------------------------------------`n"
    }
}
