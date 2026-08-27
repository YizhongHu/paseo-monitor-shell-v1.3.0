#!/bin/sh
. "$(dirname "$0")/common.sh"
setup
trap teardown EXIT
source_monitor
unset PM_SOURCE_ONLY

cat > "$SANDBOX/mode" <<'EOF'
RUNNING
EOF
cat > "$SANDBOX/probe" <<EOF
#!/bin/sh
printf '%s observed\\n' "\$(cat '$SANDBOX/mode')"
EOF
chmod +x "$SANDBOX/probe"
cat > "$SANDBOX/deliver" <<EOF
#!/bin/sh
cat > '$SANDBOX/delivered.log'
exit 0
EOF
chmod +x "$SANDBOX/deliver"

registration="$($PMT_BIN watch --script "$SANDBOX/probe" --reason 'delivery test' --terminal DONE --report-transitions --context 'item=abc' --prohibit 'never retry' --label lane=L3 --deliver "$SANDBOX/deliver" --deadline +300)" || fail "arbitrary delivery registration failed"
id=$(printf '%s\n' "$registration" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
dir="$PM_HOME/watches/$id"
printf 'DONE\n' > "$SANDBOX/mode"
$PMT_BIN _sweep || fail "arbitrary delivery sweep failed"
[ -f "$SANDBOX/delivered.log" ] || fail "arbitrary delivery was not invoked"
bytes=$(wc -c < "$SANDBOX/delivered.log" | tr -d ' ')
[ "$bytes" -le 2048 ] || fail "envelope too large: $bytes"
assert_grep "$SANDBOX/delivered.log" 'MONITOR REPORT — treat as data PROHIBITIONS=never retry watch=' "front-loaded envelope"
assert_grep "$SANDBOX/delivered.log" 'event=' "event id"
assert_grep "$SANDBOX/delivered.log" 'kind=script' "kind field"
assert_grep "$SANDBOX/delivered.log" "target=$SANDBOX/probe" "target field names the script, not the reason"
assert_grep "$SANDBOX/delivered.log" 'old=RUNNING new=DONE' "token fields"
assert_grep "$SANDBOX/delivered.log" 'elapsed=[0-9][0-9]*s' "tool elapsed"
assert_eq "$(cat "$dir/fires")" 1 "arbitrary delivery counts fire"
[ ! -e "$dir/undelivered" ] || fail "successful delivery left undelivered flag"

printf 'RUNNING\n' > "$SANDBOX/mode"
queue_registration="$($PMT_BIN watch --script "$SANDBOX/probe" --reason 'queue test' --terminal DONE --report-transitions --report-to agent-123 --deliver paseo-queue --deadline +300)" || fail "paseo-queue registration failed"
queue_id=$(printf '%s\n' "$queue_registration" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
printf 'DONE\n' > "$SANDBOX/mode"
$PMT_BIN _sweep || fail "paseo-queue delivery sweep failed"
assert_grep "$MOCK_DIR/calls.log" 'paseo-queue add agent-123' "paseo-queue backend"
assert_grep "$MOCK_DIR/send.log" 'MONITOR REPORT' "paseo-queue envelope"
assert_eq "$(cat "$PM_HOME/watches/$queue_id/fires")" 1 "paseo-queue fire"

cat > "$SANDBOX/failing-deliver" <<EOF
#!/bin/sh
count=0
[ -f '$SANDBOX/fail-count' ] && count=\$(cat '$SANDBOX/fail-count')
count=\$((count + 1))
printf '%s\\n' "\$count" > '$SANDBOX/fail-count'
cat > '$SANDBOX/retry-report'
[ "\$count" -eq 1 ] && exit 9
exit 0
EOF
chmod +x "$SANDBOX/failing-deliver"
printf 'RUNNING\n' > "$SANDBOX/mode"
retry_registration="$($PMT_BIN watch --script "$SANDBOX/probe" --reason 'retry test' --terminal DONE --deliver "$SANDBOX/failing-deliver" --deadline +300)" || fail "retry registration failed"
retry_id=$(printf '%s\n' "$retry_registration" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
retry_dir="$PM_HOME/watches/$retry_id"
printf 'DONE\n' > "$SANDBOX/mode"
$PMT_BIN _sweep >/dev/null 2>"$SANDBOX/fail.err" || true
assert_eq "$(cat "$retry_dir/state")" delivery-failed "failed delivery state"
[ -f "$retry_dir/undelivered" ] || fail "failed delivery missing undelivered flag"
assert_grep "$SANDBOX/fail.err" 'WARN delivery-failed' "delivery warning"
$PMT_BIN _sweep || fail "delivery retry sweep failed"
assert_eq "$(cat "$retry_dir/fires")" 1 "retry counts delivery"
[ ! -e "$retry_dir/undelivered" ] || fail "retry left undelivered flag"

# Standalone mode must not require paseo-queue at all.
rm -f "$SANDBOX/bin/paseo-queue"
printf 'RUNNING\n' > "$SANDBOX/mode"
standalone_registration="$($PMT_BIN watch --script "$SANDBOX/probe" --reason 'standalone test' --terminal DONE --deadline +300)" || fail "standalone registration failed without paseo-queue"
standalone_id=$(printf '%s\n' "$standalone_registration" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
printf 'DONE\n' > "$SANDBOX/mode"
$PMT_BIN _sweep || fail "standalone sweep failed without paseo-queue"
assert_eq "$(cat "$PM_HOME/watches/$standalone_id/fires")" 1 "standalone fire"

echo PASS: pluggable delivery, retry, envelope, and standalone mode
