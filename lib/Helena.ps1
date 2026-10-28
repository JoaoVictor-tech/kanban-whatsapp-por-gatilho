<#
Helena API — helpers PowerShell
Uso:
    . .\Helena.ps1
    Connect-Helena -Token 'pn_xxxxxxxxxxxx'
    Get-HelenaPanels -IncludeSteps
    Get-HelenaPanelCards -PanelId '<id>'
    Move-HelenaPanelCard -CardId '<id>' -StepId '<id-coluna-destino>'

Base URLs variam por grupo de endpoint (ver reference/*.md nesta skill):
    core -> contatos, tags, custom fields, webhooks, departamentos, agentes
    chat -> canais, sessoes, mensagens, templates, sequencias, chatbot
    crm  -> paineis/cards (kanban)
#>

$script:HelenaToken = $env:HELENA_TOKEN
$script:HelenaBase = @{
    core = 'https://api.helena.run/core'
    chat = 'https://api.helena.run/chat'
    crm  = 'https://api.helena.run/crm'
}

function Connect-Helena {
    param([Parameter(Mandatory)][string]$Token)
    $script:HelenaToken = $Token
    Write-Host "Token Helena configurado nesta sessao." -ForegroundColor Green
}

function Invoke-HelenaApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('core','chat','crm')][string]$Group,
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('GET','POST','PUT','DELETE')][string]$Method = 'GET',
        $Body,
        [hashtable]$Query,
        [int]$MaxRetries = 3
    )
    if (-not $script:HelenaToken) { throw "Token nao configurado. Rode Connect-Helena -Token 'pn_...' primeiro (ou defina `$env:HELENA_TOKEN)." }

    $uri = "$($script:HelenaBase[$Group])$Path"
    if ($Query) {
        $pairs = foreach ($k in $Query.Keys) {
            $v = $Query[$k]
            if ($v -is [array]) { foreach ($item in $v) { "$k=$([uri]::EscapeDataString([string]$item))" } }
            else { "$k=$([uri]::EscapeDataString([string]$v))" }
        }
        $uri += '?' + ($pairs -join '&')
    }

    $headers = @{ Authorization = "Bearer $($script:HelenaToken)" }
    $jsonBody = $null
    if ($Body) { $jsonBody = $Body | ConvertTo-Json -Depth 10 }

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            if ($jsonBody) {
                # PS 5.1: passar a string direta faz o Invoke-RestMethod usar a codificacao
                # padrao do sistema e destruir acentos (ola -> ol?). Enviar bytes UTF-8
                # explicitos e a unica forma confiavel de mandar texto em portugues.
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)
                return Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers -Body $bytes -ContentType 'application/json; charset=utf-8'
            } else {
                return Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers
            }
        } catch {
            $resp = $_.Exception.Response
            $status = if ($resp) { [int]$resp.StatusCode } else { 0 }
            if ($status -eq 429 -and $attempt -le $MaxRetries) {
                $wait = [math]::Pow(2, $attempt)
                Write-Warning "429 rate limit — aguardando ${wait}s (tentativa $attempt/$MaxRetries)..."
                Start-Sleep -Seconds $wait
                continue
            }
            Write-Error "Helena API erro [$Method $uri]: $($_.Exception.Message)"
            throw
        }
    }
}

# ---------------- Contatos ----------------

function New-HelenaContact {
    param(
        [string]$Name, [string]$PhoneNumber, [string]$Email,
        [string[]]$TagNames, [hashtable]$CustomFields, [hashtable]$Metadata,
        [switch]$Upsert
    )
    $body = @{}
    if ($Name) { $body.name = $Name }
    if ($PhoneNumber) { $body.phoneNumber = $PhoneNumber }
    if ($Email) { $body.email = $Email }
    if ($TagNames) { $body.tagNames = $TagNames }
    if ($CustomFields) { $body.customFields = $CustomFields }
    if ($Metadata) { $body.metadata = $Metadata }
    if ($Upsert) { $body.options = @{ upsert = $true; upsertTagOperation = 'INSERTIFNOTEXISTS' } }
    Invoke-HelenaApi -Group core -Path '/v1/contact' -Method POST -Body $body
}

function Get-HelenaContactByPhone {
    param([Parameter(Mandatory)][string]$Phone, [switch]$IncludeTags)
    $q = @{}
    if ($IncludeTags) { $q.IncludeDetails = 'Tags' }
    Invoke-HelenaApi -Group core -Path "/v1/contact/phonenumber/$Phone" -Query $q
}

function Update-HelenaContactTags {
    param(
        [Parameter(Mandatory)][string]$ContactIdOrPhone,
        [string[]]$TagNames,
        [ValidateSet('InsertIfNotExists','DeleteIfExists','ReplaceAll')][string]$Operation = 'InsertIfNotExists'
    )
    Invoke-HelenaApi -Group core -Path "/v1/contact/$ContactIdOrPhone/tags" -Method POST -Body @{ tagNames = $TagNames; operation = $Operation }
}

# ---------------- Mensagens ----------------

function Send-HelenaText {
    param(
        [Parameter(Mandatory)][string]$To, [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$Text, [string]$SessionId
    )
    $body = @{ to = $To; from = $From; text = $Text }
    if ($SessionId) { $body.sessionId = $SessionId }
    Invoke-HelenaApi -Group chat -Path '/v1/send/text' -Method POST -Body $body
}

function Send-HelenaTemplate {
    param(
        [Parameter(Mandatory)][string]$To, [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$TemplateId, [hashtable]$Parameters, [string]$FileIdOrUrl
    )
    $body = @{ to = $To; from = $From; templateId = $TemplateId }
    if ($Parameters) { $body.parameters = $Parameters }
    if ($FileIdOrUrl) { $body.fileIdOrUrl = $FileIdOrUrl }
    Invoke-HelenaApi -Group chat -Path '/v1/send/template' -Method POST -Body $body
}

function Send-HelenaSessionMessage {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [string]$Text, [string]$TemplateId, [hashtable]$Parameters, [switch]$Sync
    )
    $body = @{}
    if ($Text) { $body.text = $Text }
    if ($TemplateId) { $body.templateId = $TemplateId }
    if ($Parameters) { $body.parameters = $Parameters }
    $path = "/v1/session/$SessionId/message"
    if ($Sync) { $path += '/sync' }
    Invoke-HelenaApi -Group chat -Path $path -Method POST -Body $body
}

# ---------------- Kanban ----------------

function Get-HelenaPanels {
    param([switch]$IncludeSteps, [switch]$IncludeTags, [ValidateSet('MANAGEMENT','SALES')][string]$Type)
    $q = @{}
    $details = @()
    if ($IncludeSteps) { $details += 'Steps' }
    if ($IncludeTags) { $details += 'Tags' }
    if ($details) { $q.IncludeDetails = $details }
    if ($Type) { $q.Type = $Type }
    Invoke-HelenaApi -Group crm -Path '/v2/panel' -Query $q
}

function Get-HelenaPanelCards {
    param(
        [Parameter(Mandatory)][string]$PanelId,
        [string]$StepId, [string]$ContactId,
        [string[]]$Statuses,
        [int]$PageSize = 100
    )
    $q = @{ PanelId = $PanelId; PageSize = $PageSize }
    if ($StepId) { $q.StepId = $StepId }
    if ($ContactId) { $q.ContactId = $ContactId }
    if ($Statuses) { $q.Statuses = $Statuses }
    Invoke-HelenaApi -Group crm -Path '/v2/panel/card' -Query $q
}

function New-HelenaPanelCard {
    param(
        [Parameter(Mandatory)][string]$StepId, [Parameter(Mandatory)][string]$Title,
        [string]$SessionId, [string[]]$ContactIds, [string]$ResponsibleUserId, [string[]]$TagNames
    )
    $body = @{ stepId = $StepId; title = $Title }
    if ($SessionId) { $body.sessionId = $SessionId }
    if ($ContactIds) { $body.contactIds = $ContactIds }
    if ($ResponsibleUserId) { $body.responsibleUserId = $ResponsibleUserId }
    if ($TagNames) { $body.tagNames = $TagNames }
    Invoke-HelenaApi -Group crm -Path '/v2/panel/card' -Method POST -Body $body
}

function Move-HelenaPanelCard {
    <# O endpoint central da automacao: move um card para outra coluna (stepId). #>
    param(
        [Parameter(Mandatory)][string]$CardId,
        [Parameter(Mandatory)][string]$StepId,
        [string]$ResponsibleUserId,
        [string[]]$TagNames
    )
    $fields = @('StepId')
    $body = @{ fields = $fields; stepId = $StepId }
    if ($ResponsibleUserId) { $body.responsibleUserId = $ResponsibleUserId; $fields += 'ResponsibleUserId' }
    if ($TagNames) { $body.tagNames = $TagNames; $body.options = @{ upsertTagOperation = 'InsertIfNotExists' }; $fields += 'TagIds' }
    $body.fields = $fields
    Invoke-HelenaApi -Group crm -Path "/v3/panel/card/$CardId" -Method PUT -Body $body
}

function Set-HelenaPanelCardStatus {
    param(
        [Parameter(Mandatory)][string]$CardId,
        [Parameter(Mandatory)][ValidateSet('OPEN','WON','LOST','ARCHIVED')][string]$Status,
        [string]$LostReasonId
    )
    $body = @{ fields = @('Status'); status = $Status }
    if ($LostReasonId) { $body.lostReasonId = $LostReasonId }
    Invoke-HelenaApi -Group crm -Path "/v3/panel/card/$CardId" -Method PUT -Body $body
}

function Add-HelenaPanelCardNote {
    param([Parameter(Mandatory)][string]$CardId, [Parameter(Mandatory)][string]$Text)
    Invoke-HelenaApi -Group crm -Path "/v1/panel/card/$CardId/note" -Method POST -Body @{ text = $Text }
}

# ---------------- Webhooks ----------------

function Get-HelenaWebhookEvents {
    Invoke-HelenaApi -Group core -Path '/v1/webhook/event'
}

function New-HelenaWebhookSubscription {
    param(
        [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string[]]$Events, [bool]$Enabled = $true
    )
    Invoke-HelenaApi -Group core -Path '/v1/webhook/subscription' -Method POST -Body @{ name = $Name; url = $Url; events = $Events; enabled = $Enabled }
}

function Get-HelenaWebhookSubscriptions {
    Invoke-HelenaApi -Group core -Path '/v1/webhook/subscription'
}

# ---------------- Mensagens agendadas (follow-up por data) ----------------
# Mecanismo nativo da Helena pra disparar um template numa data/hora futura -- ideal
# para gatilhos vindos de sistemas externos (DMS/ERP) com base numa data de referencia
# (ex.: 1 ano da compra, 3 anos = vencimento de garantia). A Helena guarda e dispara
# sozinha na hora certa -- nao precisa de cron/polling do nosso lado.

function New-HelenaScheduledMessage {
    param(
        [Parameter(Mandatory)][string]$To,
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][datetime]$Scheduling,
        [ValidateSet('TEMPLATE','CHATBOT')][string]$Type = 'TEMPLATE',
        [string]$TemplateId,
        [string]$BotId,
        [hashtable]$Parameters,
        [string]$FileUrl,
        [switch]$HiddenSession
    )
    $body = @{
        to         = $To
        from       = $From
        type       = $Type
        scheduling = $Scheduling.ToString('o')
        hiddenSession = [bool]$HiddenSession
    }
    if ($TemplateId) { $body.templateId = $TemplateId }
    if ($BotId) { $body.botId = $BotId }
    if ($Parameters -or $FileUrl) {
        $body.templateParams = @{}
        if ($Parameters) { $body.templateParams.parameters = $Parameters }
        if ($FileUrl) { $body.templateParams.fileUrl = $FileUrl }
    }
    Invoke-HelenaApi -Group chat -Path '/v1/scheduled-message' -Method POST -Body $body
}

function Get-HelenaScheduledMessages {
    param(
        [string]$Status,       # SCHEDULED, PROCESSED, SENT, DELIVERED, READ, CANCELED, FAILED
        [string]$To,
        [int]$PageSize = 100
    )
    $q = @{ PageSize = $PageSize }
    if ($Status) { $q.Status = $Status }
    if ($To) { $q.To = $To }
    Invoke-HelenaApi -Group chat -Path '/v1/scheduled-message' -Query $q
}

function Cancel-HelenaScheduledMessage {
    param([Parameter(Mandatory)][string]$Id)
    Invoke-HelenaApi -Group chat -Path "/v1/scheduled-message/$Id/cancel" -Method POST
}

Write-Host "Helena.ps1 carregado. Rode 'Connect-Helena -Token ...' para comecar." -ForegroundColor Cyan
