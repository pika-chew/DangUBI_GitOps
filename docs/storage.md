# Cinder CSI와 스토리지

## 구성 범위

- `apps/infra/cinder-csi.yaml`: 공식 chart `openstack-cinder-csi` 2.36.5를 사용한다.
  이 chart의 기본 드라이버 이미지는 v1.36.0이며 Kubernetes 1.36과 같은 minor 버전이다.
- `helm/cinder-csi/values.yaml`: 전용 Secret 참조, Worker의 controller 2개와 node DaemonSet을 설정한다.
- `apps/infra/storage.yaml`: StorageClass와 Kafka·MongoDB의 정적 local PV를 별도 Application으로 관리한다.
- MySQL의 백엔드별 StorageClass는 별도로 구성한다.

| StorageClass | 용도 | 프로비저닝 | PVC 삭제 후 |
| --- | --- | --- | --- |
| `cinder-retain` | Cinder 동적 볼륨 | Cinder CSI | PV·볼륨 보존 |
| `local-retain` | Worker 로컬 디스크 | 정적 PV 별도 생성 | PV·데이터 보존 |
| `local-kafka` | Kafka 브로커 전용 | Worker별 정적 PV | PV·데이터 보존 |
| `local-mongodb` | MongoDB 멤버 전용 | Worker별 정적 PV | PV·데이터 보존 |

네 클래스 모두 기본값으로 지정하지 않는다. PVC에 `storageClassName`을 명시한다.
`WaitForFirstConsumer`는 Pod 배치 조건을 고려하도록 바인딩·볼륨 생성을 늦춘다.
PVC만 생성한 시점의 `Pending`은 이 모드에서 반드시 오류를 의미하지는 않는다.
`cinder-retain`은 확장을 허용하지만 실제 Cinder 백엔드와 파일시스템의 지원 여부를 확인해야 한다.
local PV의 용량 변경과 노드 간 데이터 이동은 자동 처리되지 않는다.

공통 Cinder 클래스에는 미확인 `availability`·`type`·`allowedTopologies`를 지정하지 않는다.
MySQL A/B의 물리 백엔드 분리를 보장하는 클래스가 아니므로 해당 용도로 사용하기 전에
Cinder/Nova AZ, volume type과 실제 백엔드 배치를 확인해 별도 클래스를 작성한다.
local PV는 노드별 실제 마운트 경로·용량과 nodeAffinity를 확인한 뒤 추가한다.

## 인증 정보 준비

기존 CCM의 `dangubi-openstack-cloud-config`는 reader 자격 증명을 사용한다.
CSI에는 Cinder 볼륨 생성·삭제·확장과 Nova의 연결·분리에 필요한 권한을 가진
전용 Application Credential을 준비한다. 권한은 실제 OpenStack 정책에 맞춰 부여한다.
CCM Secret은 수정·복제하지 않고 CSI 전용 Secret `kube-system/dangubi-cinder-cloud-config`를 사용한다.

클러스터 관리자 kubeconfig가 있는 Control Plane에서 다음 함수를 정의해 사용한다.

```sh
kctl() { sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf "$@"; }
```

Git에서 제외되는 `.secrets/cinder-cloud.conf`에 접근 권한을 제한해 다음 형식으로 실제 값을 저장한다.
ID와 Secret의 실제 값은 Git에 커밋하지 않는다.

```ini
[Global]
auth-url = http://10.10.0.10:5000
region = RegionOne
application-credential-id = <CSI 전용 ID>
application-credential-secret = <CSI 전용 Secret>
```

```sh
chmod 600 .secrets/cinder-cloud.conf
kctl -n kube-system create secret generic dangubi-cinder-cloud-config \
  --from-file=cloud.conf=.secrets/cinder-cloud.conf \
  --dry-run=client -o yaml | kctl apply -f -
kctl -n kube-system get secret dangubi-cinder-cloud-config
```

Secret 생성 예시는 GitOps 레포 루트를 기준으로 한다.
Keystone 인증뿐 아니라 Nova·Cinder API 도달성과 실제 볼륨 조작 권한도 확인한다.
자격 증명을 교체하면 controller와 node DaemonSet을 순차적으로 재시작한다.
향후 HTTPS·사설 CA를 사용하면 CA 마운트와 `ca-file`을 함께 설정한다.

## 최초 동기화와 확인

기존 Cinder CSI 설치가 있으면 관리 도구와 릴리스를 먼저 확인한다.
이 chart에는 고정 이름의 ClusterRole과 ServiceAccount가 있으므로 중복 설치하지 않는다.

변경이 `main`에 반영돼야 root가 감지한다. `bootstrap/infra-project.yaml`에는 chart 저장소를
허용 목록에 추가했으므로 기존 설치 환경에서는 해당 파일을 먼저 재적용한다.

```sh
kctl apply -f bootstrap/infra-project.yaml
kctl -n argocd get applications
kctl -n kube-system rollout status deployment/cinder-csi-controllerplugin --timeout=300s
kctl -n kube-system rollout status daemonset/cinder-csi-nodeplugin --timeout=300s
kctl get csidriver cinder.csi.openstack.org
kctl get csinodes
kctl get nodes -L topology.cinder.csi.openstack.org/zone
kctl get storageclass cinder-retain local-retain local-kafka local-mongodb
```

controller는 서로 다른 Worker에 2개, node plugin은 Worker 4대에 1개씩 실행한다.
Control Plane에는 node plugin을 배치하지 않으므로 그곳에서 Cinder PVC를 사용하는 Pod를 실행하지 않는다.
sync wave는 자식 Application 등록 순서이며 CSI의 Ready 대기를 보장하지 않는다.
controller·node plugin이 실제 Ready인지 확인한 뒤 PVC 검증을 진행한다.

Snapshot은 비활성화했다. 공통 snapshot-controller와 Snapshot CRD를 도입할 때 다시 설정한다.
두 Application은 자동 prune과 삭제 finalizer를 사용하지 않으며,
StorageClass에도 `Prune=false,Delete=false`를 지정한다.
Retain은 백업이나 직접적인 PV·OpenStack 볼륨 삭제를 막는 기능을 대신하지 않는다.

## 실제 볼륨 검증

StorageClass 생성과 CSI Pod Ready만으로 볼륨 조작 성공을 확인할 수는 없다.
다음 항목은 실제 클러스터에서 별도로 확인한다.

1. `cinder-retain` 테스트 PVC와 이를 사용하는 Worker의 Pod를 생성한다.
   `dangubi-data`의 Pod에는 CPU·메모리 requests와 메모리 limits를 지정한다.
2. PVC가 `Bound`이고 Pod에서 실제 쓰기·읽기가 가능한지 확인한다.
3. Pod를 다시 생성해 같은 PVC의 데이터가 보존되는지 확인한다.
4. 테스트 Pod와 PVC를 삭제하고 Retain으로 남는 PV·Cinder 볼륨 ID를 확인한다.
   불필요한 테스트 PV·볼륨은 데이터를 확인한 뒤 개별적으로 정리한다.

## Kafka local PV 준비와 확인

Kafka는 `local-kafka`의 `10Gi` PVC를 3개 요청한다. `k8s-worker-2`·`k8s-worker-3`·`k8s-worker-4`의
`/mnt/data/kafka`를 각각 PV 하나에 연결한다. PV에 선언한 `10Gi`는 PVC 매칭 용량이다.
디렉터리가 기존 OS 디스크에 있으면 실제 사용량은 제한되지 않으므로 디스크 여유를 감시한다.

동기화 전에 Control Plane에서 세 노드의 `kubernetes.io/hostname` 값과 `Ready` 상태를 확인한다.

```sh
kctl get nodes k8s-worker-2 k8s-worker-3 k8s-worker-4 -L kubernetes.io/hostname
```

각 Worker에서 경로가 새 Kafka 전용 디렉터리인지 확인한 뒤 아래를 실행한다.
경로가 이미 있으면 기존 데이터와 소유권을 먼저 확인한다.

```sh
sudo install -d -o 1001 -m 0750 /mnt/data/kafka
stat -c '%n %u:%g %a' /mnt/data/kafka
df -hT /mnt/data/kafka
```

`main` 반영과 `dangubi-storage` 동기화 후 PV를 확인한다. Kafka Pod가 스케줄될 때 PVC가
각 PV에 바인딩되며, PV의 노드가 장애를 일으키면 해당 볼륨은 다른 노드로 이동하지 않는다.

```sh
kctl get pv -l app.kubernetes.io/component=kafka
kctl -n dangubi-data get pvc,pod -l strimzi.io/cluster=dangubi-kafka -o wide
```

## MongoDB local PV 준비와 확인

`k8s-worker-1`·`k8s-worker-2`·`k8s-worker-4`의 `/mnt/data/mongodb`를 각각 PV 하나에 연결한다.
MongoDB를 배포할 때는 멤버별 PVC의 `storageClassName`을 `local-mongodb`, 요청 용량을 `20Gi`로 맞춘다.
`20Gi`는 초기 검증용 PVC 매칭 용량이며, 공유 OS 디스크의 실제 사용량은 제한하지 않는다.

동기화 전에 노드의 `kubernetes.io/hostname` 라벨과 `Ready` 상태를 확인한다.
각 Worker에 MongoDB 전용 디렉터리를 준비하고, 배포에 사용할 이미지의 실행 UID·GID와 Pod 보안 설정에
맞춰 쓰기 권한을 설정한다. Kafka가 함께 배치된 Worker 2·4에서는 두 서비스의 디스크 사용량을 함께 확인한다.

```sh
kctl get nodes k8s-worker-1 k8s-worker-2 k8s-worker-4 -L kubernetes.io/hostname
kctl get pv -l app.kubernetes.io/component=mongodb
```

MongoDB를 배포한 후 멤버별 PVC가 각각 다른 PV에 바인딩되고, 데이터 디렉터리에 쓰기가 가능한지 확인한다.

## 로컬 검증

```sh
helm repo add openstack https://kubernetes.github.io/cloud-provider-openstack
helm repo update openstack
helm pull openstack/openstack-cinder-csi --version 2.36.5 --untar --untardir .cache
helm lint .cache/openstack-cinder-csi --kube-version 1.36.5 \
  --values helm/cinder-csi/values.yaml
helm template cinder-csi .cache/openstack-cinder-csi \
  --namespace kube-system --kube-version 1.36.5 --values helm/cinder-csi/values.yaml
kubectl kustomize manifests/infra/storage
git diff --check
```

## 참고

- [Cinder CSI chart 2.36.5](https://github.com/kubernetes/cloud-provider-openstack/tree/openstack-cinder-csi-2.36.5/charts/cinder-csi-plugin)
- [Cinder CSI 설정](https://github.com/kubernetes/cloud-provider-openstack/blob/master/docs/cinder-csi-plugin/using-cinder-csi-plugin.md)
- [Kubernetes StorageClass](https://kubernetes.io/docs/concepts/storage/storage-classes/)
