#!/usr/bin/env bash
# 모드 ④ 신선도 점검. 메타 줄을 읽어 개념별로 재확인 대상인지 계산한다.
#   fresh.sh <CONCEPTS.md 경로> [저장소 루트]
set -uo pipefail
F="${1:-}"
if [ -z "$F" ]; then
  echo "사용법: fresh.sh <CONCEPTS.md 경로> [저장소 루트]" >&2
  echo "  예: fresh.sh \"$PWD/CONCEPTS.md\"" >&2
  exit 2
fi
[ -f "$F" ] || { echo "그 경로에 파일이 없다: $F" >&2; exit 2; }
DIR=$(cd "$(dirname "$F")" && pwd)
ROOT="${2:-$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || echo "$DIR")}"
META=$(grep -c '^- \*\*메타\*\*:' "$F" | tr -cd '0-9'); META=${META:-0}
CONC=$(grep -c '^## [0-9]\{1,\}\.' "$F" | tr -cd '0-9'); CONC=${CONC:-0}
if [ "$META" -eq 0 ]; then
  echo "메타 줄이 하나도 없다 (개념 ${CONC}개). **신선도를 계산할 수 없다 — 0건이 아니라 못 셌다.**"
  echo
  echo "먼저 개념마다 제목 아래에 이 줄을 넣는다:"
  echo '  - **메타**: 상태=… · 확인=YYYY-MM-DD(`해시`) · 파일=`루트상대경로` · 이웃=…'
  echo
  echo "해시를 모르면 확인=YYYY-MM-DD(해시 미상)으로 두고 나중에 채운다."
  echo "파일이 없는 규칙 개념이면 파일=없음(규칙 개념)."
  exit 2
fi
[ "$META" -lt "$CONC" ] && echo "주의: 개념 ${CONC}개 중 메타 줄 ${META}개. 나머지는 표에 안 나온다." && echo
printf "%-4s %-22s %-12s %s\n" "#" "개념" "상태" "판정"
printf -- "---- ---------------------- ------------ ------------------------------\n"
STALE=0; FRESH=0

python3 - "$F" <<'PYEOF' | while IFS='|' read -r num name state hash files; do
import re, sys, io
src = io.open(sys.argv[1], encoding="utf-8").read().splitlines()
num = name = None
for ln in src:
    m = re.match(r"^##\s*(\d{1,2})\.\s*(.+)$", ln)
    if m:
        num, name = m.group(1), m.group(2).split("—")[0].strip()[:20]; continue
    if num and ln.startswith("- **메타**:"):
        g = lambda k: (re.search(k + r"=([^·\n]+)", ln) or [None, ""])[1].strip()
        print("|".join([num, name, g("상태") or "?", g("확인"), g("파일")]))
        num = None
PYEOF
  H=$(echo "$hash" | grep -o '[0-9a-f]\{7,40\}' | head -1)
  FS=$(echo "$files" | tr -d '`' | tr ',' ' ')
  if [ -z "$H" ]; then printf "%-4s %-22s %-12s %s\n" "$num" "$name" "$state" "재확인 필요 — 기준 없음"; continue; fi
  git -C "$ROOT" cat-file -e "$H" 2>/dev/null || { printf "%-4s %-22s %-12s %s\n" "$num" "$name" "$state" "재확인 필요 — 기준 소실"; continue; }
  case "$files" in
    *없음*) printf "%-4s %-22s %-12s %s\n" "$num" "$name" "$state" "규칙 개념 — 결정 변동으로만 추적"; continue;;
  esac
  OK=""; BAD=""; GONE=""
  for f in $FS; do
    # 파일이든 디렉터리든 추적 대상이 하나라도 있으면 통과
    if [ "$(git -C "$ROOT" ls-files "$f" 2>/dev/null | head -1)" != "" ]; then OK="$OK $f"; continue; fi
    [ -e "$ROOT/$f" ] && BAD="$BAD $f" || GONE="$GONE $f"
  done
  if [ -z "$OK" ]; then
    [ -n "$BAD" ] && printf "%-4s %-22s %-12s %s\n" "$num" "$name" "$state" "재확인 필요 — 미추적" \
                  || printf "%-4s %-22s %-12s %s\n" "$num" "$name" "$state" "재확인 필요 — 경로 소실"
    continue
  fi
  C=$(git -C "$ROOT" log --oneline "$H"..HEAD -- $OK 2>/dev/null | wc -l | tr -d ' ')
  EXTRA=""
  [ -n "$BAD" ] && EXTRA=" (미추적 $(echo $BAD | wc -w | tr -d ' ')개 제외)"
  [ -n "$GONE" ] && EXTRA="$EXTRA (경로 소실 $(echo $GONE | wc -w | tr -d ' ')개)"
  if [ "$C" -gt 0 ]; then printf "%-4s %-22s %-12s %s\n" "$num" "$name" "$state" "재확인 필요 — 커밋 ${C}건${EXTRA}"
  else printf "%-4s %-22s %-12s %s\n" "$num" "$name" "$state" "신선${EXTRA}"; fi
done

# ── 결정이 움직였는가 (전역 1회, 형식 자동 판별)
GOV="DECISIONS.md AGENTS.md CLAUDE.md"
OLDEST=$(grep -o '확인=[^(]*(`[0-9a-f]\{7,40\}`' "$F" | grep -o '[0-9a-f]\{7,40\}' | while read h; do
  git -C "$ROOT" log --format="%ct $h" -1 "$h" 2>/dev/null; done | sort -n | head -1 | awk '{print $2}')
echo
if [ -n "$OLDEST" ]; then
  TRACKED=""
  for g in $GOV; do [ -n "$(git -C "$ROOT" ls-files "$g" 2>/dev/null | head -1)" ] && TRACKED="$TRACKED $g"; done
  if [ -n "$TRACKED" ]; then
    DC=$(git -C "$ROOT" log --oneline "$OLDEST"..HEAD -- $TRACKED 2>/dev/null | wc -l | tr -d ' ')
    echo "결정·지침 변동: 가장 오래된 확인($OLDEST) 이후 커밋 ${DC}건"
    if [ "$DC" -gt 0 ] && [ -f "$ROOT/DECISIONS.md" ]; then
      # 형식 판별 — 프로젝트마다 다르다
      HEADN=$(grep -c '^## [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}' "$ROOT/DECISIONS.md" 2>/dev/null | head -1 | tr -cd '0-9'); HEADN=${HEADN:-0}
      TABN=$(grep -c '^| *[A-Z][A-Z]*[0-9][0-9]* *|' "$ROOT/DECISIONS.md" 2>/dev/null | head -1 | tr -cd '0-9'); TABN=${TABN:-0}
      D=$(git -C "$ROOT" diff "$OLDEST"..HEAD -- DECISIONS.md 2>/dev/null)
      if [ "$HEADN" -ge "$TABN" ] && [ "$HEADN" -gt 0 ]; then
        NEWN=$(echo "$D" | grep -c '^+## [0-9]\{4\}-')
        RELN=$(echo "$D" | grep -c '^+- 관련:')
        echo "  형식: 날짜 헤딩 · 새 결정 ${NEWN}건 · '관련:' 줄 ${RELN}건 · 구멍 $((NEWN-RELN))건"
        [ "$((NEWN-RELN))" -gt 0 ] && echo "  → 관련 줄 없는 결정은 어느 개념을 건드렸는지 알 수 없다. 갱신 경로의 구멍으로 보고한다."
      elif [ "$TABN" -gt 0 ]; then
        NEWN=$(echo "$D" | grep -c '^+| *[A-Z][A-Z]*[0-9][0-9]* *|')
        IDS=$(echo "$D" | grep '^+| *[A-Z][A-Z]*[0-9][0-9]* *|' | sed 's/^+| *\([A-Z][A-Z]*[0-9][0-9]*\) *|.*/\1/' | tr '\n' ' ')
        echo "  형식: 표(결정 ID) · 새 결정 행 ${NEWN}건${IDS:+  — $IDS}"
        echo "  → 이 형식에는 '관련:' 줄 관행이 없다. 어느 개념이 걸리는지는 ID를 개념 절에서 찾아 잇는다."
        [ "$NEWN" -gt 0 ] && for i in $IDS; do
          H=$(grep -c "$i" "$F" 2>/dev/null | head -1 | tr -cd '0-9'); H=${H:-0}
          [ "${H:-0}" -eq 0 ] && echo "     $i: 개념 지도에 언급 없음 — 어느 개념에 걸리는지 확인 필요"
        done
      else
        echo "  형식 불명 — **0건이 아니라 못 셌다.** DECISIONS.md를 직접 열어 확인한다."
      fi
      git -C "$ROOT" log --oneline "$OLDEST"..HEAD -- $TRACKED 2>/dev/null | head -4 | sed 's/^/     /'
    fi
  fi
fi

# ── 파일 항목에 지침·결정 파일이 섞여 있는가
MIX=$(grep -o '파일=[^·]*' "$F" | grep -c 'AGENTS\.md\|DECISIONS\.md\|CLAUDE\.md\|TODO\.md' || true)
if [ "${MIX:-0}" -gt 0 ]; then
  echo
  echo "경고: 개념 ${MIX}개의 '파일' 항목에 지침·결정 파일이 섞여 있다."
  echo "  그 파일들은 거의 매일 바뀌어서 실제 내용이 가만히 있어도 재확인 대상이 된다."
  echo "  '파일'에는 실제 동작 근거(코드·산출물)만 남기고, 결정 변동은 위 전역 검사로 본다."
fi
