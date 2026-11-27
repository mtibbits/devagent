# shellcheck shell=bash
# tests/lib/stuck-forms.bash — #909: the one home of the pre-#909 STUCK header
# forms and of the unified header's Created: regex. A pure function layer: source
# it with `. "$BATS_TEST_DIRNAME/lib/stuck-forms.bash"`, never with `load`, so it
# stays out of lib_setup_layers.bats's hermetic-env census.

# The forms a STUCK written before #909 may have on disk; readers accept each.
STUCK_OLD_FORMS=(cs sh sh-nolg)

# The unified header's `Created:` (date -Iseconds: zone always as ±HH:MM, never
# Z, also under the suite's TZ=UTC).
STUCK_CREATED_RE='^Created:     [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$'

# stuck_old_form <form> <file> <N> <name> <reason> <lg-N> <lg-name>
# Writes <file> as a pre-#909 writer did; <lg-N>/<lg-name> are ignored by sh-nolg.
#   cs      checklist-stuck.sh@eb60c515:72-77
#   sh      stuck.sh@eb60c515:62-69, a last good found
#   sh-nolg stuck.sh before 48348c5c, none found (the line omitted)
stuck_old_form() {
  local form="$1" file="$2" n="$3" name="$4" reason="$5" lgn="$6" lgname="$7"
  case "$form" in
    cs)
      printf 'Step:        %s %s\nReason:      %s\nLast good:   %s %s\nCreated:     2026-11-04T08:47:12-05:00\n' \
        "$n" "$name" "$reason" "$lgn" "$lgname" > "$file" ;;
    sh)
      printf 'Step:        %s %s\nReason:      %s\nLast good:   step %s %s\nCreated:     2026-11-04 08:47\n' \
        "$n" "$name" "$reason" "$lgn" "$lgname" > "$file" ;;
    sh-nolg)
      printf 'Step:        %s %s\nReason:      %s\nCreated:     2026-11-04 08:47\n' \
        "$n" "$name" "$reason" > "$file" ;;
    *)
      echo "stuck_old_form: unknown form '$form'" >&2
      return 2 ;;
  esac
}
