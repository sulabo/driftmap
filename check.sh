#!/usr/bin/env bash
# CONCEPTS.md 기계 검사. 사람 판단이 필요 없는 것만 본다.
#   check.sh <CONCEPTS.md 경로>
# 종료코드: 0 = 지적 없음, 1 = 지적 있음, 2 = 못 돌림
set -uo pipefail
F="${1:-}"
if [ -z "$F" ]; then
  echo "사용법: check.sh <CONCEPTS.md 경로>" >&2
  echo "  예: check.sh \"\$PWD/CONCEPTS.md\"" >&2
  echo "  CONCEPTS.md 위치를 모르면: find . -name CONCEPTS.md -not -path \"*/node_modules/*\"" >&2
  exit 2
fi
[ -f "$F" ] || { echo "그 경로에 파일이 없다: $F" >&2; exit 2; }
DIR=$(cd "$(dirname "$F")" && pwd)
ROOT=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || echo "$DIR")
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0

echo "검사 대상: $(basename "$(dirname "$F")")/$(basename "$F")"
echo "저장소 루트: $(basename "$ROOT")"
echo

grep -o '^## [0-9]\{1,\}\.' "$F" | grep -o '[0-9]\{1,\}' | sort -n | uniq > "$T/body"
CN=$(wc -l < "$T/body" | tr -d ' ')

# ── 1. 요약표 행 ↔ 본문 절
echo "[1] 요약표와 본문 절이 일대일인가"
grep '^| *[0-9]\{1,\} *|' "$F" | sed 's/^| *\([0-9]\{1,\}\) *|.*/\1/' | sort -n | uniq > "$T/tbl"
if [ ! -s "$T/tbl" ]; then
  ROWS=$(awk '/^\| /{if($0 !~ /^\| *[-: ]*\|/) c++} END{print c+0}' "$F")
  echo "    번호 열 없는 표 — 행 수로만 대조: 표 $((ROWS-1))행 vs 본문 ${CN}절"
  [ "$((ROWS-1))" -ne "$CN" ] && { echo "    행 수 불일치 (이름으로 직접 대조 필요)"; N=$((N+1)); }
else
  while read -r n; do grep -qx "$n" "$T/body" || { echo "    표에만 있고 본문 절 없음: 개념 $n"; N=$((N+1)); }; done < "$T/tbl"
  while read -r n; do grep -qx "$n" "$T/tbl"  || { echo "    본문에만 있고 표에 없음: 개념 $n"; N=$((N+1)); }; done < "$T/body"
fi

# ── 2. 근거 경로가 신선도 계산에 쓸 수 있는 형태인가
echo "[2] 근거 경로가 신선도 계산에 쓸 수 있는가"
grep -o '`[A-Za-z0-9_./-]\{1,\}\.[a-z][a-z0-9]\{0,\}:[0-9][0-9,~-]*`' "$F" \
  | tr -d '`' | cut -d: -f1 | sort -u > "$T/paths"
: > "$T/bad"
while read -r p; do
  # 루트 상대로 추적되면 통과 — 신선도 계산이 된다
  git -C "$ROOT" ls-files --error-unmatch "$p" >/dev/null 2>&1 && continue
  HIT=$(git -C "$ROOT" ls-files "*/$p" 2>/dev/null | head -1)
  if [ -n "$HIT" ]; then
    echo "    경로 누락: \`$p\` → 루트 상대로는 \`$HIT\`" >> "$T/bad"
  elif [ -e "$ROOT/$p" ] || [ -e "$DIR/$p" ]; then
    echo "    미추적(중첩 저장소): \`$p\` — 그 저장소에서 따로 git log를 돌려야 함" >> "$T/bad"
  else
    DISK=$(find "$ROOT" -name "*$(basename "$p")" -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null | head -1)
    if [ -n "$DISK" ]; then
      REL=${DISK#$ROOT/}
      if git -C "$ROOT" ls-files --error-unmatch "$REL" >/dev/null 2>&1; then
        echo "    약칭: \`$p\` → 실제 파일은 \`$REL\`" >> "$T/bad"
      else
        echo "    미추적(중첩 저장소): \`$p\` → \`$REL\` — 그 저장소에서 따로 봐야 함" >> "$T/bad"
      fi
    else
      echo "    끊어진 참조: \`$p\` — 같은 이름의 파일이 저장소에 없다" >> "$T/bad"
    fi
  fi
done < "$T/paths"
TOT=$(wc -l < "$T/paths" | tr -d ' ')
if [ -s "$T/bad" ]; then
  sort "$T/bad"
  BC=$(wc -l < "$T/bad" | tr -d ' ')
  echo "    → 근거 ${TOT}개 중 ${BC}개가 그대로는 신선도 계산 불가"
  N=$((N+BC))
else
  echo "    지적 없음 (${TOT}개 전부 루트 상대로 추적됨)"
fi

# ── 3. 개념 간 참조가 양방향인가
echo "[3] 개념 사이 참조가 양방향인가"
python3 - "$F" > "$T/edges" <<'PYEOF'
import re, sys, io
src = io.open(sys.argv[1], encoding="utf-8").read().splitlines()
cur, out = None, set()
# "개념 12", "개념 1·3", "개념 5·6·7" 만 잡는다. 뒤에 붙는 일반 · 구분자는 안 먹는다.
REF = re.compile(r"개념\s*(\d{1,2}(?:\s*[·،,]\s*\d{1,2})*)")
SEC = re.compile(r"^##\s*(\d{1,2})\.")
for ln in src:
    m = SEC.match(ln)
    if m: cur = m.group(1); continue
    if not cur: continue
    for g in REF.findall(ln):
        for t in re.split(r"[·،,]", g):
            t = t.strip()
            if t and t != cur: out.add((cur, t))
for a, b in sorted(out, key=lambda x: (int(x[0]), int(x[1]))):
    print(a, b)
PYEOF
: > "$T/one"
while read -r a b; do grep -qx "$b $a" "$T/edges" || echo "    한쪽만: 개념 $a 가 개념 $b 를 가리키는데 그쪽에 역참조 없음" >> "$T/one"; done < "$T/edges"
OC=$(wc -l < "$T/one" | tr -d ' '); [ "$OC" -gt 0 ] && cat "$T/one"
echo "    참조 $(wc -l < "$T/edges" | tr -d ' ')건 · 한쪽만 ${OC}건"
N=$((N+OC))

# ── 4. 상태 어휘 (상태를 적는 자리만 본다. 본문 산문은 보지 않는다)
echo "[4] 닫힌 상태 어휘 밖의 말을 쓰는가"
# 메타 줄의 상태= 필드 + 요약표의 상태 열만 추출
{ grep -o '상태=[^·]*' "$F" | sed 's/상태=//'
  awk -F'|' '/^\| *\**[0-9]+\** *\|/ {gsub(/^ +| +$/,"",$4); if($4!="") print $4}' "$F"
} | sed 's/ *$//' | grep -v '^$' | sort -u > "$T/states"
BAD=0
while read -r st; do
  case "$st" in
    일치|미구현|낡은\ 문서|미결|중복\ 정본|확인\ 못\ 함) ;;
    해소됨*|폐기됨*|없음*|규칙*) ;;
    *) echo "    닫힌 어휘 밖: '$st'"; BAD=$((BAD+1));;
  esac
done < "$T/states"
if [ "$BAD" -eq 0 ]; then echo "    지적 없음 ($(wc -l < "$T/states" | tr -d ' ')종 확인)"; else N=$((N+BAD)); fi

# ── 4b. 파일 항목에 지침·결정 파일이 섞였는가
echo "[4b] '파일' 항목이 실제 동작 근거만 담고 있는가"
grep -n '^- \*\*메타\*\*:' "$F" | grep -o '파일=[^·]*' > "$T/files" 2>/dev/null || : > "$T/files"
MIXN=$(grep -c 'AGENTS\.md\|DECISIONS\.md\|CLAUDE\.md\|TODO\.md' "$T/files" || true)
if [ "${MIXN:-0}" -gt 0 ]; then
  echo "    지침·결정 파일이 섞인 개념 ${MIXN}개 — 신선도 신호가 망가진다"
  grep -o 'AGENTS\.md\|DECISIONS\.md\|CLAUDE\.md\|[^,`]*TODO\.md' "$T/files" | sort | uniq -c | sed 's/^/      /'
  N=$((N+MIXN))
else
  echo "    지적 없음"
fi

# ── 5. 메타 줄
echo "[5] 메타 줄 (신선도 계산의 전제)"
MT=$(grep -c '^- \*\*메타\*\*:' "$F")
echo "    개념 ${CN}개 중 메타 줄 ${MT}개"
[ "$MT" -lt "$CN" ] && N=$((N+1))

echo
echo "지적 총 ${N}건"
[ "$N" -gt 0 ] && exit 1 || exit 0
