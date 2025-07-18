{{/*
Define backend host for ALB
*/}}
{{- define "alb.backendHost" -}}
{{ .Values.alb.backendHostTpl | default "frontend.helm-app" }}.svc.cluster.local
{{- end }}

{{/*
Define the default NGINX config for ALB
*/}}
{{- define "alb.defaultConf" -}}
server {
    listen 80;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    ssl_certificate /etc/nginx/tls/tls.crt;
    ssl_certificate_key /etc/nginx/tls/tls.key;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

    location / {
        proxy_pass http://frontend.helm-app.svc.cluster.local;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

}
{{- end }}

{{/*
Define frontend service name
*/}}
{{- define "frontend.name" -}}
{{ .Chart.Name }}-frontend
{{- end }}

{{/*
Define frontend full release name
*/}}
{{- define "frontend.fullname" -}}
frontend
{{- end }}

{{- define "api-gateway.fullname" -}}
api-gateway
{{- end }}

{{/*
Define lambda-producer name
*/}}
{{- define "lambda-producer.name" -}}
lambda-producer
{{- end }}

{{/*
Define lambda-producer full name (without release name)
*/}}
{{- define "lambda-producer.fullname" -}}
lambda-producer
{{- end }}