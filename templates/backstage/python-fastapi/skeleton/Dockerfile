FROM python:3.13-alpine@sha256:7415fbc3c9e4979cc717d92377ab2bc7b2b4a2af1ac03cc52b5f3f88efedaf3a AS base
# Pin the available util-linux security patch instead of allowing a floating upgrade.
RUN apk add --no-cache libuuid=2.42.3-r0

FROM base AS dependencies
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir --require-hashes --only-binary=:all: --target=/dependencies -r requirements.txt

FROM base
# Only stdlib plus the locked application dependencies belong in the runtime.
RUN rm -rf /usr/local/lib/python3.13/site-packages/* /usr/local/lib/python3.13/ensurepip /usr/local/bin/pip*
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PYTHONPATH=/dependencies
WORKDIR /app
COPY --from=dependencies /dependencies /dependencies
COPY main.py ./
USER 1000:1000
EXPOSE 8000
CMD ["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
