# ag808 — Avaliador Portaria 808

Agente do GitHub Copilot CLI que faz uma avaliação técnica preliminar da regularidade fiscal de municípios e da aderência às duas trilhas da Portaria Normativa MF nº 808/2023:

1. Contrapartida de 0,5% (soluções inovadoras, consórcios, capacitação, PPPs/concessões)
2. Operação de crédito com garantia da União

Usa as APIs oficiais do Siconfi e do IBGE e classifica cada critério como `REGULAR`, `ATENÇÃO`, `IMPEDITIVO` ou `SEM DADO`.

## Instalação

```bash
copilot plugin install hubrecife/ag808
```

Ou, só para você, copie o agente:

```bash
cp agents/avaliador-portaria-808.agent.md ~/.copilot/agents/
```

## Uso

```bash
copilot --agent avaliador-portaria-808
```

Ou, dentro do Copilot CLI, digite `/agent` e escolha **avaliador-portaria-808**. Exemplo de pedido:

> Avalie o município de Recife/PE, código IBGE 2611606.

O agente precisa de acesso ao shell e à rede para consultar as APIs. Aprove as chamadas quando o CLI pedir.

> Avaliação técnica preliminar baseada em dados públicos; não substitui o parecer da STN, da instituição financeira ou da assessoria jurídica.
