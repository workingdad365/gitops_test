# GitOps Practice

## 즉시 실행 가이드(요약)
1) `dummy_server.py`, `Dockerfile`, `argocd`, `k8s` 관련 파일을 준비한다.
2) `.github/workflows/build-and-push-ghcr.yml` 생성 후 GitHub에 커밋한다.
3) `kind create cluster --name gitops-practice` 실행.
4) `kubectl create namespace argocd` 후 ArgoCD를 설치한다.
5) `kubectl apply -f argocd/dummy-server-application.yaml` 실행.
6) Ingress를 사용하려면 `kubectl apply -f k8s/dummy-server-ingress.yaml` 실행.
7) `kubectl apply -f k8s/argocd-server-ingress.yaml` 실행.
8) GitHub Actions 수동 실행: `Build and Push dummy_server to GHCR` → `Run workflow`.
9) 변경 반영 확인: `kubectl get application dummy-server -n argocd`.
10) 서비스 확인: `curl -s -H "Host: dummy.127.0.0.1.nip.io" http://127.0.0.1:28080/ip`.

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

      - name: Sync deployment manifest image tag
        run: |
          IMAGE_NAME="${{ steps.meta.outputs.IMAGE_NAME }}"
          IMAGE_TAG="${{ steps.meta.outputs.IMAGE_TAG }}"
          IMAGE_FULL="${IMAGE_NAME}:${IMAGE_TAG}"

          sed -i "s|${IMAGE_NAME}:[^[:space:]]*|${IMAGE_FULL}|g" k8s/deployment.yaml

          if git diff --quiet -- k8s/deployment.yaml; then
            echo "No manifest change."
            exit 0
          fi

          git config --global user.name "github-actions[bot]"
          git config --global user.email "github-actions[bot]@users.noreply.github.com"
          git add k8s/deployment.yaml
          git commit -m "chore: update dummy-server image tag to ${IMAGE_TAG}"
          git push origin HEAD:${GITHUB_REF_NAME}
```

### 5.1 실행 방식
- 기본 배포 태그는 `sha-<커밋해시 앞 7자리>` 형식이다.
- 워크플로우는 이미지 빌드/푸시 후 `k8s/deployment.yaml`의 `image` 태그를 갱신해 Git에 자동 커밋/푸시한다.

### 5.2 실행/확인 한 페이지 체크
1. GitHub에서 `Build and Push dummy_server to GHCR` → `Run workflow` 실행
2. 최근 커밋 확인: `git log -1 --oneline`
3. ArgoCD 상태 확인: `kubectl get application dummy-server -n argocd`
4. 배포 Pod 확인: `kubectl get pods -n dummy-server`
5. API 동작 확인: `curl -s -H "Host: dummy.127.0.0.1.nip.io" http://127.0.0.1:28080/ip`

### 5.3 업로드 이미지 확인
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

### 5.4 실습 복붙 실행 블록(현재 가이드 기준)
```bash
kind create cluster --name gitops-practice
kubectl create namespace argocd
kubectl apply --server-side --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/kind/deploy.yaml

kubectl apply -f argocd/dummy-server-application.yaml
kubectl apply -f k8s/dummy-server-ingress.yaml
kubectl apply -f k8s/argocd-server-ingress.yaml
kubectl get application dummy-server -n argocd

kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 28080:80
curl -s -H "Host: dummy.127.0.0.1.nip.io" http://127.0.0.1:28080/ip
curl -s -L -H "Host: argocd.127.0.0.1.nip.io" http://127.0.0.1:28080

# GHCR 푸시 후 자동 갱신용
kubectl get application dummy-server -n argocd
kubectl get pods -n dummy-server
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

## 9. dummy-server 배포(Application 적용)
- GitOps 배포용 매니페스트는 `k8s/deployment.yaml`, `k8s/service.yaml`, `k8s/namespace.yaml`(선택), `argocd/dummy-server-application.yaml` 순으로 준비한다.
- `k8s/deployment.yaml`의 image 값은 `ghcr.io/workingdad365/gitops_test:<태그>` 형식을 사용한다.
- Application을 생성하고 동기화한다.
```bash
kubectl apply -f argocd/dummy-server-application.yaml
kubectl get application dummy-server -n argocd
kubectl annotate application dummy-server -n argocd argocd.argoproj.io/refresh=hard --overwrite
```
- 동작 상태를 확인한다.
```bash
kubectl get pods -n dummy-server
kubectl get svc -n dummy-server
kubectl port-forward svc/dummy-server -n dummy-server 8081:80
curl http://localhost:8081/ip
```
- `curl` 테스트가 실패하면 `application`이 `OutOfSync`/`Missing`인지 확인하고, 문제가 없으면 하드 리프레시를 반복한다.
- ArgoCD UI를 `8080`에서 사용 중이라면 dummy 서비스는 다른 포트(예: `18080`)를 사용한다.

## 10. Ingress 설치/적용 (kind 기준)
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
- dummy-server Ingress 예시는 `k8s/dummy-server-ingress.yaml`로 저장한다.
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dummy-server
  namespace: dummy-server
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
spec:
  ingressClassName: nginx
  rules:
    - host: dummy.127.0.0.1.nip.io
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: dummy-server
                port:
                  number: 80
```
- Ingress를 배포하고 테스트한다.
```bash
kubectl apply -f k8s/dummy-server-ingress.yaml
kubectl get ingress -n dummy-server
kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 18081:80
curl -H "Host: dummy.127.0.0.1.nip.io" http://127.0.0.1:18081/ip
```
- 응답이 `{"ip":"..."}`이면 Ingress 연결이 완료된 것이다.

## 11. ArgoCD UI를 Ingress로 노출
- `k8s/argocd-server-ingress.yaml` 생성 후 적용한다.
```bash
kubectl apply -f k8s/argocd-server-ingress.yaml
kubectl get ingress -n argocd
```
- 테스트 포트포워드는 기존 `8080` 충돌을 피해서 별도 포트를 사용한다.
```bash
kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 18080:80
curl -L -H "Host: argocd.127.0.0.1.nip.io" http://127.0.0.1:18080
```
- 브라우저로 확인할 때는 `http://argocd.127.0.0.1.nip.io:18080`로 접속한다.
- 로그인은 기존 `admin` 계정과 `argocd-initial-admin-secret` 비밀번호를 사용한다.

## 12. 마무리 체크리스트
- 실행 포트 정리
  - ArgoCD는 `kubectl port-forward -n argocd svc/argocd-server 8080:443`로 운영
  - Ingress 테스트는 `28080:80` 또는 사용 가능한 임시 포트로 운영
- 최종 동작 점검
  - `kubectl get application dummy-server -n argocd`
  - `curl -s -H "Host: dummy.127.0.0.1.nip.io" http://127.0.0.1:28080/ip`
  - `curl -s -H "Host: argocd.127.0.0.1.nip.io" http://127.0.0.1:28080`
- 매니페스트 동기화 재실행
  - `kubectl annotate application dummy-server -n argocd argocd.argoproj.io/refresh=hard --overwrite`
- 정리
  - 완료 후 필요 없어진 `kubectl port-forward`는 종료한다.
  - 새 이미지 배포는 GHCR 푸시 후 `deployment.yaml`의 태그 갱신 → `git push` → 위 주석된 hard refresh 순으로 반복한다.
  - 향후 이미지 태그만 바꿔도 바로 배포되도록 하려면 추후 Helm/이미지 업데이트 자동화 단계를 추가할 수 있다.
