# plataforma-dev: operação das ferramentas compartilhadas. `make help` lista os alvos.

.PHONY: help network up down ps \
        sonar-up sonar-down gitea-up gitea-down obs-up obs-down \
        backup-sonar backup-gitea copiar-volume obs-prod-check obs-prod-copy

SONAR = docker compose -f sonarqube/docker-compose.yml --env-file .env
GITEA = docker compose -f gitea/docker-compose.yml --env-file .env
OBS   = docker compose -f observabilidade/docker-compose.yml --env-file .env

# Containers de origem dos backups. Default: os da plataforma. Durante a migração,
# aponte para os antigos, ex.: make backup-sonar SONAR_DB_CTR=auditoria-2-0-sonar-sonar-db-1
SONAR_DB_CTR ?= plataforma-sonar-sonar-db-1
GITEA_CTR    ?= plataforma-gitea-gitea-1
HOJE := $(shell date +%F)

help:
	@echo "Rede:            network (cria a rede externa devtools; idempotente)"
	@echo "Tudo:            up | down | ps"
	@echo "SonarQube:       sonar-up | sonar-down        http://localhost:9000"
	@echo "Gitea:           gitea-up | gitea-down        http://localhost:3001"
	@echo "Observabilidade: obs-up | obs-down            http://localhost:3002"
	@echo "Backup:          backup-sonar | backup-gitea  (saida em backups/)"
	@echo "Migracao:        copiar-volume DE=<volume> PARA=<volume>"
	@echo "Obs. de prod:    obs-prod-check | obs-prod-copy   (PROD_* no .env; ver observabilidade/PRODUCAO.md)"

.env:
	cp .env.example .env

network:
	@docker network inspect devtools >/dev/null 2>&1 || docker network create devtools

up: sonar-up gitea-up obs-up
down: sonar-down gitea-down obs-down
ps:
	@docker ps --filter label=com.docker.compose.project=plataforma-sonar \
	           --filter label=com.docker.compose.project=plataforma-gitea \
	           --filter label=com.docker.compose.project=plataforma-obs \
	           --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

sonar-up: network .env
	$(SONAR) up -d
	@echo "Aguarde ficar UP: curl -s localhost:9000/api/system/status"
sonar-down:
	$(SONAR) down

gitea-up: network .env
	$(GITEA) up -d
gitea-down:
	$(GITEA) down

obs-up: network .env
	$(OBS) up -d
obs-down:
	$(OBS) down

# Nunca use `down -v` sem um destes backups: os volumes guardam o que não está no git.
backup-sonar:
	@mkdir -p backups
	docker exec $(SONAR_DB_CTR) pg_dump -U sonar sonar | gzip > backups/sonar-db-$(HOJE).sql.gz
	@ls -l backups/sonar-db-$(HOJE).sql.gz

backup-gitea:
	@mkdir -p backups
	docker exec -u git -w /tmp $(GITEA_CTR) sh -c 'rm -f /tmp/gitea-dump.zip && gitea dump -c /data/gitea/conf/app.ini -f /tmp/gitea-dump.zip'
	docker cp $(GITEA_CTR):/tmp/gitea-dump.zip backups/gitea-dump-$(HOJE).zip
	docker exec $(GITEA_CTR) rm -f /tmp/gitea-dump.zip
	@ls -l backups/gitea-dump-$(HOJE).zip

# Copia um volume inteiro preservando dono/permissões. Rode com a stack de ORIGEM
# parada. O volume de origem não é alterado (montado read-only) e serve de rollback.
copiar-volume:
	@test -n "$(DE)" -a -n "$(PARA)" || (echo "uso: make copiar-volume DE=<volume> PARA=<volume>"; exit 1)
	@docker volume inspect $(DE) >/dev/null
	@! docker volume inspect $(PARA) >/dev/null 2>&1 || (echo "$(PARA) ja existe: remova-o antes (docker volume rm) ou escolha outro nome"; exit 1)
	docker volume create $(PARA)
	docker run --rm -v $(DE):/de:ro -v $(PARA):/para alpine sh -c 'cp -a /de/. /para/'

# Observabilidade de PRODUÇÃO: os alvos rodam aqui e agem no servidor por ssh/scp.
# Host e caminhos vêm do .env (PROD_*), nunca do git. Só leem e copiam: subir e
# derrubar containers no servidor continua manual (observabilidade/PRODUCAO.md).
PROD_ENV = eval "$$(grep -E '^PROD_(SSH|OBS_DIR|APP_DIR)=' .env | tr -d '\r' | sed 's/^/export /')" && \
	{ test -n "$$PROD_SSH" -a -n "$$PROD_OBS_DIR" -a -n "$$PROD_APP_DIR" || \
	  { echo "defina PROD_SSH, PROD_OBS_DIR e PROD_APP_DIR no .env (ver .env.example)"; exit 1; }; }

# Só leitura: o que roda no servidor e o que existe nos caminhos configurados.
obs-prod-check: .env
	@$(PROD_ENV) && ssh "$$PROD_SSH" "\
	  echo '== projetos compose'; docker compose ls; \
	  echo '== containers'; docker ps --format '{{.Names}}\t{{.Image}}\t{{.Ports}}'; \
	  echo '== volumes'; docker volume ls --format '{{.Name}}' | grep -E 'storage|obs'; \
	  echo \"== $$PROD_APP_DIR\"; ls -la '$$PROD_APP_DIR'; \
	  echo \"== $$PROD_OBS_DIR\"; ls -la '$$PROD_OBS_DIR' 2>/dev/null || echo '(nao existe)'"

# O chmod a+rX vem ANTES do 600 do .env.prod: o Grafana (uid 472) precisa atravessar
# os diretórios montados, e o .env.prod só é lido pelo docker compose. O `cp -n` não
# sobrescreve um .env.prod já preenchido, então o alvo pode ser rodado de novo.
obs-prod-copy: .env
	@$(PROD_ENV) && set -x && \
	ssh "$$PROD_SSH" "mkdir -p '$$PROD_OBS_DIR'" && \
	scp -r observabilidade/docker-compose.prod.yml observabilidade/.env.prod.example \
	       observabilidade/loki observabilidade/promtail observabilidade/grafana \
	       "$$PROD_SSH:$$PROD_OBS_DIR/" && \
	scp observabilidade/Makefile.prod "$$PROD_SSH:$$PROD_OBS_DIR/Makefile" && \
	ssh "$$PROD_SSH" "cd '$$PROD_OBS_DIR' && cp -n .env.prod.example .env.prod; \
	  chmod -R a+rX . && chmod 600 .env.prod && find . -exec ls -ld {} +"
