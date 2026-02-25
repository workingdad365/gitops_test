# GitOps Practice

## 즉시 실행 가이드(요약)
1) `dummy_server.py`, `Dockerfile`, `argocd/`, `helm/` 관련 파일을 준비한다.
2) `.github/workflows/build-and-push-ghcr.yml` 생성 후 GitHub에 커밋한다.
3) `kind create cluster --name gitops-practice` 실행.
4) `kubectl create namespace argocd` 후 ArgoCD를 설치한다.
5) `kubectl apply -f argocd/dummy-server-application.yaml` 실행.
6) Ingress Controller를 설치한다 (kind용 ingress-nginx).
7) `kubectl apply -f k8s/argocd-server-ingress.yaml` 실행.
8) GitHub Actions 수동 실행: `Build and Push dummy_server to GHCR` → `Run workflow`.
9) 변경 반영 확인: `kubectl get application dummy-server -n argocd`.
10) 서비스 확인: `curl -s -H "Host: dummy.127.0.0.1.nip.io" http://127.0.0.1:28080/ip`.
11) 인사말 확인: `curl -s -H "Host: dummy.127.0.0.1.nip.io" http://127.0.0.1:28080/sayhello`.

## 1. 목표
- FastAPI 기반 API 서버(`dummy_server.py`)를 구현한다.
- Docker 이미지로 빌드한다.
- GitHub Container Registry(GHCR)에 수동 워크플로우로 배포한다.
- 로컬 Kubernetes 환경(kind)과 ArgoCD를 설치한다.
- Helm Chart를 사용하여 Kubernetes 리소스를 관리한다.
- 환경변수(`GREETING_MESSAGE`)를 `values.yaml`로 분리하여 GitOps 방식으로 관리한다.

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
import os

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


@app.get("/sayhello")
def say_hello():
    message = os.environ.get("GREETING_MESSAGE", "Hello!")
    return {"message": message}
```

### 3.1 동작 요약
- `GET /ip` 호출 시 클라이언트 IP 반환
- `x-forwarded-for` 헤더가 있으면 그 값을 우선 사용
- 없으면 `request.client.host` 사용
- `GET /sayhello` 호출 시 환경변수 `GREETING_MESSAGE` 값을 반환 (기본값: `Hello!`)

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

## 5. Helm Chart 구성

### 5.1 디렉터리 구조
```
helm/dummy-server/
├── Chart.yaml
├── values.yaml
└── templates/
    ├── _helpers.tpl
    ├── deployment.yaml
    ├── service.yaml
    ├── ingress.yaml
    └── NOTES.txt
```

### 5.2 Chart.yaml
```yaml
apiVersion: v2
name: dummy-server
description: A Helm chart for dummy-server FastAPI application
type: application
version: 0.1.0
appVersion: "1.0.0"
```

### 5.3 values.yaml
모든 설정 값을 여기서 관리한다. 환경변수도 `env` 섹션에서 정의한다.

```yaml
replicaCount: 1

image:
  repository: ghcr.io/workingdad365/gitops_test
  tag: sha-20ea14c
  pullPolicy: Always

service:
  type: ClusterIP
  port: 80
  targetPort: 8000

ingress:
  enabled: true
  className: nginx
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
  host: dummy.127.0.0.1.nip.io

env:
  GREETING_MESSAGE: "안녕하세요 무엇을 도와드릴까요?"
```

### 5.4 핵심 템플릿 설명

**`templates/deployment.yaml`** — 환경변수를 `values.yaml`의 `env` 맵에서 동적으로 주입한다:
```yaml
env:
  {{- range $key, $value := .Values.env }}
  - name: {{ $key }}
    value: {{ $value | quote }}
  {{- end }}
```

**`templates/ingress.yaml`** — `ingress.enabled`가 `true`일 때만 생성된다.

### 5.5 Helm Chart 방식의 장점

| 항목 | 설명 |
|------|------|
| 이미지 태그 변경 | `values.yaml`의 `image.tag`만 변경하면 자동 반영 |
| 환경변수 관리 | `values.yaml`의 `env` 섹션에서 통합 관리 |
| Ingress 설정 | 차트 안에 포함, `enabled` 플래그로 제어 |
| 환경별 설정 분리 | `values-dev.yaml`, `values-prod.yaml` 등으로 분리 가능 |
| ArgoCD 연동 | `source.helm` 설정으로 네이티브 Helm 렌더링 지원 |

## 6. ArgoCD Application

`argocd/dummy-server-application.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: dummy-server
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/workingdad365/gitops_test.git
    targetRevision: main
    path: helm/dummy-server
    helm:
      releaseName: dummy-server
      valueFiles:
        - values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: dummy-server
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- `source.path`에 Helm 차트 경로(`helm/dummy-server`)를 지정한다.
- `source.helm` 섹션으로 Helm 차트를 네이티브로 렌더링한다.
- `releaseName`으로 릴리스 이름을 명시적으로 지정한다.

## 7. GitHub Actions 워크플로우(수동 실행, GHCR Push)

`build-and-push-ghcr.yml` 작성 위치:
`.github/workflows/build-and-push-ghcr.yml`

```yaml
name: Build and Push dummy_server to GHCR

on:
  workflow_dispatch:

permissions:
  contents: write
  packages: write

jobs:
  build-and-push:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
          persist-credentials: true

      - name: Prepare image metadata
        id: meta
        run: |
          OWNER="${{ github.repository_owner }}"
          REPO="${{ github.event.repository.name }}"
          OWNER_LOWER="$(echo "$OWNER" | tr '[:upper:]' '[:lower:]')"
          REPO_LOWER="$(echo "$REPO" | tr '[:upper:]' '[:lower:]')"
          IMAGE_SHA="${GITHUB_SHA:0:7}"
          IMAGE_TAG="sha-${IMAGE_SHA}"
          IMAGE_DATE_TAG="$(date +'%Y%m%d-%H%M%S')"
          echo "IMAGE_NAME=ghcr.io/${OWNER_LOWER}/${REPO_LOWER}" >> "$GITHUB_OUTPUT"
          echo "IMAGE_TAG=${IMAGE_TAG}" >> "$GITHUB_OUTPUT"
          echo "IMAGE_DATE_TAG=${IMAGE_DATE_TAG}" >> "$GITHUB_OUTPUT"

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
            ${{ steps.meta.outputs.IMAGE_NAME }}:${{ steps.meta.outputs.IMAGE_DATE_TAG }}

      - name: Sync Helm values image tag
        run: |
          IMAGE_TAG="${{ steps.meta.outputs.IMAGE_TAG }}"

          sed -i "s/^  tag: .*/  tag: ${IMAGE_TAG}/" helm/dummy-server/values.yaml

          if git diff --quiet -- helm/dummy-server/values.yaml; then
            echo "No values change."
            exit 0
          fi

          git config --global user.name "github-actions[bot]"
          git config --global user.email "github-actions[bot]@users.noreply.github.com"
          git add helm/dummy-server/values.yaml
          git commit -m "chore: update dummy-server image tag to ${IMAGE_TAG}"
          git push origin HEAD:${GITHUB_REF_NAME}
```

### 7.1 실행 방식
- 기본 배포 태그는 `sha-<커밋해시 앞 7자리>` 형식이다.
- 워크플로우는 이미지 빌드/푸시 후 `helm/dummy-server/values.yaml`의 `image.tag`를 갱신해 Git에 자동 커밋/푸시한다.
- ArgoCD가 Git 변경을 감지하여 자동 동기화한다.

### 7.2 실행/확인 한 페이지 체크
1. GitHub에서 `Build and Push dummy_server to GHCR` → `Run workflow` 실행
2. 최근 커밋 확인: `git log -1 --oneline`
3. ArgoCD 상태 확인: `kubectl get application dummy-server -n argocd`
4. 배포 Pod 확인: `kubectl get pods -n dummy-server`
5. API 동작 확인:
```bash
curl -s -H "Host: dummy.127.0.0.1.nip.io" http://127.0.0.1:28080/ip
curl -s -H "Host: dummy.127.0.0.1.nip.io" http://127.0.0.1:28080/sayhello
```

## 8. 환경변수 변경 데모: GREETING_MESSAGE

Helm + ArgoCD GitOps 환경에서 환경변수를 변경하고 자동 배포되는 과정을 확인한다.

### 8.1 현재 값 확인
```bash
curl -s -H "Host: dummy.127.0.0.1.nip.io" http://127.0.0.1:28080/sayhello
# 응답: {"message":"안녕하세요 무엇을 도와드릴까요?"}
```

### 8.2 값 변경하기
`helm/dummy-server/values.yaml`에서 `GREETING_MESSAGE`를 수정한다:
```yaml
env:
  GREETING_MESSAGE: "반갑습니다! 새로운 인사말입니다."
```

### 8.3 Git에 커밋/푸시
```bash
git add helm/dummy-server/values.yaml
git commit -m "chore: update GREETING_MESSAGE"
git push
```

### 8.4 ArgoCD 자동 동기화 확인
ArgoCD가 Git 변경을 감지하고 자동 배포한다 (syncPolicy.automated 설정).
```bash
# 동기화 상태 확인
kubectl get application dummy-server -n argocd

# 즉시 동기화를 원하면 하드 리프레시
kubectl annotate application dummy-server -n argocd argocd.argoproj.io/refresh=hard --overwrite

# Pod 재시작 확인 (환경변수 변경 시 Pod가 재생성됨)
kubectl get pods -n dummy-server -w
```

### 8.5 변경된 값 확인
```bash
curl -s -H "Host: dummy.127.0.0.1.nip.io" http://127.0.0.1:28080/sayhello
# 응답: {"message":"반갑습니다! 새로운 인사말입니다."}
```

## 9. 로컬 Kubernetes 환경(kind) 구축
### 9.1 kind 설치
```bash
curl -Lo kind https://kind.sigs.k8s.io/dl/v0.27.0/kind-linux-amd64
chmod +x kind
sudo mv kind /usr/local/bin/kind
kind version
```

### 9.2 kubectl 설치
```bash
curl -LO "https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --client
```

### 9.3 클러스터 생성
```bash
kind create cluster --name gitops-practice
kubectl cluster-info
kubectl get nodes
```

## 10. ArgoCD 설치
### 10.1 설치 명령
```bash
kubectl create namespace argocd
kubectl apply --server-side --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

### 10.2 상태 확인
```bash
kubectl get pods -n argocd
kubectl get svc -n argocd
```
모든 Pod가 `Running`이면 설치 완료.

### 10.3 UI 접속
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```
- 브라우저: `https://localhost:8080`
- 아이디: `admin`
- 초기 비밀번호 조회:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```

## 11. 실습 복붙 실행 블록

```bash
# 1. 클러스터 생성 & 기본 인프라
kind create cluster --name gitops-practice
kubectl create namespace argocd
kubectl apply --server-side --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/kind/deploy.yaml

# 2. ArgoCD Application 배포 (Helm 차트 연동)
kubectl apply -f argocd/dummy-server-application.yaml
kubectl apply -f k8s/argocd-server-ingress.yaml
kubectl get application dummy-server -n argocd

# 3. 포트포워드 & 테스트
kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 28080:80
curl -s -H "Host: dummy.127.0.0.1.nip.io" http://127.0.0.1:28080/ip
curl -s -H "Host: dummy.127.0.0.1.nip.io" http://127.0.0.1:28080/sayhello
curl -s -L -H "Host: argocd.127.0.0.1.nip.io" http://127.0.0.1:28080

# 4. 환경변수 변경 테스트
# helm/dummy-server/values.yaml 에서 GREETING_MESSAGE 수정 후:
git add helm/dummy-server/values.yaml
git commit -m "chore: update GREETING_MESSAGE"
git push
kubectl annotate application dummy-server -n argocd argocd.argoproj.io/refresh=hard --overwrite
curl -s -H "Host: dummy.127.0.0.1.nip.io" http://127.0.0.1:28080/sayhello
```

## 12. Ingress 설치/적용 (kind 기준)
- ingress-nginx를 설치한다.
```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/kind/deploy.yaml
kubectl get ns ingress-nginx
kubectl get pods -n ingress-nginx
```
- 단일 노드에서 컨트롤러가 Pending이면 노드 라벨을 추가한다.
```bash
kubectl label node gitops-practice-control-plane ingress-ready=true --overwrite
kubectl get pods -n ingress-nginx -w
```
- dummy-server Ingress는 Helm 차트에 포함되어 자동 배포된다 (`values.yaml`의 `ingress.enabled: true`).
- ArgoCD Ingress는 별도로 적용한다:
```bash
kubectl apply -f k8s/argocd-server-ingress.yaml
kubectl get ingress -n argocd
```

## 13. ArgoCD UI를 Ingress로 노출
- `k8s/argocd-server-ingress.yaml` 적용 후 확인한다.
```bash
kubectl apply -f k8s/argocd-server-ingress.yaml
kubectl get ingress -n argocd
```
- 테스트:
```bash
kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 28080:80
curl -L -H "Host: argocd.127.0.0.1.nip.io" http://127.0.0.1:28080
```
- 브라우저: `http://argocd.127.0.0.1.nip.io:28080`
- 로그인은 `admin` 계정과 `argocd-initial-admin-secret` 비밀번호를 사용한다.

## 14. 프로젝트 구조

```
gitops_test/
├── dummy_server.py              # FastAPI 애플리케이션
├── Dockerfile                   # 컨테이너 이미지 정의
├── README.md
├── argocd/
│   └── dummy-server-application.yaml   # ArgoCD Application (Helm 소스)
├── helm/
│   └── dummy-server/
│       ├── Chart.yaml           # Helm 차트 메타데이터
│       ├── values.yaml          # 설정 값 (이미지 태그, 환경변수 등)
│       └── templates/
│           ├── _helpers.tpl     # 템플릿 헬퍼 함수
│           ├── deployment.yaml  # Deployment 템플릿
│           ├── service.yaml     # Service 템플릿
│           ├── ingress.yaml     # Ingress 템플릿
│           └── NOTES.txt        # 배포 후 안내 메시지
├── k8s/
│   └── argocd-server-ingress.yaml  # ArgoCD UI Ingress (수동 적용)
└── .github/
    └── workflows/
        └── build-and-push-ghcr.yml  # CI 워크플로우
```

## 15. 마무리 체크리스트
- 실행 포트 정리
  - ArgoCD는 `kubectl port-forward -n argocd svc/argocd-server 8080:443`로 운영
  - Ingress 테스트는 `28080:80` 또는 사용 가능한 임시 포트로 운영
- 최종 동작 점검
  - `kubectl get application dummy-server -n argocd`
  - `curl -s -H "Host: dummy.127.0.0.1.nip.io" http://127.0.0.1:28080/ip`
  - `curl -s -H "Host: dummy.127.0.0.1.nip.io" http://127.0.0.1:28080/sayhello`
  - `curl -s -H "Host: argocd.127.0.0.1.nip.io" http://127.0.0.1:28080`
- 환경변수 변경 테스트
  - `helm/dummy-server/values.yaml`의 `GREETING_MESSAGE` 수정 → `git push` → ArgoCD 자동 동기화 → `/sayhello` 응답 변경 확인
- 매니페스트 동기화 재실행
  - `kubectl annotate application dummy-server -n argocd argocd.argoproj.io/refresh=hard --overwrite`
- 정리
  - 완료 후 필요 없어진 `kubectl port-forward`는 종료한다.
  - 새 이미지 배포는 GHCR 푸시 후 `values.yaml`의 `image.tag` 자동 갱신 → ArgoCD 동기화 순으로 반복한다.


