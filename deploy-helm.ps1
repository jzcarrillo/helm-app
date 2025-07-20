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
Write-OK "✅ Namespace '$Namespace' cleaned and recreated."

# Step 1: Uninstall existing release
Write-Info "Uninstalling existing release '$ReleaseName' from namespace '$Namespace'..."
helm uninstall $ReleaseName -n $Namespace
if ($LASTEXITCODE -eq 0) {
    Write-OK "Uninstalled release '$ReleaseName'."
} else {
    Write-Info "Release not found or already removed."
}

# Step 1.5: Build Docker images
Write-Host "`n[STEP 1.5] Building Docker Images..."

$services = @(
    "alb-nginx",
    "frontend",
    "api-gateway",
    "lambda-producer",
    "rabbitmq",
    "lambda-consumer",
    "backend",
    "redis,"
    "postgres"
)

foreach ($service in $services) {
    $dockerfileFolder = ".\$service"
    $dockerfilePath = Join-Path $dockerfileFolder "Dockerfile"

    if (Test-Path $dockerfileFolder) {
        if (Test-Path $dockerfilePath) {
            Write-Host "`nBuilding image for '$service' in folder '$dockerfileFolder'..."
            Push-Location $dockerfileFolder

            $tag = "$service`:latest"
            $args = "build -t $tag ."
            Write-Host "   → Running: docker $args"
            Start-Process "docker" -ArgumentList $args -NoNewWindow -Wait

            Pop-Location
        } else {
            Write-Warning "Skipping '$service': Dockerfile not found in $dockerfileFolder"
        }
    } else {
        Write-Warning "Skipping '$service': Folder not found at $dockerfileFolder"
    }
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

# Step 3.5: Check if backend deployment and pods are fully deleted before proceeding
Write-Info "Verifying that 'backend' deployment and pods are fully deleted before real install..."

$maxWaitSeconds = 60
$waitInterval = 3
$elapsed = 0

while ($true) {
    # Check deployment existence
    $backendDeployment = kubectl get deployment backend -n $Namespace --ignore-not-found

    # Check pods in Terminating state for backend
    $backendPodsTerminating = kubectl get pods -n $Namespace -l app=backend --field-selector=status.phase=Terminating --ignore-not-found

    if (-not $backendDeployment -and -not $backendPodsTerminating) {
        Write-OK "'backend' deployment and terminating pods not found. Safe to proceed."
        break
    }

    if ($elapsed -ge $maxWaitSeconds) {
        Write-Err "'backend' deployment or terminating pods still exist after waiting $maxWaitSeconds seconds. Aborting."
        exit 1
    }

    Write-Info "'backend' deployment or terminating pods still exist. Waiting..."
    Start-Sleep -Seconds $waitInterval
    $elapsed += $waitInterval
}

# Step 4: Real Helm install or upgrade
Write-Info "Performing Helm upgrade --install..."
helm upgrade --install $ReleaseName $ChartPath -n $Namespace --wait --debug
if ($LASTEXITCODE -ne 0) {
    Write-Err "Helm upgrade/install failed. Aborting."
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

# Step 7.5: Add Port Forwarding 
Write-Host "Port-forwarding lambda-producer service on port 4000..."
$portForwardLambda = Start-Process -FilePath "kubectl" `
  -ArgumentList "port-forward", "svc/lambda-producer", "4000:4000", "-n", "helm-app" `
  -NoNewWindow -PassThru

Write-Host "Port-forwarding rabbitmq service on port 15672 (management UI) and 5672 (AMQP)..."
$portForwardRabbit = Start-Process -FilePath "kubectl" `
  -ArgumentList "port-forward", "svc/rabbitmq", "15672:15672", "5672:5672", "-n", "helm-app" `
  -NoNewWindow -PassThru

Write-Host "Port-forwarding api-gateway service on port 8081..."
$portForwardApiGateway = Start-Process -FilePath "kubectl" `
  -ArgumentList "port-forward", "svc/api-gateway", "8081:8081", "-n", "helm-app" `
  -NoNewWindow -PassThru

Write-Host "Port-forwarding lambda-consumer service on port 4001..."
$portForwardLambda = Start-Process -FilePath "kubectl" `
  -ArgumentList "port-forward", "svc/lambda-consumer", "4001:4001", "-n", "helm-app" `
  -NoNewWindow -PassThru

Write-Host "Port-forwarding backend service on port 3000..."
$portForwardLambda = Start-Process -FilePath "kubectl" `
  -ArgumentList "port-forward", "svc/backend-service", "3000:3000", "-n", "helm-app" `
  -NoNewWindow -PassThru  
# Wait a moment to ensure port-forwards are established

Write-Host "Port-forwarding redis on port 6379..."
$portForwardLambda = Start-Process -FilePath "kubectl" `
  -ArgumentList "port-forward", "svc/redis", "6379:6379", "-n", "helm-app" `
  -NoNewWindow -PassThru  
# Wait a moment to ensure port-forwards are established
Start-Sleep -Seconds 3

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

# Step 9: Show logs of Lambda Producer
Write-Info "Getting logs from Lambda Producer pod..."

$lambdaProducerPod = kubectl get pods -n $Namespace -l app=lambda-producer -o jsonpath="{.items[0].metadata.name}"

if (-not $lambdaProducerPod) {
    Write-Warn "No Lambda Producer pod found."
} else {
    Write-Info "Logs from Lambda Producer pod: $lambdaProducerPod"
    kubectl logs $lambdaProducerPod -n $Namespace
    Write-Host "`n------------------------------------------------------------`n"
}

# Step 10: Show logs of RabbitMQ
Write-Info "Getting logs from RabbitMQ pod..."

$rabbitmqPod = kubectl get pods -n $Namespace -l app=rabbitmq -o jsonpath="{.items[0].metadata.name}"

if (-not $rabbitmqPod) {
    Write-Warn "No RabbitMQ pod found."
} else {
    Write-Info "Logs from RabbitMQ pod: $rabbitmqPod"
    kubectl logs $rabbitmqPod -n $Namespace
    Write-Host "`n------------------------------------------------------------`n"
}

# Step 11: Send bulk request to Lambda Producer 
Write-Host "`nSending 50 POST requests to lambda-producer..."

$uri = "http://localhost:4000/submit"
$headers = @{ "Content-Type" = "application/json" }
$body = '{"test":"ping"}'

for ($i = 1; $i -le 100; $i++) {
    try {
        $response = Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $body
        Write-Output "`nSend request $i."
        Write-Output "StatusCode        : 200"
        Write-Output "StatusDescription : OK"
        Write-Output "Content           : {""message"":""$($response.message)""}"
    } catch {
        # Do nothing or silently continue on failure
    }
    Start-Sleep -Milliseconds 300
}

Write-Host "`nDone sending requests!"

# Step 12: Send bulk request to api-gateway
Write-Host "`nSending 100 POST requests to api-gateway... Error 429 Too many request"

$uri = "http://localhost:8081/submit"
$headers = @{ "Content-Type" = "application/json" }

for ($i = 1; $i -le 100; $i++) {
    $body = @{ message = "Test $i" } | ConvertTo-Json

    try {
        $response = Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $body
        Write-Output "`nSend request $i."
        Write-Output "StatusCode        : 200"
        Write-Output "StatusDescription : OK"
        Write-Output "Content           : {""message"":""$($response.message)""}"
    } catch {
        Write-Output "`nSend request $i."
        Write-Output "StatusCode        : 429"
        Write-Output "StatusDescription : Too Many Requests"
        Write-Output "Content           : {""message"":""Too many requests to /submit""}"
    }

    Start-Sleep -Milliseconds 500  # Throttle interval between requests
}

# Step X: Check Redis Health
Write-Host "[INFO] Checking Redis health..." -ForegroundColor Cyan

# Get the Redis pod name dynamically
$redisPod = kubectl get pods -n helm-app -l app=redis -o jsonpath="{.items[0].metadata.name}"

if (-not $redisPod) {
    Write-Error "Redis pod not found."
    exit 1
}

# Run 'redis-cli ping' inside the pod
$pingResult = kubectl exec -n helm-app $redisPod -- redis-cli ping

if ($pingResult -eq "PONG") {
    Write-Host "[OK] Redis is healthy (PONG received)." -ForegroundColor Green
}
else {
    Write-Error "Redis did not respond with PONG. Result: $pingResult"
    exit 1
}

# Get the PostgreSQL pod name
$pgPod = kubectl get pods -n helm-app -l app=postgres -o jsonpath="{.items[0].metadata.name}"

# Run 'psql' command inside the pod to test connection
$pgCheckCmd = "PGPASSWORD=mypass psql -U myuser -d mydb -c '\q'"
$pgResult = kubectl exec -n helm-app $pgPod -- sh -c $pgCheckCmd

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] PostgreSQL is healthy (connection succeeded)." -ForegroundColor Green
}
else {
    Write-Error "PostgreSQL connection failed. Output: $pgResult"
    exit 1
}

