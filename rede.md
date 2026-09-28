# Rede e portas

## Rede `devtools`

Rede Docker externa, com nome fixo, criada uma vez por host (`make network`). Todos os composes
da plataforma entram nela, e cada projeto consumidor a declara como externa:

```yaml
networks:
  devtools:
    external: true
    name: devtools
```

Os serviços se encontram pelo nome, sem depender do `COMPOSE_PROJECT_NAME` de ninguém:

| Nome na rede | Uso |
|---|---|
| `sonarqube:9000` | scanner dos projetos → servidor Sonar |
| `loki:3100` | Promtail → Loki; Grafana → Loki |
| `gitea:3000` | acesso interno ao Gitea (o CI usa a URL do host, ver runner/README.md) |

O `sonar-db` fica **fora** da `devtools`: só o `sonarqube` fala com ele.

> A rede só vale no **mesmo host**. Quando a plataforma for para um servidor (etapa b do plano),
> os consumidores passam a usar URL/IP e a rede deixa de ser necessária para eles.

## Portas no host

A plataforma é **dona** destas portas, e nenhum projeto deve publicá-las:

| Serviço | Porta | Observação |
|---|---|---|
| Gitea HTTP | 3001 | runner e remotes apontam para `localhost:3001` |
| Gitea SSH | 2222 | |
| SonarQube | 9000 | SonarLint (Connected Mode) aponta para cá |
| Grafana | 3002 | |
| Loki | não publicada | só pela rede `devtools` |

A 3000 fica livre para os projetos (o `auditoria-2.0` põe o Gotenberg nela).
