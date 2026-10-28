<#
Simula os webhooks da Helena contra o dispatcher rodando localmente,
sem precisar de ngrok nem de mensagens reais no WhatsApp.

Uso (com o automacao-kanban.ps1 rodando em outro terminal):
    powershell -File exemplos\testar-local.ps1 -ContactId '<id-de-um-contato-com-card-aberto>'
#>
param(
    [Parameter(Mandatory)][string]$ContactId,
    [string]$SessionId = '',
    [int]$Port = 8091
)

$url = "http://localhost:$Port/"
$eventos = @(
    @{ eventType = 'MESSAGE_RECEIVED';   content = @{ contactId = $ContactId; sessionId = $SessionId; text = 'Oi, tenho interesse' } },
    @{ eventType = 'MESSAGE_SENT';       content = @{ contactId = $ContactId; sessionId = $SessionId; origin = 'USER'; text = 'Olá! Segue a proposta.' } },
    @{ eventType = 'CONTACT_TAG_UPDATE'; content = @{ id = $ContactId; tagNames = @('Proposta enviada') } }
)

foreach ($e in $eventos) {
    Write-Host "Enviando $($e.eventType)..." -ForegroundColor Cyan
    $json = $e | ConvertTo-Json -Depth 5
    Invoke-RestMethod -Uri $url -Method POST -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/json; charset=utf-8' | Out-Null
    Start-Sleep -Seconds 2
}
Write-Host "Pronto. Confira o card no kanban da Helena." -ForegroundColor Green
