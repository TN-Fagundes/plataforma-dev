# plataforma-dev

Ferramentas de desenvolvimento compartilhadas entre projetos: **Gitea** (git + CI),
**SonarQube** (qualidade) e **Grafana/Loki/Promtail** (logs). Uso exclusivo em intranet.

> **Status (2026-09-28):** **SonarQube, Gitea e observabilidade de dev migrados** e rodando
> daqui. A **observabilidade de produção** (instância separada, no servidor de prod) está
> versionada aqui e aguarda o deploy no servidor. Detalhes no topo do
> [plano](docs/plano-migracao.md).

| Ferramenta | Pasta | Projeto Compose | URL |
|---|---|---|---|
| SonarQube | [sonarqube/](sonarqube/) | `plataforma-sonar` | http://localhost:9000 |
| Gitea | [gitea/](gitea/) | `plataforma-gitea` | http://localhost:3001 |
| Loki + Promtail + Grafana (dev) | [observabilidade/](observabilidade/) | `plataforma-obs` | http://localhost:3002 |
| Loki + Promtail + Grafana (**prod**) | [observabilidade/PRODUCAO.md](observabilidade/PRODUCAO.md) | `plataforma-obs-prod` | http://<servidor-prod>:3001 |
| Runner do CI (nativo, WSL) | [runner/](runner/) | — | — |

## Uso

```bash
make help        # alvos
make network     # cria a rede externa `devtools` (uma vez por host)
make sonar-up    # ou gitea-up, obs-up, up (todas)
make backup-sonar backup-gitea   # dumps em backups/ (fora do git)
```

Dashboards e alertas de um projeto vão para o Grafana pela API, com
[observabilidade/grafana-sync.sh](observabilidade/grafana-sync.sh) (o projeto chama via `make grafana-sync`):

```bash
GRAFANA_TOKEN=<token> sh observabilidade/grafana-sync.sh <dir-provisioning> <uid-pasta> "<Título>"
```

O `.env` é criado do `.env.example` na primeira subida.

## Documentação

- [docs/plano-migracao.md](docs/plano-migracao.md): diagnóstico, arquitetura-alvo, fases de
  migração, validação, rollback e onboarding de novos projetos.
- [rede.md](rede.md): rede `devtools` e mapa de portas.
- [sonarqube/runbook.md](sonarqube/runbook.md): kernel, backup/restore, profiles, tokens.
- [runner/README.md](runner/README.md): instalação e registro do `act_runner`.
