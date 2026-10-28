# Kanban de vendas que se move sozinho com o WhatsApp

Automação em PowerShell que mantém o funil de vendas (kanban do CRM) atualizado sem trabalho
manual: cada mensagem do cliente, resposta do vendedor ou etiqueta aplicada no WhatsApp move o
card do lead para a coluna certa.

Funciona com a Helena, plataforma de atendimento e CRM multicanal, recebendo os webhooks dela e
chamando sua API REST. Foi desenvolvido durante meu estágio, como base para as automações de
kanban de clientes. Esta é uma versão de portfólio, sem dados de empresas ou clientes.

## O problema

Vendedores raramente atualizam o kanban à mão. O resultado é um funil desatualizado: o gestor não
sabe quais leads estão parados, quais esperam resposta do cliente e quais já foram perdidos.

## Como funciona

| Evento no WhatsApp / CRM | Webhook da Helena | Ação no kanban |
| --- | --- | --- |
| Cliente mandou mensagem | `MESSAGE_RECEIVED` | Card vai para **Em atendimento** |
| Vendedor respondeu (mensagens de bot são ignoradas) | `MESSAGE_SENT` | Card vai para **Aguardando cliente** |
| Etiqueta "Proposta enviada" aplicada | `CONTACT_TAG_UPDATE` | Card vai para **Aguardando cliente** |
| Etiqueta "Sem interesse" aplicada | `CONTACT_TAG_UPDATE` | Card é marcado como **perdido** |

```
WhatsApp ──► Helena ──webhook──► automacao-kanban.ps1 (servidor HTTP)
                                      │
                                      ├─ identifica o evento
                                      ├─ acha o card aberto do contato no painel
                                      └─ move o card / marca como perdido (API da Helena)
```

O mapeamento de etiquetas para colunas fica no `config.json`, então dá para adaptar a qualquer
funil sem mexer no código.

## Estrutura

```
automacao-kanban.ps1     servidor HTTP que recebe os webhooks e aplica as regras
lib/Helena.ps1           módulo com funções para a API da Helena (contatos, mensagens,
                         templates, kanban, webhooks, mensagens agendadas), com retentativas
config.example.json      modelo de configuração do funil (painel, etapas, etiquetas)
exemplos/testar-local.ps1 simula os webhooks para testar sem WhatsApp
```

O módulo `lib/Helena.ps1` também pode ser usado sozinho, no terminal:

```powershell
. .\lib\Helena.ps1
Connect-Helena -Token 'pn_xxxxxxxxxxxx'
Get-HelenaPanels -IncludeSteps | ConvertTo-Json -Depth 5
Move-HelenaPanelCard -CardId '<id>' -StepId '<id-da-coluna>'
```

## Como rodar

1. Copie a configuração e preencha com os IDs do seu painel:

   ```powershell
   copy config.example.json config.json
   ```

   Para descobrir os IDs: `Get-HelenaPanels -IncludeSteps -Type SALES | ConvertTo-Json -Depth 5`.

2. Suba o dispatcher:

   ```powershell
   $env:HELENA_TOKEN = 'pn_xxxxxxxxxxxx'
   powershell -File automacao-kanban.ps1
   ```

3. Exponha a porta e registre o webhook na Helena:

   ```powershell
   ngrok http 8091
   New-HelenaWebhookSubscription -Url 'https://xxxx.ngrok-free.app/' -Events @('MESSAGE_RECEIVED','MESSAGE_SENT','CONTACT_TAG_UPDATE')
   ```

4. Para testar sem WhatsApp, simule os eventos:

   ```powershell
   powershell -File exemplos\testar-local.ps1 -ContactId '<id-de-um-contato-com-card-aberto>'
   ```

## Tecnologias

PowerShell 5.1 · API REST e webhooks da Helena · `System.Net.HttpListener` · ngrok

## Autor

João Victor Lopez de Arruda · [GitHub](https://github.com/JoaoVictor-tech) · [LinkedIn](https://linkedin.com/in/joao-victor-arruda)
