# 🏠 GitOps on Raspberry Pi 5

> Raspberry Pi 5 위에서 ArgoCD로 GitOps 워크플로우를 구축한 홈랩 학습 레포

![Kubernetes](https://img.shields.io/badge/Kubernetes-k3s-326CE5?logo=kubernetes&logoColor=white)
![ArgoCD](https://img.shields.io/badge/ArgoCD-GitOps-EF7B4D?logo=argo&logoColor=white)
![Helm](https://img.shields.io/badge/Helm-Chart-0F1689?logo=helm&logoColor=white)
![Tailscale](https://img.shields.io/badge/Tailscale-Mesh_VPN-242424?logo=tailscale&logoColor=white)
![Discord](https://img.shields.io/badge/Discord-Webhook-5865F2?logo=discord&logoColor=white)

---

## 🎯 Overview

Raspberry Pi 5 (ARM64) 위에 k3s 클러스터를 구성하고, ArgoCD를 통해 Git을 단일 진실의 원천(Single Source of Truth)으로 삼는 GitOps 워크플로우를 직접 구축했다. 단순히 배포 자동화에 그치지 않고, 멀티 환경(dev/prod) 관리, 알림 시스템, 보안 강화까지 실제 운영 환경에서 마주치는 문제들을 단계적으로 해결했다.

---

## 🏗 Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Developer                            │
│                    git push to GitHub                       │
└──────────────────────────┬──────────────────────────────────┘
                           │  webhook / polling
                           ▼
┌──────────────────────────────────────────────────────────────┐
│                      GitHub Repository                       │
│  ┌─────────────────┐         ┌──────────────────────────┐   │
│  │   argocd/        │         │   apps/                  │   │
│  │  ├ root-app.yaml │         │   └── nginx/ (Helm Chart)│   │
│  │  ├ applications/ │         │       ├ values-dev.yaml  │   │
│  │  └ notifications │         │       └ values-prod.yaml │   │
│  └─────────────────┘         └──────────────────────────┘   │
└──────────────────────┬───────────────────────────────────────┘
                       │  ArgoCD watches & pulls
                       ▼
┌──────────────────────────────────────────────────────────────┐
│              Raspberry Pi 5  (k3s cluster)                   │
│                                                              │
│   ┌─────────────────────────────────────────────────────┐   │
│   │  ArgoCD (argocd namespace)                          │   │
│   │   Root App ──► nginx-dev App  ──► nginx (dev ns)    │   │
│   │             └► nginx-prod App ──► nginx (prod ns)   │   │
│   └─────────────────────────────────────────────────────┘   │
│                          │                                   │
│               sync / health event                            │
│                          ▼                                   │
│   ┌──────────────────────────────┐                          │
│   │  argocd-notifications        │──────► Discord Channel   │
│   │  (deployed / failed /        │        ✅ ❌ 🔴          │
│   │   health-degraded)           │                          │
│   └──────────────────────────────┘                          │
└──────────────────────────────────────────────────────────────┘
                       ▲
         Tailscale (WireGuard Mesh VPN)
         외부 어디서든 kubectl / ArgoCD UI 접근
```

`apps/`는 실제 워크로드(Helm Chart), `argocd/`는 ArgoCD 관리 리소스(Application, Notification)로 디렉토리를 분리했다. Root App이 `argocd/applications/`를 감시하는 App of Apps 패턴으로, 신규 Application 추가 시 YAML 파일 하나만 커밋하면 자동 등록된다.

---

## ⚙️ Tech Stack

| 카테고리 | 기술 | 비고 |
|----------|------|------|
| **Container Orchestration** | k3s, Helm 3 | ARM64 경량 Kubernetes 배포판 |
| **GitOps** | ArgoCD 3.x | Application, App of Apps, Notifications |
| **Networking** | Tailscale | WireGuard 기반 Mesh VPN, 외부 접근 |
| **Notification** | Discord Webhook | 배포 성공 / Sync 실패 / Health Degraded |
| **Hardware** | Raspberry Pi 5 8GB | ARM64, 홈랩 클러스터 노드 |

---

## 📁 Repository Structure

```
gitops/
├── apps/                          # 워크로드 선언 (Helm Charts)
│   └── nginx/
│       ├── Chart.yaml             # Chart 메타데이터
│       ├── templates/
│       │   ├── deployment.yaml    # Deployment 템플릿
│       │   └── service.yaml       # Service 템플릿
│       ├── values.yaml            # Base defaults
│       ├── values-dev.yaml        # Dev 오버라이드 (replica=1, 리소스 절감)
│       └── values-prod.yaml       # Prod 오버라이드 (replica=3, 버전 핀)
│
└── argocd/                        # ArgoCD 관리 리소스
    ├── applications/              # Child Applications (App of Apps 대상)
    │   ├── nginx-dev.yaml
    │   └── nginx-prod.yaml
    ├── root-app.yaml              # App of Apps 루트
    └── notifications-cm.yaml      # Discord 알림 ConfigMap
```

**설계 의도:** `apps/`와 `argocd/`를 분리함으로써 "무엇을 배포하는가(apps)"와 "어떻게 배포를 관리하는가(argocd)"의 관심사를 명확히 구분했다. 신규 서비스 추가 시 `apps/`에 Helm Chart를, `argocd/applications/`에 Application YAML만 추가하면 Root App이 자동으로 감지한다.

---

## 🚀 Key Features

### App of Apps Pattern
`root-app.yaml` 하나가 `argocd/applications/` 디렉토리 전체를 감시한다. 신규 Application을 추가하려면 Git에 YAML 파일 하나만 커밋하면 ArgoCD가 자동으로 Child Application을 생성한다. ArgoCD 자체도 GitOps로 관리되는 구조다.

### Multi-environment via Helm Values
동일한 Helm Chart를 사용하면서 `values-dev.yaml` / `values-prod.yaml`로 환경별 차이를 선언한다. Dev는 replica=1에 최신 alpine 태그를, Prod는 replica=3에 패치 버전까지 고정(1.27.3-alpine)해 예측 가능성을 확보했다.

### Self-heal + Auto-sync
ArgoCD의 `selfHeal: true`, `prune: true` 설정으로 클러스터 상태가 Git과 달라지면 자동 복구된다. `kubectl scale` 등으로 임의로 replica를 변경해도 수십 초 내로 Git 선언 상태로 되돌아온다.

### Discord Notifications (3종)
배포 성공(`on-deployed`), Sync 실패(`on-sync-failed`), Health Degraded(`on-health-degraded`) 세 가지 트리거를 구성했다. 의도적으로 존재하지 않는 이미지 태그를 배포해 알림 발송을 검증한 뒤 `git revert`로 복구하는 흐름까지 실습했다.

### Security Hardening
ArgoCD 초기 admin 패스워드를 변경하고, 읽기 전용 RBAC viewer 계정을 별도로 생성했다. 최소 권한 원칙에 따라 배포 권한이 필요 없는 관찰자는 viewer 계정을 사용하도록 구성했다.

---

## 💡 Key Learnings

- **GitOps 4원칙**: 선언적(Declarative) → 버전관리(Versioned) → 자동적용(Automated) → 지속조정(Continuously reconciled) 사이클을 직접 체감
- **Sync vs Health 분리**: `Synced`이지만 `Degraded`가 가능함 — Git 반영과 실제 서비스 상태는 별개의 개념
- **K8s Controller Pattern**: watch → diff → act 무한루프가 Self-heal의 실체이며, ArgoCD가 이를 Application 레벨에서 구현한 것임을 이해
- **Helm Values 우선순위**: `values-dev.yaml`이 `values.yaml`을 덮어쓰는 계층 구조로 DRY 원칙 적용 — 공통값은 한 곳만 수정
- **App of Apps 재귀 구조**: Root App → Child Apps → 실제 워크로드로 이어지는 계층적 GitOps 관리 구조
- **GitOps 롤백**: `kubectl rollout undo`가 아닌 `git revert`로 롤백 — 이력이 Git에 남고 ArgoCD가 자동 적용

---

## 🔍 Troubleshooting Experience

운영 환경에서 마주치는 문제들을 직접 재현하고 해결한 경험이 이 레포의 핵심 자산이다.

**1. ApplicationSet CRD annotation size limit 초과**
ArgoCD ApplicationSet 적용 시 `kubectl.kubernetes.io/last-applied-configuration` 어노테이션이 262144바이트 제한을 초과해 apply 실패. `kubectl apply --server-side`로 전환해 해결했다. Client-side apply와 Server-side apply의 차이를 실제로 경험.

**2. Orphan 리소스 — Application 삭제 시 종속 리소스 잔존**
ArgoCD Application 삭제 후에도 배포된 Deployment/Service가 클러스터에 남아있는 문제. `resources-finalizer.argocd.argoproj.io` finalizer가 없으면 ArgoCD가 종속 리소스를 정리하지 않음을 파악하고, 모든 Application에 finalizer를 추가해 해결.

**3. argocd-server CrashLoopBackOff — timezone 불일치**
argocd-server Pod가 반복 재시작되는 현상. admin 비밀번호 변경 시 `passwordMtime` 필드에 `date +%Z` (KST abbreviation) 출력값을 넣었던 것이 원인. Go의 time.Parse는 RFC3339 표준만 인식하므로 "EST"가 5가지 타임존을 의미할 수 있는 abbreviation의 모호성 때문에 거부. `date -u +%FT%TZ` (UTC) 형식으로 변경 후 해결.

> **검증 방법론**: 의도적으로 존재하지 않는 이미지 태그(`nginx:intentional-fail`)를 배포해 Health Degraded 알림 트리거를 검증한 뒤, `git revert`로 복구하는 흐름을 실습했다. 장애를 능동적으로 주입해 모니터링 시스템을 검증하는 Chaos Engineering의 기본 사고방식을 적용.

---

## 📚 Learning Notes

구축 과정과 개념 정리는 Notion에 기록  
(링크 추가 예정)

---

## 📄 License

[MIT](LICENSE)
