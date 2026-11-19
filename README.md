# ag808 — Avaliador Portaria 808

Agente do GitHub Copilot CLI que faz uma avaliação técnica preliminar da regularidade fiscal de municípios e da aderência às duas trilhas da Portaria Normativa MF nº 808/2023:

1. Contrapartida de 0,5% (soluções inovadoras, consórcios, capacitação, PPPs/concessões)
2. Operação de crédito com garantia da União

Os dados vêm de um script de coleta (`scripts/coleta.ps1`) que consulta as fontes oficiais e já calcula os indicadores. O agente interpreta o resultado e redige o parecer; ele não lê JSON bruto nem estima números.

## O que é coletado automaticamente

| Fonte | Dados |
|---|---|
| Siconfi — RREO Anexo 14 | RCL, saúde (ASPS), educação (MDE), FUNDEB 70%, resultado primário, regra de ouro, despesas com PPP, restos a pagar |
| Siconfi — RGF Anexos 01 a 04 | pessoal do Executivo e do Legislativo, DCL, garantias, operações de crédito |
| Siconfi — extrato de entregas | situação de RREO, RGF, DCA e MSC por órgão |
| Tesouro Transparente | CAPAG oficial mais recente (nota final e notas parciais) |
| IBGE | validação do código do município |

Inclui o período mais recente e uma série histórica de 3 exercícios fechados. Cada indicador sai com valor, limite legal, status sugerido e a URL exata da consulta.

**Não coletado** (o agente lista como pendência ou usa documentos que você fornecer): CAUC, SADIPEM/PVL, CNDT, CRF-FGTS, TCU/CGU (CEIS, CNEP, CEPIM), plano anual da Portaria 808 e legislação local.

## Instalação

```bash
copilot plugin install hubrecife/ag808
```

Para atualizar uma instalação anterior, desinstale e instale de novo (`copilot plugin uninstall ag808`).

Requisitos: Windows PowerShell 5.1 (já vem no Windows) ou PowerShell 7 (`pwsh`) no Linux/macOS.

## Uso

Modo interativo (recomendado: você aprova os comandos):

```bash
copilot --agent ag808:avaliador-portaria-808 -i "Avalie Feira de Santana/BA, código IBGE 2910800"
```

Ou dentro do Copilot CLI: `/agent` → **ag808:avaliador-portaria-808**.

Modo não interativo (`-p`): o Copilot não pode pedir aprovação, então libere o shell explicitamente:

```bash
copilot --agent ag808:avaliador-portaria-808 -p "Avalie Feira de Santana/BA, código IBGE 2910800" --allow-tool='shell(powershell:*)' --allow-tool='shell(Get-ChildItem:*)'
```

No Linux/macOS troque `powershell` por `pwsh` e `Get-ChildItem` por `find`.

## Rodar só a coleta

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/coleta.ps1 -Ibge 2910800 -Saida feira.json
```

Parâmetros: `-Exercicio <ano>`, `-Anos <n>` (série histórica, padrão 3), `-SemCapag`, `-Saida <arquivo>`.

## Testes

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/verifica.ps1
```

Compara o resultado do script com valores conferidos manualmente no Siconfi e na planilha CAPAG.

> Avaliação técnica preliminar baseada em dados públicos; não substitui o parecer da STN, da instituição financeira ou da assessoria jurídica.
