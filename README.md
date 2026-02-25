# GitOps Practice

## 1. 목표
- FastAPI 기반 API 서버(`dummy_server.py`)를 구현한다.
- Docker 이미지로 빌드한다.
- GitHub Container Registry(GHCR)에 수동 워크플로우로 배포한다.
- 로컬 Kubernetes 환경(kind)과 ArgoCD를 설치한다.

## 2. 사전 준비
- Linux 환경(WSL2 포함)
- `docker` 설치 확인
- GitHub 저장소 권한(패키지 작성/읽기 권한)

### 2.1 GitHub 환경
- Repository: 현재 작업 디렉터리 `README.MD` 기준의 동일 저장소
- Secrets는 별도 추가 없이 `GITHUB_TOKEN`만 사용

## 3. API 서버 구현
프로젝트 루트에 아래 파일을 생성한다.

`dummy_server.py`
```python
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
```

### 3.1 동작 요약
- `GET /ip` 호출 시 클라이언트 IP 반환
- `x-forwarded-for` 헤더가 있으면 그 값을 우선 사용
- 없으면 `request.client.host` 사용

## 4. 컨테이너 이미지 정의
프로젝트 루트에 `Dockerfile`을 생성한다.

```dockerfile
FROM python:3.12-slim

WORKDIR /app

COPY dummy_server.py .

RUN pip install --no-cache-dir "fastapi" "uvicorn[standard]"

EXPOSE 8000

CMD ["uvicorn", "dummy_server:app", "--host", "0.0.0.0", "--port", "8000"]
```

## 5. GitHub Actions 워크플로우(수동 실행, GHCR Push)
`build-and-push-ghcr.yml` 작성 위치:
`.github/workflows/build-and-push-ghcr.yml`

```yaml
name: Build and Push dummy_server to GHCR

on:
  workflow_dispatch:

permissions:
  contents: read
  packages: write

jobs:
  build-and-push:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Prepare image metadata
        id: meta
        run: |
          OWNER="${{ github.repository_owner }}"
          REPO="${{ github.event.repository.name }}"
          OWNER_LOWER="$(echo "$OWNER" | tr '[:upper:]' '[:lower:]')"
          REPO_LOWER="$(echo "$REPO" | tr '[:upper:]' '[:lower:]')"
          IMAGE_TAG="$(date +'%Y%m%d-%H%M%S')"
          echo "IMAGE_NAME=ghcr.io/${OWNER_LOWER}/${REPO_LOWER}" >> "$GITHUB_OUTPUT"
          echo "IMAGE_TAG=${IMAGE_TAG}" >> "$GITHUB_OUTPUT"

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to GitHub Container Registry
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push image
        uses: docker/build-push-action@v6
        with:
          context: .
          file: ./Dockerfile
          push: true
          tags: |
            ${{ steps.meta.outputs.IMAGE_NAME }}:${{ steps.meta.outputs.IMAGE_TAG }}
            ${{ steps.meta.outputs.IMAGE_NAME }}:sha-${{ github.sha }}
```

### 5.1 실행 방식
- GitHub → Actions → `Build and Push dummy_server to GHCR` → `Run workflow`
- 태그는 자동으로 `YYYYMMDD-hhmmss` 형식 생성됨

### 5.2 업로드 이미지 확인
- GitHub 저장소 페이지에서 `Packages` 확인
- 로컬 확인 예시
```bash
docker login ghcr.io
docker pull ghcr.io/<OWNER>/<REPO>:<TAG>
docker images | grep <REPO>
```
- 태그 목록 조회 예시
```bash
gh api /repos/<OWNER>/<REPO>/packages/container/<REPO>/versions --paginate
```

## 6. 로컬 Kubernetes 환경(kind) 구축
### 6.1 kind 설치
```bash
curl -Lo kind https://kind.sigs.k8s.io/dl/v0.27.0/kind-linux-amd64
chmod +x kind
sudo mv kind /usr/local/bin/kind
kind version
```

### 6.2 kubectl 설치
```bash
curl -LO "https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --client
```

### 6.3 클러스터 생성
```bash
kind create cluster --name gitops-practice
kubectl cluster-info
kubectl get nodes
```

## 7. ArgoCD 설치
### 7.1 설치 명령
```bash
kubectl create namespace argocd
kubectl apply --server-side --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

### 7.2 상태 확인
```bash
kubectl get pods -n argocd
kubectl get svc -n argocd
```
모든 Pod가 `Running`이면 설치 완료.

### 7.3 UI 접속
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```
- 브라우저: `https://localhost:8080`
- 아이디: `admin`
- 초기 비밀번호 조회:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```

## 8. 이번 실습에서 확인한 포인트
- `kubectl apply`와 `server-side apply` 혼용 시 CRD 애노테이션 크기 이슈가 발생할 수 있다.
- `applicationsets.argoproj.io`의 `metadata.annotations` 오류가 반복될 때는 `--server-side --force-conflicts` 사용을 우선 적용했다.
- 네임스페이스를 누락하면 ArgoCD 리소스가 `default`에 생성될 수 있어, 설치 전/후 네임스페이스 일관성을 유지해야 한다.
