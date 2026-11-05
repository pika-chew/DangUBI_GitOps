# Argo CD bootstrap

## 구성

- `bootstrap/argocd/`: Argo CD v3.6.1 공식 설치 매니페스트를 참조한다.
  초기 구성은 non-HA이며, Argo CD 자체의 고가용성 전환은 별도 작업이다.
- `bootstrap/`: AppProject 4개와 부모 Application `dangubi-root`를 등록한다.
- 부모는 이 레포의 `main` 브랜치에 있는 `apps/`를 재귀적으로 감시한다.
  기능 브랜치의 변경은 `main` 병합 후 반영된다.
- 현재 `apps/`에는 `.gitkeep`만 있으므로 하위 Application은 아직 생성되지 않는다.

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
이 단계에서는 `argocd`만 생성한다. 업무·데이터 네임스페이스와 쿼터는
다음 단계의 `manifests/infra/platform/`에서 작성한다.

하위 Application에는 위 표의 `spec.project`와 `spec.destination.namespace`를 지정한다.
업무와 데이터 프로젝트는 클러스터 범위 리소스 및 ResourceQuota·LimitRange 변경을 허용하지 않는다.
AppProject 이름에 `dangubi-`를 붙여 다른 프로젝트와 구분한다.

현재 모든 프로젝트의 `sourceRepos`는 이 GitOps 레포만 허용한다.
외부 Helm chart를 도입할 때 해당 프로젝트에 정확한 chart 저장소 URL을 추가한다.
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
