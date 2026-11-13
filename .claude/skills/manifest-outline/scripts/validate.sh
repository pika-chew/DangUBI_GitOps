#!/usr/bin/env bash
# 매니페스트 정적 검증: yq 문법 → kustomize 렌더링 → kubeconform 스키마.
# 사용: validate.sh <파일 또는 폴더...>
#   - 폴더에 kustomization.yaml이 있으면 렌더링 결과를 검증한다.
#   - 파일이면 그 파일을 그대로 검증한다.
# 도구 경로는 PATH 또는 환경 변수로 지정한다: YQ, KUSTOMIZE, KUBECONFORM
# Strimzi 등 공용 카탈로그에 없는 CRD 스키마는 EXTRA_SCHEMA_LOCATION으로 넘긴다.
#   예: EXTRA_SCHEMA_LOCATION='/path/schemas/{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json'
set -u

YQ="${YQ:-$(command -v yq || true)}"
KUSTOMIZE="${KUSTOMIZE:-$(command -v kustomize || true)}"
KUBECONFORM="${KUBECONFORM:-$(command -v kubeconform || true)}"

if [ $# -eq 0 ]; then
  echo "사용: $0 <파일 또는 폴더...>" >&2
  exit 2
fi

missing=()
[ -z "$YQ" ] && missing+=("yq")
[ -z "$KUBECONFORM" ] && missing+=("kubeconform")
[ -z "$KUSTOMIZE" ] && ! command -v kubectl >/dev/null 2>&1 && missing+=("kustomize(또는 kubectl)")
if [ ${#missing[@]} -gt 0 ]; then
  echo "[경고] 없는 도구: ${missing[*]} — 해당 단계는 건너뛴다."
fi

render() {
  if [ -n "$KUSTOMIZE" ]; then "$KUSTOMIZE" build "$1"; else kubectl kustomize "$1"; fi
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
fail=0
targets=()
i=0

for p in "$@"; do
  i=$((i + 1))
  if [ -d "$p" ]; then
    if [ -f "$p/kustomization.yaml" ]; then
      out="$tmpdir/render-$i.yaml"
      if render "$p" > "$out" 2> "$tmpdir/err"; then
        echo "[통과] kustomize build $p ($(grep -c '^kind:' "$out") 리소스) — 아래 메시지의 render-$i.yaml = $p"
        targets+=("$out")
      else
        echo "[실패] kustomize build $p"; sed 's/^/        /' "$tmpdir/err"; fail=1
      fi
    else
      while IFS= read -r f; do targets+=("$f"); done < <(find "$p" -maxdepth 1 -name '*.yaml' -type f)
    fi
  elif [ -f "$p" ]; then
    targets+=("$p")
  else
    echo "[실패] 없는 경로: $p"; fail=1
  fi
done

if [ -n "$YQ" ]; then
  for f in "${targets[@]}"; do
    if ! "$YQ" eval '.' "$f" > /dev/null 2> "$tmpdir/err"; then
      echo "[실패] yq 문법 $f"; sed 's/^/        /' "$tmpdir/err"; fail=1
    fi
  done
  [ $fail -eq 0 ] && echo "[통과] yq 문법 (${#targets[@]}개)"
fi

if [ -n "$KUBECONFORM" ] && [ ${#targets[@]} -gt 0 ]; then
  args=(-strict -summary -schema-location default
        -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json')
  [ -n "${EXTRA_SCHEMA_LOCATION:-}" ] && args+=(-schema-location "$EXTRA_SCHEMA_LOCATION")
  if "$KUBECONFORM" "${args[@]}" "${targets[@]}"; then
    echo "[통과] kubeconform"
  else
    echo "[실패] kubeconform (위 메시지 참고. 'could not find schema'는 CRD 스키마가 없다는 뜻)"; fail=1
  fi
fi

if grep -nE "kafka\.strimzi\.io/v1(beta|alpha)" "${targets[@]}" 2>/dev/null; then
  echo "[실패] 금지된 Strimzi API 버전"; fail=1
fi

exit $fail
