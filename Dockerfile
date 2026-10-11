FROM python:3.14.3-slim
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

ARG GIT_SHORT_HASH="unknown"
ARG GIT_TAG=""

LABEL maintainer="Panda Team" \
      org.opencontainers.image.revision="${GIT_SHORT_HASH}" \
      org.opencontainers.image.version="${GIT_TAG}"

RUN useradd --create-home --shell /bin/bash appuser
RUN mkdir /app && chown appuser:appuser /app

WORKDIR /app

ENV TZ=Europe/Kyiv \
    GIT_SHORT_HASH="${GIT_SHORT_HASH}" \
    GIT_TAG="${GIT_TAG}" \
    PYTHONUNBUFFERED=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    PATH="/app/.venv/bin:$PATH"

COPY --chown=appuser:appuser pyproject.toml uv.lock ./
USER appuser
RUN uv sync --frozen --no-dev
COPY --chown=appuser:appuser . .

EXPOSE 8080

CMD ["uvicorn", "main:app","--host","0.0.0.0", "--port", "8080"]
