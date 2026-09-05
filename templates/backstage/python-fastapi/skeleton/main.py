from fastapi import FastAPI

app = FastAPI(
    title="${{ values.component_id }}",
    description=${{ values.description | dump }}
)

@app.get("/")
def read_root():
    return {
        "status": "healthy",
        "service": "${{ values.component_id }}",
        "owner": "${{ values.owner }}",
        "framework": "FastAPI"
    }

@app.get("/healthz")
def health_check():
    return {"status": "ok"}
