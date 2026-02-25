from fastapi import FastAPI, Request

app = FastAPI()


def _extract_client_ip(request: Request) -> str:
    forwarded_for = request.headers.get("x-forwarded-for")
    if forwarded_for:
        return forwarded_for.split(",")[0].strip()
    if request.client:
        return request.client.host
    return "unknown"


@app.get("/ip")
def get_ip(request: Request):
    return {"ip": _extract_client_ip(request)}


@app.get("/")
def root(request: Request):
    return {"message": "ok", "ip": _extract_client_ip(request)}
