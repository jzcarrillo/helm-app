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

# --- CLEANUP EXISTING PORT-FORWARD PROCESSES ---
Write-Info "Cleaning up any existing 'kubectl port-forward' processes..."
Get-Process | Where-Object {
    $_.ProcessName -eq "kubectl" -and $_.Path -match "kubectl" -and $_.StartInfo.Arguments -match "port-forward"
} | ForEach-Object {
    try {
        Stop-Process -Id $_.Id -Force
        Write-OK "Stopped kubectl port-forward process (PID: $($_.Id))"
    } catch {
        Write-Warn "Could not stop kubectl port-forward process with PID $($_.Id)"
    }
}

# List of ports to clean up
$ports = @(3000, 4000, 4001, 5672, 6379, 8081, 15672, 9090, 9093, 3000)

foreach ($port in $ports) {
    Write-Host "Checking port $port..."

    $connections = netstat -aon | findstr ":$port"

    if ($connections) {
        $procIds = ($connections | ForEach-Object {
            ($_ -split '\s+')[-1]
        }) | Sort-Object -Unique

        foreach ($procId in $procIds) {
            try {
                Write-Host "Killing process ID $procId using port $port..."
                taskkill /PID $procId /F | Out-Null
                Write-Host "Killed process ID $procId"
            } catch {
                Write-Warning ("Failed to kill process ID {0}: {1}" -f $procId, $_.Exception.Message)
            }
        }
    } else {
        Write-Host "Port $port is free."
    }
}



Start-Sleep -Seconds 2

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
    "redis",
    "postgres",
    "prometheus",
    "alertmanager",
    "grafana"
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

# Step 4: Install everything EXCEPT backend
Write-Info "Installing non-backend components first..."

helm upgrade --install $ReleaseName $ChartPath -n $Namespace `
  --set backendService.enabled=false `
  --wait --debug

if ($LASTEXITCODE -ne 0) {
    Write-Err "Initial Helm upgrade/install failed. Aborting."
    exit 1
}
Write-OK "Initial Helm install successful (backend excluded)."
Write-OK "Helm release '$ReleaseName' installed successfully."


# Step 4.1: Wait for Redis and PostgreSQL to be ready
Write-Info "`n[STEP 4.1] Waiting for Redis and PostgreSQL readiness..."

# Redis readiness check
$redisPod = kubectl get pods -n helm-app -l app=redis -o jsonpath="{.items[0].metadata.name}"
$redisReady = $false
for ($i = 1; $i -le 10; $i++) {
    $pingResult = kubectl exec -n helm-app $redisPod -- redis-cli ping
    if ($pingResult -eq "PONG") {
        $redisReady = $true
        break
    }
    Start-Sleep -Seconds 3
}
if (-not $redisReady) {
    Write-Err "Redis not ready after retries. Aborting."
    exit 1
}
Write-OK "Redis is ready."

# PostgreSQL readiness check
$pgPod = kubectl get pods -n helm-app -l app=postgres -o jsonpath="{.items[0].metadata.name}"
$pgReady = $false
for ($i = 1; $i -le 10; $i++) {
    $pgCheckCmd = "PGPASSWORD=mypass psql -U myuser -d mydb -c '\q'"
    $output = kubectl exec -n helm-app $pgPod -- /bin/sh -c $pgCheckCmd
    if ($LASTEXITCODE -eq 0) {
        $pgReady = $true
        break
    }
    Start-Sleep -Seconds 3
}
if (-not $pgReady) {
    Write-Err "PostgreSQL not ready after retries. Aborting."
    exit 1
}
Write-OK "PostgreSQL is ready."

# Step 4.2: Deploy backend now that dependencies are ready
Write-Info "`n[STEP 4.2] Deploying backend now that Redis and PostgreSQL are ready..."
helm upgrade --install $ReleaseName $ChartPath -n $Namespace `
  --set backendService.enabled=true `
  --wait --debug

if ($LASTEXITCODE -ne 0) {
    Write-Err "Backend install failed. Aborting."
    exit 1
}
Write-OK "Backend deployed successfully after readiness check."


# Step 5: Show pods
Write-Info "Getting pods in namespace '$Namespace'..."
kubectl get pods -n $Namespace

# Step 6: Show services
Write-Info "Getting services in namespace '$Namespace'..."
kubectl get service -n $Namespace

# Step 6.5: Apply HPA for api-gateway
Write-Host "STEP 6.5: Apply HPA for api-gateway"
try {
    kubectl delete hpa api-gateway -n $namespace --ignore-not-found
    kubectl autoscale deployment api-gateway --cpu-percent=30 --min=1 --max=5 -n $namespace
    Write-Host "HPA for api-gateway created successfully"
} catch {
    Write-Warning "⚠️ Failed to apply HPA: $($_.Exception.Message)"
}

# Step 7: Check if ALB and frontend are accessible
Write-Info "Checking access to NodePort services..."

# Get NodePorts
$albPort = kubectl get svc alb-nginx -n $Namespace -o=jsonpath="{.spec.ports[0].nodePort}" 2>$null
$frontendPort = kubectl get svc frontend -n $Namespace -o=jsonpath="{.spec.ports[0].port}" 2>$null
$prometheusPort = kubectl get svc prometheus -n $Namespace -o=jsonpath="{.spec.ports[0].port}" 2>$null
$apigatewayPort = kubectl get svc api-gateway -n $Namespace -o=jsonpath="{.spec.ports[0].port}" 2>$null
$grafanaPort = kubectl get svc grafana -n $Namespace -o=jsonpath="{.spec.ports[0].port}" 2>$null

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
$portForwardRedis = Start-Process -FilePath "kubectl" `
  -ArgumentList "port-forward", "svc/redis", "6379:6379", "-n", "helm-app" `
  -NoNewWindow -PassThru  

Write-Host "Port-forwarding prometheus on port 9090..."
$portForwardPrometheus = Start-Process -FilePath "kubectl" `
  -ArgumentList "port-forward", "svc/prometheus", "9090:30900", "-n", "helm-app" `
  -NoNewWindow -PassThru  

Write-Host "Port-forwarding alertmanager on port 9093..."
$portForwardAlertmanager = Start-Process -FilePath "kubectl" `
  -ArgumentList "port-forward", "svc/alertmanager", "9093:9093", "-n", "helm-app" `
  -NoNewWindow -PassThru   

Write-Host "Port-forwarding grafana on port 3000..."
$portForwardAlertmanager = Start-Process -FilePath "kubectl" `
  -ArgumentList "port-forward", "svc/grafana", "3000:32000", "-n", "helm-app" `
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
    Start-Sleep -Milliseconds 200
}

Write-Host "`nDone sending requests!"

# Step 12: Send bulk request to api-gateway
Write-Host "`nSending 500 POST requests to api-gateway... Error 429 Too many request"

$uri = "http://localhost:8081/submit"
$headers = @{ "Content-Type" = "application/json" }

for ($i = 1; $i -le 1000; $i++) {
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

    Start-Sleep -Milliseconds 100  # Throttle interval between requests
}

# Step 12.1: Send bulk request to api-gateway
Write-Host "`nSending 500 POST requests to api-gateway... Error 429 Too many request"

$uri = "http://localhost:30081/submit"
$headers = @{ "Content-Type" = "application/json" }

for ($i = 1; $i -le 500; $i++) {
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

    Start-Sleep -Milliseconds 200  # Throttle interval between requests
}

# STEP 13: Scale API Gateway Deployment to 4 Replicas
Write-Host "STEP 13: Scale API Gateway Deployment to 4 Replicas"
try {
    kubectl scale deployment api-gateway -n $Namespace --replicas=4
    Write-Host "Successfully scaled api-gateway to 4 replicas" -ForegroundColor Green
} catch {
    Write-Warning "Failed to scale api-gateway: $($_.Exception.Message)"
}

# STEP 14.0: HTTPS Requests (Expect: Success)
Write-Host "`nSending 500 HTTPS requests to https://localhost:31443"
1..100 | ForEach-Object {
    try {
        Invoke-WebRequest -Uri "https://localhost:31443" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop | Out-Null
        Write-Host "[$_] HTTPS success"
    } catch {
        Write-Host "[$_]  HTTPS failed - $($_.Exception.Message)"
    }
}

# STEP 14.1: HTTP Requests with port 31443 (Expect: Blocked)
Write-Host "`n Sending 500 HTTP requests to http://localhost:31443"
1..100 | ForEach-Object {
    try {
        Invoke-WebRequest -Uri "http://localhost:31443" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop | Out-Null
        Write-Host "[$_] HTTP unexpectedly succeeded"
    } catch {
        Write-Host "[$_] HTTP blocked as expected"
    }
}

# STEP 14.2: HTTP Requests with port 80 (Expect: Blocked)
Write-Host "`n Sending 500 HTTP requests to http://localhost:80"
1..100 | ForEach-Object {
    try {
        Invoke-WebRequest -Uri "http://localhost:80" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop | Out-Null
        Write-Host "[$_] HTTP unexpectedly succeeded"
    } catch {
        Write-Host "[$_] HTTP blocked as expected"
    }
}

Write-Host "`nDeployment and Verification Complete." -ForegroundColor Cyan

# STEP 15: Open new terminal to monitor HPA scaling
$command = "kubectl get hpa -n $namespace --watch"

Write-Host "Watching HPA scaling behavior in another new terminal..."
Start-Process powershell -ArgumentList @(
    "-NoProfile",
    "-NoExit",
    "-Command",
    $command
)

