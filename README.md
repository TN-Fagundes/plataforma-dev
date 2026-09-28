# plataforma-dev

Ferramentas de desenvolvimento compartilhadas entre projetos: **Gitea** (git + CI),
**SonarQube** (qualidade) e **Grafana/Loki/Promtail** (logs). Uso exclusivo em intranet.

> **Status (2026-09-28):** Fase 0 do plano. Composes, Makefile e runbooks prontos e validados
> (`docker compose config`); rede `devtools` criada; backups feitos. **Nenhuma ferramenta
> migrada ainda**: todas continuam rodando a partir do repositório `auditoria-2.0`.

| Ferramenta | Pasta | Projeto Compose | URL |
|---|---|---|---|
| SonarQube | [sonarqube/](sonarqube/) | `plataforma-sonar` | http://localhost:9000 |
| Gitea | [gitea/](gitea/) | `plataforma-gitea` | http://localhost:3001 |
| Loki + Promtail + Grafana (dev) | [observabilidade/](observabilidade/) | `plataforma-obs` | http://localhost:3002 |
| Runner do CI (nativo, WSL) | [runner/](runner/) | — | — |

## Uso

```bash
make help        # alvos
make network     # cria a rede externa `devtools` (uma vez por host)
make sonar-up    # ou gitea-up, obs-up, up (todas)
make backup-sonar backup-gitea   # dumps em backups/ (fora do git)
```

O `.env` é criado do `.env.example` na primeira subida.

## Documentação

- [docs/plano-migracao.md](docs/plano-migracao.md): diagnóstico, arquitetura-alvo, fases de
  migração, validação, rollback e onboarding de novos projetos.
- [rede.md](rede.md): rede `devtools` e mapa de portas.
- [sonarqube/runbook.md](sonarqube/runbook.md): kernel, backup/restore, profiles, tokens.
- [runner/README.md](runner/README.md): instalação e registro do `act_runner`.
