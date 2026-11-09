---
name: manifest-outline
description: DangUBI_GitOps에서 매니페스트를 "개요 → 사용자가 직접 작성 → 검토·커밋" 순서로 만드는 워크플로. 사용자가 쿠버네티스·Argo CD 매니페스트(Application, Deployment, Rollout, CronJob, ExternalSecret, kustomization 등)의 개요·골격·뼈대·파일 구성을 짜 달라고 하거나, 직접 작성한 매니페스트를 "확인해줘", "검토해줘", "문제없는지 봐줘", "개요 주석 지우고 커밋해줘"라고 할 때 반드시 이 스킬을 먼저 읽는다. 매니페스트를 대신 완성해 달라는 명시적 요청이 없으면 상세 spec을 채우지 않는다.
---

# 매니페스트 개요 → 직접 작성 → 검토 워크플로

사용자는 매니페스트를 직접 작성하면서 구조를 이해하려 한다. 그래서 Claude의 역할은 두 가지뿐이다.

1. **개요**: 어떤 파일이 어디에 필요하고, 각 파일이 무슨 역할이며, 무엇을 채워야 하는지를 보여 준다.
2. **검토**: 사용자가 채운 결과가 맞는지 확인하고, 맞으면 개요 주석을 지우고 커밋한다.

Claude가 spec을 다 채워 버리면 사용자가 배울 기회가 사라진다. 과거에 "개요를 짜 달랬는데 매니페스트를 거의 다 만들어 버렸다"는 지적을 받은 적이 있다. 사용자가 "작성해줘", "채워줘"라고 명시하지 않는 한 개요 수준을 지킨다.

git 브랜치·커밋·PR 규칙은 `convention` 스킬을 따른다(main 직접 작업 금지, `키워드: 내용` 커밋, 단위별 커밋).

---

## 1. 개요 모드

### 시작 전에 저장소 규칙을 확인한다
개요가 저장소의 실제 규칙과 어긋나면 사용자가 그 위에 쌓은 작업이 전부 틀어진다. 파일을 만들기 전에 아래를 읽는다.

- `bootstrap/*-project.yaml`: AppProject 이름, 허용 저장소, 허용 네임스페이스, 금지 리소스
- `manifests/infra/platform/namespaces.yaml`, `resourcequotas.yaml`: 네임스페이스와 quota (quota가 있으면 모든 컨테이너에 requests·메모리 limits가 필수)
- `apps/` 아래 기존 Application: 이름 규칙(`dangubi-<이름>`), sync-wave, syncPolicy 모양
- 같은 계층의 기존 매니페스트: 리소스 이름 규칙, 라벨, 주석 스타일
- 관련 앱 저장소가 로컬에 있으면(예: `../DangUBI_CronJob`) 실행 인자·환경 변수 이름

### 파일 형식
각 파일에는 **헤더 주석 + 최소 뼈대**만 둔다.

```yaml
# <리소스 이름> (<kind>) — <스케줄 등 한눈에 필요한 값>
# - 역할: 이 리소스가 하는 일 한두 줄.
# - 설계 의도: 무엇이 개별이고 무엇을 묶는지, 왜 이렇게 나눴는지 (필요할 때만)
# - 정할 것: 아직 결정되지 않은 것 (필요할 때만)
# - 채울 것:
#   - 필드 이름과 넣을 값의 방향 (확정된 값이면 값까지)
#   - 주의점 (예: resources 필수 — dangubi ResourceQuota)
apiVersion: <group/version>
kind: <Kind>
metadata:
  name: <이름>
```

- `spec` 이하는 쓰지 않는다. `CHANGE_ME` 같은 자리표시자도 넣지 않는다. 채울 내용은 "채울 것" 목록으로 말한다.
- Application은 `metadata.namespace: argocd`까지 둔다.
- `kustomization.yaml`은 예외다. `namespace`와 `resources` 목록은 폴더 구조 자체라 실제로 쓴다. 각 항목 옆에 한 줄 주석을 단다.
- 설계 의도는 분명히 적는다. 특히 "이 리소스가 다른 리소스를 부르는지/묶는지"는 사용자가 가장 헷갈려 하는 부분이다. 예: "개별 CronJob이며 다른 CronJob을 부르지 않는다. 순서는 시간으로만 맞춘다."
- 표·목록을 받아 반영할 때도 같은 수준을 지킨다. 값(스케줄, 이름 등)은 "채울 것"에 적고 spec으로 쓰지 않는다.
- 추측한 내용은 추측이라고 쓴다("~용도로 보인다"). 확인한 사실과 섞지 않는다.

### 끝나면
1. 폴더별로 `kustomize build`가 되는지 확인한다(파일 구조 확인용).
2. 단위별로 커밋한다. push는 사용자가 요청할 때만 한다.
3. 답변에는 파일 트리, 각 파일의 역할 한 줄, 설계 의도, 사용자가 정해야 할 것을 적는다.
4. 개요 상태로 `main`에 머지되면 spec 없는 리소스 때문에 동기화가 실패한다는 점을 알린다. PR을 만들면 본문 맨 위에도 적는다.

---

## 2. 검토 모드

사용자가 "작성했는데 확인해줘"라고 하면 실행한다.

### 무엇을 봤는지 먼저 확정한다
- `git status`와 `git diff`로 사용자가 바꾼 파일과 내용을 확인한다. 에디터에 저장되지 않은 수정은 보이지 않으므로, 개요와 달라진 게 없으면 저장했는지 묻는다.
- 파일 맨 위의 개요 주석("채울 것")을 체크리스트로 쓴다. 빠진 항목은 "필수"와 "선택(넣지 않아도 동작)"으로 구분한다.

### 검증
`scripts/validate.sh <파일 또는 폴더...>`를 실행한다(경로는 이 스킬 폴더 기준). yq 문법, kustomize 렌더링, kubeconform 스키마를 한 번에 돌린다. 폴더를 넘기면 kustomization으로 렌더링한 결과를 검증하므로, 사용자가 작성한 파일이 든 폴더째 넘기는 게 좋다. 도구가 PATH에 없으면 `YQ`·`KUBECONFORM`·`KUSTOMIZE` 환경 변수로 경로를 넘기고, 아예 없으면 scratchpad에 바이너리만 받아서 쓴다(시스템 설치 금지).

kubeconform의 `missing properties: 'spec'`은 그 리소스가 아직 개요 상태(사용자가 안 채움)라는 뜻이다. 사용자가 이번에 채우지 않은 파일이면 문제로 세지 말고 "아직 개요"로 따로 알린다.

스크립트가 못 잡는 것은 직접 확인한다.

| 확인 | 방법 |
| --- | --- |
| AppProject 허용 | Application의 `project`·`repoURL`·`destination.namespace`가 해당 AppProject의 `sourceRepos`·`destinations`와 문자열까지 같은지. 리소스 kind가 blacklist/whitelist에 걸리지 않는지 |
| ResourceQuota | quota가 있는 네임스페이스면 모든 컨테이너(init·사이드카, 오퍼레이터가 만드는 파드 포함)에 requests.cpu·requests.memory·limits.memory가 있는지 |
| 이름 연결 | Service selector ↔ 파드 라벨, Deployment selector ↔ template 라벨, envFrom/secretKeyRef ↔ 실제 ConfigMap·Secret 이름과 키, Rollout의 active/preview Service 이름 |
| 순서 | sync-wave가 의존 관계(DB → Kafka → Connect → 앱)와 맞는지 |
| 비밀 값 | 평문 비밀번호·토큰이 없는지. Secret 대신 ExternalSecret인지 |
| 금지 API | Strimzi는 `kafka.strimzi.io/v1`만 (`v1beta*`, `v1alpha*` 금지) |
| 앱 실행 인자 | 앱 저장소가 정한 형식과 맞는지 (예: 배치 앱은 `--spring.batch.job.name=<Job>`, args이지 command가 아님) |
| 흔한 실수 | `kubectl create --dry-run`으로 만든 YAML의 `status: {}`·`creationTimestamp: null`·빈 `resources: {}`, `--` 인자가 `command`로 들어간 것, `restartPolicy` 기본값 |

Strimzi CR은 공용 카탈로그에 v1 스키마가 없을 수 있다. 그때는 해당 버전의 CRD를 받아 `openapi2jsonschema.py`로 스키마를 만든 뒤 `--schema-location`으로 넘긴다.

### 판정에 따라 다르게 끝낸다

**문제가 없을 때**
1. 개요 헤더 주석 블록(파일 맨 위 `# <이름> (<kind>)`부터 `# - 채울 것:` 목록 끝까지)만 지운다. 사용자가 직접 쓴 주석은 남긴다.
2. 다시 검증한다.
3. `convention`에 맞춰 커밋한다. 예: `feat: fill collector argocd application`.
4. push는 요청할 때만 한다.
5. 답변: 확인한 항목 표, 넣지 않은 선택 항목과 그 영향, 커밋 해시.

**문제가 있을 때**
- 개요 주석을 지우지 않고 커밋하지도 않는다. 사용자가 고칠 차례다.
- 무엇이 왜 문제인지, 그대로 배포하면 어떻게 되는지, 어느 줄을 어떻게 고치면 되는지 알려 준다. 고친 코드를 통째로 써 주기보다 바꿀 부분을 짚어 준다.
- 사소한 것(오타, 끝 공백)은 문제와 구분해 "선택"으로 알린다.

---

## 참고: kubectl로 초안 만들기

사용자가 처음부터 쓰기 어려워하면 `kubectl create <종류> --dry-run=client -o yaml > 파일.yaml`로 초안을 만드는 방법을 알려 준다. Deployment·Service·ConfigMap·CronJob·Job은 되고, CRD(Application, Rollout, ExternalSecret, Strimzi CR)는 안 된다. CRD는 저장소의 비슷한 기존 파일을 복사해서 시작한다. 필드 뜻은 `kubectl explain <경로>`로 찾는다(클러스터 연결 필요).
