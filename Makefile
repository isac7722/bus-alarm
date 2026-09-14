SHELL := /bin/bash

.DEFAULT_GOAL := help

COMPOSE := docker compose
HEALTH_URL ?= http://127.0.0.1:8000/health
HEALTH_ATTEMPTS ?= 30
IOS_DIR := ios
XCODE_PROJECT := $(IOS_DIR)/BusWidget.xcodeproj
SIMULATOR ?= iPhone 17 Pro

.PHONY: help dev server xcode stop restart logs status test test-backend test-backend-unit test-backend-integration test-ios wait-server check-docker check-xcode

help: ## 사용 가능한 Make 명령을 표시합니다.
	@echo "BusWidget 개발 명령"
	@echo
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / {printf "  %-12s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo
	@echo "예시: make dev, make logs, make test SIMULATOR=\"iPhone 17 Pro\""

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

restart: check-docker ## backend를 다시 빌드하고 재생성한 뒤 준비 상태를 확인합니다.
	$(COMPOSE) up --build -d --force-recreate backend
	@$(MAKE) --no-print-directory wait-server

logs: check-docker ## backend 로그를 실시간으로 표시합니다. 종료는 Ctrl+C입니다.
	$(COMPOSE) logs -f backend

status: check-docker ## Docker 컨테이너 상태를 표시합니다.
	$(COMPOSE) ps

test: ## 백엔드 검사와 iOS 테스트를 모두 실행합니다.
	@$(MAKE) --no-print-directory test-backend
	@$(MAKE) --no-print-directory test-ios

test-backend: check-docker ## Go 검사와 격리된 PostgreSQL·Redis 통합 테스트를 실행합니다.
	@cd backend && test -z "$$(gofmt -l cmd internal app/content/content.go)" || { echo "gofmt 검사가 실패했습니다."; exit 1; }
	@cd backend && go vet ./...
	@bash backend/scripts/test-integration.sh

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
	@docker info >/dev/null 2>&1 || { echo "오류: Docker Desktop을 실행해 주세요."; exit 1; }

check-xcode:
	@command -v xcodegen >/dev/null 2>&1 || { echo "오류: 'brew install xcodegen'으로 XcodeGen을 설치해 주세요."; exit 1; }
	@command -v xcodebuild >/dev/null 2>&1 || { echo "오류: Xcode Command Line Tools를 설정해 주세요."; exit 1; }
