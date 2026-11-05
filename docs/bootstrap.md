# Argo CD bootstrap

## 구성

- `bootstrap/argocd/`: Argo CD v3.6.1 공식 설치 매니페스트를 참조한다.
  초기 구성은 non-HA이며, Argo CD 자체의 고가용성 전환은 별도 작업이다.
- `bootstrap/`: AppProject 4개와 부모 Application `dangubi-root`를 등록한다.
- 부모는 이 레포의 `main` 브랜치에 있는 `apps/`를 재귀적으로 감시한다.
  기능 브랜치의 변경은 `main` 병합 후 반영된다.
- `apps/infra/platform.yaml`은 `manifests/infra/platform/`의 네임스페이스와 자원 쿼터를 배포한다.

Argo CD 3.6의 공식 테스트 대상에는 Kubernetes 1.36이 포함된다.
설치 매니페스트는 이동하는 `stable` 대신 v3.6.1로 고정한다.

## 프로젝트와 배포 대상

| AppProject | 배포 네임스페이스 | 담당 리소스 |
| --- | --- | --- |
| `dangubi-root` | `argocd` | 하위 Application만 |
| `dangubi-infra` | `kube-system`, `metallb-system`, `argo-rollouts`, `dangubi-data`, `dangubi` | 플랫폼, Namespace, PV, StorageClass, CRD 등 |
| `dangubi-data` | `dangubi-data` | MySQL, MongoDB, Kafka, Kafka Connect |
| `dangubi-workloads` | `dangubi` | Command, Query |

`dangubi`와 `dangubi-data`를 이후 A/B 작업의 기본 네임스페이스로 사용한다.
Argo CD 설치 단계에서는 `argocd`만 생성한다. 업무·데이터 및 플랫폼 컨트롤러용
네임스페이스는 `manifests/infra/platform/`에서 별도로 관리한다.

하위 Application에는 위 표의 `spec.project`와 `spec.destination.namespace`를 지정한다.
업무와 데이터 프로젝트는 클러스터 범위 리소스 및 ResourceQuota·LimitRange 변경을 허용하지 않는다.
AppProject 이름에 `dangubi-`를 붙여 다른 프로젝트와 구분한다.

root·data·workloads 프로젝트는 이 GitOps 레포만 허용한다.
infra 프로젝트는 Cinder CSI 설치를 위해 공식 OpenStack chart 저장소도 허용한다.
외부 Helm chart를 추가로 도입할 때 해당 프로젝트에 정확한 chart 저장소 URL을 추가한다.
Operator를 도입하면 컨트롤러·CRD는 infra에서, 클러스터 정의는 data에서 관리한다.
Calico와 OpenStack CCM은 기존 Ansible에서 계속 관리한다.

## 최초 설치

클러스터 관리자 권한의 kubeconfig가 있는 실행 노드에서 이 레포의 루트를 기준으로 실행한다.
아래 명령은 실제 클러스터에 리소스를 생성한다. 먼저 현재 context와 대상 노드를 확인한다.

```sh
kubectl config current-context
kubectl get nodes
```

Argo CD가 설치되지 않은 클러스터에 다음을 적용한다.
이미 설치돼 있다면 버전과 설치 도구를 먼저 확인하고 기존 설치를 중복 관리하지 않는다.

```sh
kubectl apply --server-side -k bootstrap/argocd
kubectl wait --for=condition=Established --timeout=120s \
  crd/applications.argoproj.io \
  crd/appprojects.argoproj.io \
  crd/applicationsets.argoproj.io
kubectl -n argocd rollout status deployment/argocd-redis --timeout=300s
kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=300s
kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
```

큰 CRD의 클라이언트 측 annotation 크기 제한을 피하기 위해 설치는 server-side apply를 사용한다.
필드 소유권 충돌이 발생하면 기존 관리 주체를 확인하고 해결한다.

비공개 레포라면 root 등록 전에 Argo CD에 읽기용 인증 정보를 설정한다.
인증 정보의 실제 값이나 kubeconfig는 Git에 커밋하지 않는다.

## root와 프로젝트 등록

```sh
kubectl apply -f bootstrap/root-project.yaml
kubectl apply -f bootstrap/infra-project.yaml
kubectl apply -f bootstrap/data-project.yaml
kubectl apply -f bootstrap/workloads-project.yaml
kubectl apply -f bootstrap/root-app.yaml

kubectl -n argocd get appprojects
kubectl -n argocd get applications
kubectl -n argocd get application dangubi-root \
  -o jsonpath='{.status.sync.status}{" "}{.status.health.status}{"\n"}'
```

root의 `Synced`와 `Healthy`를 확인한다. 동기화에 실패하면 다음 명령으로 원인을 확인한다.

```sh
kubectl -n argocd describe application dangubi-root
```

## 플랫폼 네임스페이스와 자원 쿼터

`dangubi-platform` Application은 `dangubi-infra` 프로젝트로 다음 네임스페이스를 생성한다.

- `dangubi`: Command, Query
- `dangubi-data`: MySQL, MongoDB, Kafka, Kafka Connect
- `metallb-system`: MetalLB
- `argo-rollouts`: Argo Rollouts

기존 `kube-system`과 별도로 설치한 `argocd`는 이 Application에서 관리하지 않는다.
여러 네임스페이스를 다루므로 Kustomize의 공통 `namespace` 변환은 사용하지 않는다.
MetalLB Speaker에 필요한 privileged Pod Security 라벨은 `metallb-system`에만 지정한다.
설정 근거는 [MetalLB 설치 문서](https://metallb.io/installation/)를 따른다.

Namespace에는 `Prune=false,Delete=false`를 지정한다. 플랫폼 Application의 자동 prune이나
Argo CD를 통한 Application 연쇄 삭제가 Namespace 내부의 DB·PVC까지 삭제하지 않도록 한다.
이는 Kubernetes API로 Namespace를 직접 삭제하는 작업까지 막지는 않는다.
설정 근거는 [Argo CD sync options](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/)를 따른다.

Application의 sync wave `-30`은 부모가 하위 Application을 등록하는 순서에 사용한다.
다른 Application이 플랫폼 내부 리소스의 Ready 상태를 반드시 기다리게 하는 설정은 아니다.
최초 플랫폼 동기화 후 네임스페이스가 생성됐는지 확인하고 컨트롤러·DB 배포를 진행한다.

2026-11-05에 사용자가 조회한 Worker Allocatable을 초기 예산의 기준으로 사용한다.
Control Plane 3대의 자원은 업무·데이터 배포 예산에 포함하지 않는다.

| Worker | Allocatable CPU | Allocatable 메모리 |
| --- | --- | --- |
| `k8s-worker-1` | 8 | 15241028Ki, 약 14.5350Gi |
| `k8s-worker-2` | 8 | 15241036Ki, 약 14.5350Gi |
| `k8s-worker-3` | 8 | 15241024Ki, 약 14.5350Gi |
| `k8s-worker-4` | 8 | 30699324Ki, 약 29.2772Gi |

합계는 CPU 32, 메모리 76422412Ki, 약 72.8821Gi다.
이 값은 현재 사용량이나 여유량이 아니라 노드의 Pod 할당 가능 상한이다.

`resourcequotas.yaml`은 아래 초기 한도를 적용한다. 값은 성능 측정으로 확정한 운영 한도가 아니며,
B의 실제 chart와 앱 자원 설정을 대조하고 필요하면 변경한다.

| Namespace | CPU requests 합계 | 메모리 requests 합계 | 메모리 limits 합계 |
| --- | --- | --- | --- |
| `dangubi-data` | 16 | 40Gi | 48Gi |
| `dangubi` | 8 | 8Gi | 12Gi |

데이터 계층의 기준 후보는 MySQL 3개, MongoDB 3개, Kafka 겸용 3개, Router 2개와
Connect 2개다. 기존 배치 초안의 후보 자원으로 계산하면 CPU requests 8.7,
메모리 requests 32.5Gi, 메모리 limits 34.5Gi다. 이 중 일부 값을 실제로 변경하거나
Operator·exporter·보조 컨테이너를 추가하면 해당 사용량도 쿼터에 포함한다.
기존 초안의 별도 Jenkins·relay 배치는 현재 구성에 그대로 적용하지 않는다.

업무 앱은 Command 초기 2개에서 4개 비교 시험, Query blue-green 시 최대 4개를 고려한 예산이다.
예를 들어 내장 relay를 포함한 Command가 Pod당 CPU request 0.75, 메모리 request 1.25Gi,
메모리 limit 1.5Gi이고 Query가 각각 0.5, 0.75Gi, 1Gi라면, 4개씩 실행할 때
CPU requests 5, 메모리 requests 8Gi, 메모리 limits 10Gi다.
이는 예산 산정을 위한 예시이며 앱별 리소스 설정은 이후 실제 사용량으로 확정한다.
예시대로 requests 8Gi를 모두 사용하면 추가 surge·검증 Pod를 위한 여유가 없으므로
증설과 배포의 동시 실행을 제한하거나 쿼터를 먼저 조정한다.

두 네임스페이스의 CPU requests 상한 합계는 24, 메모리 requests는 48Gi,
메모리 limits는 60Gi다. Worker 전체 대비 CPU requests 8, 메모리 limits 약 12.8821Gi를
플랫폼 및 기타 사용량을 위한 예산상 여유로 남긴다. ResourceQuota는 이 여유를 시스템용으로
예약하거나 노드별 배치·장애 복구를 보장하지 않는다. 기존 시스템 Pod의 실제 사용량은 별도 확인한다.
가장 큰 Worker가 사라지면 잔여 메모리는 약 43.6049Gi이므로, limits 60Gi를 모두 사용하는
부하의 재배치를 보장할 수 없다. 노드별 affinity·스토리지와 장애 시 축소 운영을 별도로 검증한다.

쿼터 적용 후 해당 네임스페이스의 컨테이너에는 CPU·메모리 requests와 메모리 limits가 필요하다.
chart의 보조 컨테이너, init container, 초기화·업그레이드 Job에도 해당 필드를 지정한다.
CPU limits와 PVC 개수·저장소 용량 쿼터는 이번에 강제하지 않는다.
LimitRange의 자동 기본값도 적용하지 않으므로 배포 파일에 자원 설정을 명시한다.
동작 근거는 [Kubernetes ResourceQuota 문서](https://kubernetes.io/docs/concepts/policy/resource-quotas/)를 따른다.

`main` 병합 및 root 동기화 후 실행 노드에서 확인한다.

```sh
kubectl -n argocd get application dangubi-platform
kubectl get namespace dangubi dangubi-data metallb-system argo-rollouts
kubectl -n dangubi-data describe resourcequota dangubi-data-compute
kubectl -n dangubi describe resourcequota dangubi-workloads-compute
```

다음 단계인 Cinder CSI와 공통 StorageClass의 구성·확인 절차는 [storage.md](storage.md)를 따른다.

## 변경과 삭제

root는 자동 동기화와 self-heal을 활성화하고, 자식 Application의 자동 prune은 비활성화한다.
`apps/`에서 파일을 삭제해도 대응하는 Application은 자동 삭제되지 않는다.
삭제 시 해당 Application의 finalizer와 관리 대상을 확인하고 수동으로 정리한다.
이 설정은 자식 Application 자체의 동기화·prune 설정을 변경하지 않는다.

`bootstrap/`은 root의 감시 대상이 아니다. AppProject나 root를 변경하면
리뷰 후 `kubectl apply -k bootstrap`으로 재적용한다.
Argo CD 자체의 설치 변경은 `kubectl apply --server-side -k bootstrap/argocd`로 별도 적용한다.
AppProject의 권한 제한은 Git 쓰기 권한과 Argo CD 사용자 RBAC 설정을 대신하지 않는다.

## 로컬 확인

```sh
kubectl kustomize bootstrap
kubectl kustomize bootstrap/argocd
kubectl kustomize manifests/infra/platform
git diff --check
```

첫 명령은 Application 1개와 AppProject 4개를 렌더링한다.
두 번째 명령은 고정 버전의 공식 매니페스트를 가져오므로 GitHub 연결이 필요하다.
렌더링 검증과 실제 클러스터의 기동·동기화 검증은 별도로 수행한다.

## 참고

- [Argo CD installation](https://argo-cd.readthedocs.io/en/stable/operator-manual/installation/)
- [Argo CD v3.6.1](https://github.com/argoproj/argo-cd/releases/tag/v3.6.1)
- [Declarative setup](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/)
- [Projects](https://argo-cd.readthedocs.io/en/stable/user-guide/projects/)
