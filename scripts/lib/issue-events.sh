#!/usr/bin/env bash
# issue-events.sh — the #712 record contract for the optional read-only
# issue-backend verbs `events`, `events --kinds` and `comment-records`
# (spec §9.3.1). Source-only; do not execute. Sourced by the backends that
# implement the verbs (scripts/issue/github.sh) and by tests; no caller reads
# it yet.
#
# BC_EVENTS_JQ holds jq defs, prepended to a backend's jq program:
#   bc_rec_check  validate one record object, else error (jq exits 5)
#   bc_rec        one record object → one six-field @tsv line
#   bc_rec_sort   sort an array of records, dropping exact numeric-seq dupes
#   bc_crec_check, bc_crec   the same for one comment-records object
#   bc_tsv_unescape   reverse @tsv's five escapes for one field
# A record object is
#   {time, seq, actor, atype, kind, detail}
# with seq a non-negative integer or "?", and detail an array of zero, one or
# two parts that bc_rec joins with one space. For deleted-comment both parts
# are ids; for labeled, unlabeled and transitioned the second part is a name.
# A comment-records object is
#   {id, author, atype, created, last_edited (time or null), body}.

# shellcheck disable=SC2016  # jq programs, not shell
BC_EVENTS_JQ='
def bc_kinds: ["created","edited-title","edited-body","edited-comment","deleted-comment","labeled","unlabeled","transitioned","assigned","unassigned","commented"];
def bc_atypes: ["user","bot","app","customer","?"];
def bc_is_time: type == "string" and test("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\\z");
def bc_is_id: tostring | test("\\A[^ \\t\\r\\n]+\\z");
def bc_is_actor: tostring | test("\\A([A-Za-z0-9:._-]+|\\?)\\z");
def bc_is_seq: tostring | test("\\A([0-9]+|\\?)\\z");
def bc_detail_ok($k):
  if ($k == "created" or $k == "edited-title" or $k == "edited-body") then length == 0
  elif $k == "deleted-comment" then length == 2 and (.[0] | bc_is_id) and (.[1] | bc_is_id)
  elif ($k == "labeled" or $k == "unlabeled" or $k == "transitioned") then
    length == 2 and (.[0] | bc_is_id) and (.[1] | type == "string")
  else length == 1 and (.[0] | bc_is_id) end;
def bc_rec_check:
  if (.time | bc_is_time) and (.seq | bc_is_seq) and (.actor | bc_is_actor)
     and (.atype as $a | bc_atypes | index([$a]) != null)
     and (.kind as $k | bc_kinds | index([$k]) != null)
     and (.kind as $k | .detail | type == "array" and bc_detail_ok($k))
  then . else error("bc_rec_check: malformed record: \(tojson)") end;
def bc_rec: [.time, (.seq | tostring), (.actor | tostring), .atype, .kind, (.detail | map(tostring) | join(" "))] | @tsv;
def bc_rec_sort:
  sort_by([.time, (if .seq == "?" then -1 else .seq end), .kind, (.detail | map(tostring)), (.actor | tostring), .atype])
  | reduce .[] as $r ([]; if $r.seq != "?" and length > 0 and .[-1] == $r then . else . + [$r] end);
def bc_crec_check:
  if (.id | bc_is_id) and (.author | bc_is_actor)
     and (.atype as $a | bc_atypes | index([$a]) != null)
     and (.created | bc_is_time) and (.last_edited == null or (.last_edited | bc_is_time))
     and (.body | type == "string")
  then . else error("bc_crec_check: malformed comment record: \(tojson)") end;
def bc_crec: [(.id | tostring), (.author | tostring), .atype, .created, (.last_edited // ""), .body] | @tsv;
def bc_tsv_unescape:
  explode
  | reduce .[] as $c ({out: [], esc: false};
      if .esc then
        .esc = false
        | if $c == 116 then .out += [9]
          elif $c == 110 then .out += [10]
          elif $c == 114 then .out += [13]
          elif $c == 92 then .out += [92]
          elif $c == 48 then .out += [0]
          else error("bc_tsv_unescape: unknown escape \\\([$c] | implode)") end
      elif $c == 92 then .esc = true
      else .out += [$c] end)
  | if .esc then error("bc_tsv_unescape: trailing backslash") else .out | implode end;
'

# bc_rec_parse — the reference parse (D-e): bc_rec lines on stdin → one JSON
# object per kept line, {time, seq, actor, atype, kind, detail, id, rest}, with
# detail split on its first space only (id = before, rest = after or null).
# A line without exactly six TAB-separated fields is dropped; a field with an
# unknown escape makes jq exit 5. Never parse records with Bash `read`: TAB is
# IFS whitespace, so an empty field collapses.
bc_rec_parse() (
  set -o pipefail
  awk -F'\t' 'NF==6' | jq -cR "$BC_EVENTS_JQ"'
    split("\t") | map(bc_tsv_unescape)
    | {time: .[0], seq: .[1], actor: .[2], atype: .[3], kind: .[4], detail: .[5]}
    | (.detail | split(" ")) as $p
    | .id = $p[0] | .rest = (if ($p | length) > 1 then $p[1:] | join(" ") else null end)' \
    | tr -d '\r'
)

# bc_events_coverage <script> <repo> <kind> — what <script>'s `events --kinds
# <repo>` declares for <kind> (D-h). Prints `unsupported` when the backend
# answers 78 or 2 or omits the kind, else its coverage word; exit 0. Exit 1
# when the script is missing or not executable, exits otherwise, or prints a
# line that is not `<kind> TAB <coverage>` in table order: a broken install is
# never read as unsupported.
bc_events_coverage() {
  local script="$1" repo="$2" kind="$3" out rc=0 line want_re k cov="" kinds
  local -a order=(created edited-title edited-body edited-comment deleted-comment labeled unlabeled transitioned assigned unassigned commented)
  local -A rank=()
  local pos=-1 i
  for i in "${!order[@]}"; do rank[${order[$i]}]=$i; done
  if [ ! -f "$script" ] || [ ! -x "$script" ]; then
    echo "bc_events_coverage: $script is missing or not executable" >&2
    return 1
  fi
  out="$("$script" events --kinds "$repo")" || rc=$?
  case "$rc" in
    0) ;;
    2|78) echo unsupported; return 0 ;;
    *) echo "bc_events_coverage: $script events --kinds exited $rc" >&2; return 1 ;;
  esac
  printf -v kinds '%s|' "${order[@]}"
  want_re="^(${kinds%|})"$'\t''(full|last-edit-only|actor-unknown|detail-unknown)$'
  while IFS= read -r line; do
    if [[ ! "$line" =~ $want_re ]]; then
      echo "bc_events_coverage: $script: malformed --kinds line: $line" >&2
      return 1
    fi
    k="${BASH_REMATCH[1]}"
    i="${rank[$k]}"
    if [ "$i" -le "$pos" ]; then
      echo "bc_events_coverage: $script: --kinds line out of order or repeated: $k" >&2
      return 1
    fi
    pos=$i
    [ "$k" = "$kind" ] && cov="${BASH_REMATCH[2]}"
  done <<< "$out"
  echo "${cov:-unsupported}"
}
