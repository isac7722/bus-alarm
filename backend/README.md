# BusWidget backend

FastAPI backend for the BusWidget app. 전체 실행과 환경 설정은 상위 [README](../README.md)를 참고하세요.

로컬 Python 개발은 PostgreSQL과 Redis를 실행한 뒤 다음 명령으로 시작할 수 있습니다.

```bash
cp .env.example .env
uv sync
uv run alembic upgrade head
uv run python -m app.commands.import_stations
uv run uvicorn app.main:app --reload
```

기본 `STATION_CATALOG_PATH`는 backend 디렉터리에서 상위의 `seoul_bus_statiosn.xlsx`를 가리킵니다. import는 전체 카탈로그를 검증한 다음 한 트랜잭션에서 교체하므로 실패 시 기존 데이터를 보존합니다.
