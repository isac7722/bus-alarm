SHELL := /bin/bash

.DEFAULT_GOAL := help

APNS ?= 0
COMPOSE := docker compose $(if $(filter 1,$(APNS)),-f docker-compose.yml -f docker-compose.apns.yml)
HEALTH_URL ?= http://127.0.0.1:8000/health
HEALTH_ATTEMPTS ?= 30
IOS_DIR := ios
XCODE_PROJECT := $(IOS_DIR)/BusWidget.xcodeproj
SIMULATOR ?= iPhone 17 Pro
UV ?= uv
# Optional station import inputs. An explicit ENV_FILE selects direct DB access.
CSV ?=
ENV_FILE ?=
DB_ENV ?=
CONTAINER ?=
STATION_DB_ENV = $(if $(DB_ENV),$(DB_ENV),$(if $(ENV_FILE),DATABASE_URL))
STATION_COMMAND = $(UV) run $(if $(ENV_FILE),--env-file "$(ENV_FILE)") python backend/scripts/update_seoul_stations.py $(if $(CSV),--csv "$(CSV)") $(if $(STATION_DB_ENV),--database-url-env "$(STATION_DB_ENV)") $(if $(CONTAINER),--container "$(CONTAINER)")

.PHONY: help setup stations-check stations-preview stations-update test-stations dev server xcode stop restart logs status test test-backend test-backend-unit test-backend-integration test-ios wait-server check-docker check-xcode testflight testflight-check testflight-status testflight-script-test

help: ## 사용 가능한 Make 명령을 표시합니다.
	@echo "BusWidget 개발 명령"
	@echo
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / {printf "  %-12s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo
	@echo "예시: make dev, make logs, make test SIMULATOR=\"iPhone 17 Pro\""

setup: ## uv sync로 정류장 관리 도구의 Python·패키지를 설치합니다.
	$(UV) sync --locked

stations-check: ## DB 접속 없이 정류장 CSV를 검증합니다. CSV=경로 지정 가능.
	$(STATION_COMMAND) --validate-only

stations-preview: ## 정류장 추가·수정 예정 건수를 확인합니다. ENV_FILE=경로로 직접 DB 연결.
	$(STATION_COMMAND)

stations-update: ## 서울·경기도 경유 정류장 추가·수정을 DB에 적용합니다.
	$(STATION_COMMAND) --apply

test-stations: ## 정류장 관리 스크립트의 lint·포맷·테스트를 실행합니다.
	$(UV) run ruff check backend/scripts
	$(UV) run ruff format --check backend/scripts
	$(UV) run python -m unittest discover -s backend/scripts/tests -v

dev: ## 서버가 준비되면 Xcode 프로젝트를 생성하고 엽니다.
	@$(MAKE) --no-print-directory server
	@$(MAKE) --no-print-directory xcode

server: check-docker ## Docker 서버를 빌드하고 백그라운드로 실행합니다.
	$(COMPOSE) up --build -d
	@$(MAKE) --no-print-directory wait-server

xcode: check-xcode ## Xcode 프로젝트를 생성하고 Xcode에서 엽니다.
	@cd $(IOS_DIR) && xcodegen generate
	@open $(XCODE_PROJECT)
	@echo "Xcode 프로젝트를 열었습니다: $(XCODE_PROJECT)"

stop: check-docker ## Docker 서버와 관련 컨테이너를 종료합니다.
	$(COMPOSE) down

restart: check-docker ## 기존 DB를 유지하고 backend만 재빌드합니다. 실시간 현황 사용 시 APNS=1.
	$(COMPOSE) up --build -d --no-deps --force-recreate backend
	@$(MAKE) --no-print-directory wait-server

logs: check-docker ## backend 로그를 실시간으로 표시합니다. 종료는 Ctrl+C입니다.
	$(COMPOSE) logs -f backend

status: check-docker ## Docker 컨테이너 상태를 표시합니다.
	$(COMPOSE) ps

test: ## 백엔드 검사와 iOS 테스트를 모두 실행합니다.
	@$(MAKE) --no-print-directory test-backend
	@$(MAKE) --no-print-directory test-ios

test-backend: check-docker ## Docker 안에서 Go 검사와 DB·Redis 통합 테스트를 실행합니다. 호스트 Go 불필요.
	@bash backend/scripts/test-integration.sh --checks

test-backend-unit: ## Docker 없이 Go 단위·호환성 테스트를 실행합니다.
	@cd backend && go test -race ./...

test-backend-integration: check-docker ## 임시 DB·Redis에서 Go 전체 테스트를 실행합니다.
	@bash backend/scripts/test-integration.sh

test-ios: check-xcode
	@echo "iOS 프로젝트 생성 및 테스트: $(SIMULATOR)"
	@cd $(IOS_DIR) && xcodegen generate
	@xcodebuild -project $(XCODE_PROJECT) -scheme BusWidget \
		-destination 'platform=iOS Simulator,name=$(SIMULATOR)' \
		CODE_SIGNING_ALLOWED=NO test

wait-server:
	@command -v curl >/dev/null 2>&1 || { echo "오류: curl이 필요합니다."; exit 1; }
	@echo "서버 준비 확인 중: $(HEALTH_URL)"
	@attempt=1; \
	while [ $$attempt -le $(HEALTH_ATTEMPTS) ]; do \
		if curl --fail --silent --show-error "$(HEALTH_URL)" >/dev/null 2>&1; then \
			echo "서버가 준비되었습니다: $(HEALTH_URL)"; \
			exit 0; \
		fi; \
		attempt=$$((attempt + 1)); \
		sleep 1; \
	done; \
	echo "오류: $(HEALTH_ATTEMPTS)초 안에 서버가 준비되지 않았습니다."; \
	$(COMPOSE) logs --tail=30 backend; \
	exit 1

check-docker:
	@command -v docker >/dev/null 2>&1 || { echo "오류: Docker를 설치해 주세요."; exit 1; }
	@docker info >/dev/null 2>&1 || { echo "오류: Docker 데몬을 실행해 주세요."; exit 1; }

check-xcode:
	@command -v xcodegen >/dev/null 2>&1 || { echo "오류: 'brew install xcodegen'으로 XcodeGen을 설치해 주세요."; exit 1; }
	@command -v xcodebuild >/dev/null 2>&1 || { echo "오류: Xcode Command Line Tools를 설정해 주세요."; exit 1; }


testflight: ## iOS 테스트 후 버전을 증가시켜 TestFlight에 업로드하고 처리 완료를 확인합니다.
	@python3 ios/scripts/testflight.py release --simulator "$(SIMULATOR)"

testflight-check: ## API 키 설정과 App Store Connect 앱 접근을 확인합니다. 업로드하지 않습니다.
	@python3 ios/scripts/testflight.py check

testflight-status: ## 마지막 업로드의 Apple 처리 상태를 확인합니다. 재업로드하지 않습니다.
	@python3 ios/scripts/testflight.py status

testflight-script-test: ## TestFlight 자동화의 오프라인 테스트를 실행합니다.
	@python3 -m unittest discover -s ios/scripts/tests -v
