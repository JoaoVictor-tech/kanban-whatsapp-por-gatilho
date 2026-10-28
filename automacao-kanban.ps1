<#
Dispatcher de webhooks que move cards do kanban (CRM da Helena) conforme o que
acontece no WhatsApp:
  - cliente mandou mensagem   -> card vai para "Em atendimento"
  - vendedor respondeu        -> card vai para "Aguardando cliente"
  - etiqueta aplicada         -> card vai para a coluna mapeada (ou e marcado como perdido)

Combina:
  - lib/Helena.ps1: funcoes prontas para a API da Helena
  - o servidor HTTP deste mesmo script, que recebe os webhooks e decide o que fazer

Uso:
    copy config.example.json config.json   (e preencha com os IDs do seu painel)
    $env:HELENA_TOKEN = 'pn_xxxxxxxxxxxx'
    powershell -File automacao-kanban.ps1
    (em outro terminal) ngrok http 8091
    New-HelenaWebhookSubscription -Url 'https://xxxx.ngrok-free.app/' -Events @('MESSAGE_RECEIVED','MESSAGE_SENT','CONTACT_TAG_UPDATE')
#>
param(
    [int]$Port = 8091,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)

# --- Carrega as funcoes da API ---
. (Join-Path $PSScriptRoot 'lib\Helena.ps1')

if (-not $env:HELENA_TOKEN) { throw "Defina `$env:HELENA_TOKEN antes de rodar (ou chame Connect-Helena manualmente)." }
Connect-Helena -Token $env:HELENA_TOKEN

# --- Configuracao do funil ---
# Para descobrir os IDs do seu painel:
#   Get-HelenaPanels -IncludeSteps -Type SALES | ConvertTo-Json -Depth 5
if (-not (Test-Path $ConfigPath)) { throw "Nao achei $ConfigPath — copie config.example.json para config.json e preencha." }
$Config = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

$PanelId = $Config.panelId
$Steps = @{}
foreach ($p in $Config.steps.PSObject.Properties) { $Steps[$p.Name] = $p.Value }
# Etiqueta (nome exato na Helena) -> coluna de destino; null = marcar o card como perdido (LOST)
$TagToStep = @{}
foreach ($p in $Config.tagToStep.PSObject.Properties) {
    $TagToStep[$p.Name] = if ($p.Value) { $Steps[$p.Value] } else { $null }
}

function Find-CardForContact {
    param([string]$ContactId, [string]$SessionId)
    if (-not $ContactId -and -not $SessionId) { return $null }
    $q = @{ PanelId = $PanelId; Statuses = @('OPEN') }
    if ($ContactId) { $q.ContactId = $ContactId }
    $result = Invoke-HelenaApi -Group crm -Path '/v2/panel/card' -Query $q
    $cards = $result.items
    if ($SessionId) { $cards = $cards | Where-Object { $_.sessionId -eq $SessionId } }
    return $cards | Select-Object -First 1
}

function Handle-MessageReceived {
    param($content)
    $card = Find-CardForContact -ContactId $content.contactId -SessionId $content.sessionId
    if (-not $card) { Write-Host "  (sem card OPEN pra esse contato/sessao — pulei)" -ForegroundColor DarkGray; return }
    Write-Host "  Movendo card $($card.id) -> EmAtendimento" -ForegroundColor Green
    Move-HelenaPanelCard -CardId $card.id -StepId $Steps.EmAtendimento
}

function Handle-MessageSent {
    param($content)
    # opcional: ignorar mensagens de bot, so contar resposta humana
    if ($content.origin -eq 'BOT') { return }
    $card = Find-CardForContact -ContactId $content.contactId -SessionId $content.sessionId
    if (-not $card) { return }
    Write-Host "  Movendo card $($card.id) -> AguardandoCliente" -ForegroundColor Green
    Move-HelenaPanelCard -CardId $card.id -StepId $Steps.AguardandoCliente
}

function Handle-TagUpdate {
    param($content)
    foreach ($tag in $content.tagNames) {
        if ($TagToStep.ContainsKey($tag)) {
            $card = Find-CardForContact -ContactId $content.id
            if (-not $card) { continue }
            $destino = $TagToStep[$tag]
            if ($destino) {
                Write-Host "  Etiqueta '$tag' -> movendo card $($card.id)" -ForegroundColor Green
                Move-HelenaPanelCard -CardId $card.id -StepId $destino
            } else {
                Write-Host "  Etiqueta '$tag' -> marcando LOST no card $($card.id)" -ForegroundColor Green
                Set-HelenaPanelCardStatus -CardId $card.id -Status LOST
            }
        }
    }
}

function Handle-HelenaEvent {
    param($evt)
    switch ($evt.eventType) {
        'MESSAGE_RECEIVED'    { Handle-MessageReceived -content $evt.content }
        'MESSAGE_SENT'        { Handle-MessageSent -content $evt.content }
        'CONTACT_TAG_UPDATE'  { Handle-TagUpdate -content $evt.content }
        default { Write-Host "  Evento sem handler: $($evt.eventType)" -ForegroundColor DarkGray }
    }
}

# --- Servidor HTTP ---
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "Dispatcher ouvindo em http://localhost:$Port/ — exponha com: ngrok http $Port" -ForegroundColor Cyan

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $body = ''
        if ($request.HasEntityBody) {
            $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
            $body = $reader.ReadToEnd()
            $reader.Close()
        }

        Write-Host "`n[$(Get-Date -Format o)] webhook recebido" -ForegroundColor Yellow
        try {
            $evt = $body | ConvertFrom-Json -ErrorAction Stop
            if ($evt.eventType) {
                Handle-HelenaEvent -evt $evt
            } else {
                Write-Host "  Payload sem 'eventType' — provavelmente lead externo. Corpo bruto:" -ForegroundColor DarkGray
                Write-Host $body
                # TODO: ajustar aqui o parser do payload de lead real (nome/telefone/email/origem)
                # depois de ver o formato no webhook-receiver.ps1, e chamar:
                #   New-HelenaContact -Upsert -Name .. -PhoneNumber .. -TagNames @('lead-externo')
                #   New-HelenaPanelCard -StepId $Steps.NovoLead -Title .. -ContactIds @($contact.id)
            }
        } catch {
            Write-Host "  Erro processando payload: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host $body
        }

        $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
        $context.Response.ContentType = 'application/json'
        $context.Response.ContentLength64 = $respBytes.Length
        $context.Response.OutputStream.Write($respBytes, 0, $respBytes.Length)
        $context.Response.OutputStream.Close()
    }
} finally {
    $listener.Stop()
    $listener.Close()
}
