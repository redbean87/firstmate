#!/usr/bin/env bash
# Disposable live lab: REAL pi CLI + REAL fork/discord/fm-pi-reply-mirror.ts
# + REAL fork/discord/fm-discord-bridge.py tick, against a scripted Discord
# REST endpoint. Nothing here is committed; the lab directory is removed after
# the evidence turn.
set -u
LAB=$(cd "$(dirname "$0")" && pwd)
ROOT=${ROOT:?set ROOT to the run worktree}
FAKE=$LAB/fake
FAKEBIN=$LAB/fakebin
PRIMARY=$LAB/primary
PI_AGENT=$LAB/pi-agent
OUT=$LAB/out
D_GUILD=100000000000000001
D_OWNER=200000000000000002
D_CMD=300000000000000003
D_REPLIES=310000000000000031
D_OPS=400000000000000004
D_TOKEN=fixture-bot-token-not-real-0123456789

say() { printf '\n== %s\n' "$*"; }
die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
spool() { printf '%s' "$PRIMARY/state/discord-bridge/pi-replies"; }
spool_files() { find "$(spool)" -name '[0-9]*.json' 2>/dev/null | sort; }
n_events() { spool_files | grep -c . || true; }
posts() { jq -c 'select(.method == "POST") | select(.path == "/channels/'"$D_REPLIES"'/messages")
  | {content: .body.content, reply_to: (.body.message_reference.message_id // null)}' "$FAKE/requests.jsonl"; }
n_posts() { posts | grep -c . || true; }

bridge() { env FM_HOME="$PRIMARY" PATH="$FAKEBIN:$PATH" FAKE_DISCORD_DIR="$FAKE" FM_DISCORD_BRIDGE_QUIET=1 \
  DISCORD_ENV_FILE="$LAB/no-env" DISCORD_BOT_TOKEN="$D_TOKEN" DISCORD_GUILD_ID="$D_GUILD" \
  DISCORD_OWNER_USER_ID="$D_OWNER" DISCORD_COMMAND_CHANNEL_IDS="$D_CMD" \
  DISCORD_REPLIES_CHANNEL_ID="$D_REPLIES" DISCORD_OPERATIONS_CHANNEL_ID="$D_OPS" \
  DISCORD_API_BASE="https://discord.test/api/v10" DISCORD_WATCHER_STALE_SECS=999999999 \
  python3 "$ROOT/fork/discord/fm-discord-bridge.py" "$@"; }

# pi_run <root> <home> <log> <session-flag> <prompt> <extension...>
# Runs the REAL pi CLI as a child of the shell that writes state/.lock, the
# shape a live firstmate primary session has (lock names an ancestor pid).
pi_run() {
  local root=$1 home=$2 log=$3 sess=$4 prompt=$5; shift 5
  local exts=""
  local e
  for e in "$@"; do exts="$exts -e $e"; done
  env LAB_LOG="$log" LAB_PROMPT="$prompt" LAB_AGENT="$PI_AGENT" LAB_HOME="$home" \
    LAB_EXTS="$exts" LAB_PATH="$FAKEBIN:$PATH" LAB_SESSION="$sess" LAB_BG_MARKER="${LAB_BG_MARKER:-}" \
    /bin/bash -c '
      printf "%s\n" "$$" > "$LAB_HOME/state/.lock"
      # shellcheck disable=SC2086
      exec env PI_CODING_AGENT_DIR="$LAB_AGENT" FM_HOME="$LAB_HOME" PATH="$LAB_PATH" \
        pi -ne $LAB_EXTS --mode json ${LAB_SESSION:-} "$LAB_PROMPT"
    ' >"$log" 2>"$log.err"
}

# checkout <dir>: a genuine primary checkout shape (non-worktree git repo with
# AGENTS.md, bin/, and the extension at fork/discord/).
checkout() {
  local d=$1 src=$2
  mkdir -p "$d/fork/discord"
  git init -q "$d"
  : > "$d/AGENTS.md"
  ln -sfn "$ROOT/bin" "$d/bin"
  cp "$src" "$d/fork/discord/fm-pi-reply-mirror.ts"
}

if [ "${1:-setup}" = setup ]; then
  say "setup: disposable fixture primary checkout, fake Discord, isolated pi config"
  mkdir -p "$PRIMARY/state" "$PRIMARY/config" "$FAKE/get" "$FAKEBIN" "$PI_AGENT" "$OUT"
  checkout "$PRIMARY" "$ROOT/fork/discord/fm-pi-reply-mirror.ts"
  # The pre-fix extension, from the commit before this change's boundary fix.
  mkdir -p "$LAB/prefix/src"
  git -C "$ROOT" show 863b6dfc:fork/discord/fm-pi-reply-mirror.ts > "$LAB/prefix/src/fm-pi-reply-mirror.ts"
  checkout "$LAB/prefix" "$LAB/prefix/src/fm-pi-reply-mirror.ts"
  rm -rf "$LAB/prefix/src"
  cp "$ROOT/fork/tests/discord-fake-curl" "$FAKEBIN/curl"; chmod +x "$FAKEBIN/curl"
  cp "$HOME/.pi/agent/auth.json" "$PI_AGENT/auth.json"
  cp "$HOME/.pi/agent/models.json" "$PI_AGENT/models.json"
  jq '{defaultProvider, defaultModel, defaultThinkingLevel}' "$HOME/.pi/agent/settings.json" > "$PI_AGENT/settings.json"
  : > "$PRIMARY/config/supervision-host"
  : > "$PRIMARY/state/.last-watcher-beat"
  : > "$FAKE/requests.jsonl"
  for ch in "$D_CMD" "$D_REPLIES" "$D_OPS"; do
    printf '{"id":"%s","guild_id":"%s"}\n' "$ch" "$D_GUILD" > "$FAKE/get/_channels_$ch.json"
  done
  printf '{"id":"600000000000000006","bot":true}\n' > "$FAKE/get/_users_@me.json"
  echo "primary git dirs: $(git -C "$PRIMARY" rev-parse --git-dir) / $(git -C "$PRIMARY" rev-parse --git-common-dir)"
  bridge tick || die "first bridge pass (creates pi-replies/)"
  [ -d "$(spool)" ] || die "bridge did not create the pi-replies spool"
  [ "$(n_events)" = 0 ] || die "spool not empty at start"
  echo "spool ready: $(spool)"
fi

if [ "${1:-}" = A ]; then
  say "A: real Pi primary answers a captain prompt -> spool event -> Discord post"
  pi_run "$PRIMARY" "$PRIMARY" "$OUT/A.jsonl" "" \
    "Reply with exactly this and nothing else: MAIN-PARITY-ALPHA" \
    "$PRIMARY/fork/discord/fm-pi-reply-mirror.ts"
  grep -q '"type":"agent_settled"' "$OUT/A.jsonl" || die "pi never settled: $(tail -3 "$OUT/A.jsonl.err")"
  [ "$(n_events)" = 1 ] || die "expected 1 spool event, got $(n_events)"
  f=$(spool_files | sed -n 1p)
  jq . "$f"
  [ "$(jq -r .schema "$f")" = "firstmate.discord-reply-event.v1" ] || die "wrong schema"
  [ "$(jq -r .continuation "$f")" = false ] || die "the first reply of a generation must not be a continuation"
  text=$(jq -r .text "$f")
  case "$text" in *MAIN-PARITY-ALPHA*) ;; *) die "reply text not captured: $text" ;; esac
  [ "$(jq -r .text_length "$f")" = "$(printf '%s' "$text" | wc -c | tr -d ' ')" ] || die "text_length must be the original length"
  bridge tick || die "delivery tick"
  echo "--- Discord POSTs in the replies channel:"; posts
  [ "$(n_posts)" = 1 ] || die "expected exactly one reply post, got $(n_posts)"
  [ "$(posts | jq -r .content)" = "$text" ] || die "the Discord post is not the settled reply verbatim"
  [ "$(posts | jq -r .reply_to)" = null ] || die "a fresh reply must not be attached to an older message"
  [ -e "$PRIMARY/state/.host-mirror.jsonl" ] && die "the Pi extension must never write the host mirror"
  echo "OK A"
fi

if [ "${1:-}" = B ]; then
  say "B: a real background delivery (custom_message + triggerTurn followUp) reply reaches Discord fresh"
  before=$(n_events); posts_before=$(n_posts)
  LAB_BG_MARKER=$OUT/B.bg pi_run "$PRIMARY" "$PRIMARY" "$OUT/B.jsonl" "" \
    "Reply with exactly this and nothing else: BG-TURN-ONE" \
    "$PRIMARY/fork/discord/fm-pi-reply-mirror.ts" "$LAB/bg-notify.ts"
  [ -e "$OUT/B.bg" ] || die "the background delivery never fired"
  grep -hq 'custom_message' "$PI_AGENT"/sessions/*/*.jsonl || die "pi did not persist a custom_message entry"
  delta=$(( $(n_events) - before ))
  [ "$delta" = 2 ] || die "expected the captain reply and the background reply, got $delta"
  first=$(spool_files | sed -n "$((before+1))p"); second=$(spool_files | sed -n "$((before+2))p")
  jq -c '{seq, continuation, text}' "$first" "$second"
  [ "$(jq -r .continuation "$first")" = false ] || die "captain reply must be fresh"
  [ "$(jq -r .continuation "$second")" = false ] || die "a background-delivery reply must be a fresh turn, not a continuation"
  second_text=$(jq -r .text "$second")
  sess=$(ls -t "$PI_AGENT"/sessions/*/*.jsonl | head -1)
  echo "--- real Pi transcript of that session (entry type / role / customType), last 8 entries:"
  jq -c 'select(.type != "session") | {type, role: (.message.role // null), customType: (.customType // null)}' "$sess" | tail -8 | tee "$OUT/B-transcript.txt"
  bridge tick || die "delivery tick"
  echo "--- Discord POSTs in the replies channel:"; posts
  bgpost=$(posts | jq -r .content | tail -1)
  new=$(( $(n_posts) - posts_before ))
  [ "$new" = 2 ] || die "expected 2 new posts, got $new"
  [ "$bgpost" = "$second_text" ] || die "background reply not delivered verbatim: $bgpost"
  case "$bgpost" in "(continued)"*) die "background reply was delivered as a continuation" ;; esac
  [ "$(posts | jq -r .reply_to | tail -1)" = null ] || die "background reply attached to an older Discord message"
  echo "OK B"
fi

if [ "${1:-}" = C ]; then
  say "C: reproduction - the SAME live background turn through the pre-fix extension is mislabelled a continuation"
  before=$(n_events)
  LAB_BG_MARKER=$OUT/C.bg pi_run "$LAB/prefix" "$PRIMARY" "$OUT/C.jsonl" "" \
    "Reply with exactly this and nothing else: PREFIX-TURN-ONE" \
    "$LAB/prefix/fork/discord/fm-pi-reply-mirror.ts" "$LAB/bg-notify.ts"
  grep -q '"type":"agent_settled"' "$OUT/C.jsonl" || die "pre-fix run never settled"
  delta=$(( $(n_events) - before ))
  echo "pre-fix run recorded $delta events"
  first=$(spool_files | sed -n "$((before+1))p"); second=$(spool_files | sed -n "$((before+2))p")
  jq -c '{seq, continuation, text}' "$first" "$second"
  second_cont=$(jq -r .continuation "$second"); second_text=$(jq -r .text "$second")
  bridge tick || die "delivery tick"
  echo "--- Discord POSTs in the replies channel:"; posts
  echo "pre-fix background reply continuation flag: $second_cont"
  [ "$second_cont" = true ] \
    || die "the pre-fix extension was expected to mislabel the background turn (reproduction did not happen)"
  last_content=$(posts | jq -rs 'last.content')
  case "$last_content" in
    "(continued)"*) echo "REPRODUCED: pre-fix extension marks the same live background turn as a continuation and the bridge posts it natively attached to the captain's earlier message" ;;
    *) die "pre-fix continuation flag had no delivery effect" ;;
  esac
  echo "OK C"
fi

if [ "${1:-}" = D ]; then
  say "D: adversarial - a linked worktree checkout writes nothing even with a valid home and lock"
  W=$LAB/wtroot
  checkout "$W" "$ROOT/fork/discord/fm-pi-reply-mirror.ts"
  git -C "$W" -c user.email=l@example -c user.name=l commit -q --allow-empty -m init
  git -C "$W" worktree add -q -b fm/linked "$LAB/linked"
  : > "$LAB/linked/AGENTS.md"; ln -sfn "$ROOT/bin" "$LAB/linked/bin"
  mkdir -p "$LAB/linked/fork/discord"
  cp "$ROOT/fork/discord/fm-pi-reply-mirror.ts" "$LAB/linked/fork/discord/"
  echo "linked worktree git dirs: $(git -C "$LAB/linked" rev-parse --git-dir) / $(git -C "$LAB/linked" rev-parse --git-common-dir)"
  echo "linked worktree has AGENTS.md and bin/: $([ -f "$LAB/linked/AGENTS.md" ] && echo yes) $([ -d "$LAB/linked/bin" ] && echo yes)"
  # Control first: the SAME extension bytes, prompt, home and lock, but from
  # the primary checkout, must record - so the only difference is the checkout
  # shape, and the linked-worktree pass is proven blocked by that gate alone.
  c_before=$(n_events)
  pi_run "$PRIMARY" "$PRIMARY" "$OUT/D-control.jsonl" "" \
    "Reply with exactly: CONTROL-PRIMARY-RECORDS" \
    "$PRIMARY/fork/discord/fm-pi-reply-mirror.ts"
  grep -q '"type":"agent_settled"' "$OUT/D-control.jsonl" || die "control run never settled"
  c_delta=$(( $(n_events) - c_before ))
  echo "control (primary checkout) events recorded: $c_delta"
  [ "$c_delta" = 1 ] || die "the control run must record one event"
  bridge tick >/dev/null || die "control delivery tick"
  before=$(n_events)
  pi_run "$LAB/linked" "$PRIMARY" "$OUT/D.jsonl" "" \
    "Reply with exactly: LINKED-WORKTREE-SHOULD-NOT-RECORD" \
    "$LAB/linked/fork/discord/fm-pi-reply-mirror.ts"
  grep -q '"type":"agent_settled"' "$OUT/D.jsonl" || die "pi never settled in the linked worktree"
  after=$(n_events)
  echo "spool events before/after linked-worktree run: $before/$after"
  [ "$after" = "$before" ] || die "a linked worktree must never write the Pi reply spool"
  echo "OK D"
fi

if [ "${1:-}" = E ]; then
  say "E: adversarial - a foreign lock holder writes nothing"
  before=$(n_events)
  env LAB_PROMPT="Reply with exactly: FOREIGN-LOCK-SHOULD-NOT-RECORD" LAB_AGENT="$PI_AGENT" \
    LAB_HOME="$PRIMARY" LAB_EXTS="-e $PRIMARY/fork/discord/fm-pi-reply-mirror.ts" LAB_PATH="$FAKEBIN:$PATH" \
    /bin/bash -c 'printf "1\n" > "$LAB_HOME/state/.lock"; exec env PI_CODING_AGENT_DIR="$LAB_AGENT" FM_HOME="$LAB_HOME" PATH="$LAB_PATH" pi -ne $LAB_EXTS --mode json "$LAB_PROMPT"' \
    >"$OUT/E.jsonl" 2>"$OUT/E.jsonl.err" || true
  grep -q '"type":"agent_settled"' "$OUT/E.jsonl" || die "pi never settled"
  after=$(n_events)
  echo "spool events before/after foreign-lock run: $before/$after (state/.lock=1)"
  [ "$after" = "$before" ] || die "a session that does not hold state/.lock must never write the spool"
  echo "OK E"
fi

if [ "${1:-}" = F ]; then
  say "F: adversarial - inert in a home whose bridge never created pi-replies/"
  FRESH=$LAB/nobridge
  checkout "$FRESH" "$ROOT/fork/discord/fm-pi-reply-mirror.ts"
  mkdir -p "$FRESH/state"
  before=0
  pi_run "$FRESH" "$FRESH" "$OUT/F.jsonl" "" \
    "Reply with exactly: NO-BRIDGE-SHOULD-NOT-RECORD" \
    "$FRESH/fork/discord/fm-pi-reply-mirror.ts"
  grep -q '"type":"agent_settled"' "$OUT/F.jsonl" || die "pi never settled"
  found=$(find "$FRESH" -path '*discord-bridge*' | wc -l | tr -d ' ')
  echo "files under any discord-bridge path in the bridge-less home: $found"
  [ "$found" = "$before" ] || die "the extension must not create a spool on its own"
  echo "OK F"
fi

if [ "${1:-}" = G ]; then
  say "G: adversarial - resuming the same session replays no old reply and mislabels no continuation"
  before=$(n_events); posts_before=$(n_posts)
  pi_run "$PRIMARY" "$PRIMARY" "$OUT/G.jsonl" "-c" \
    "Reply with exactly this and nothing else: RESUMED-REPLY" \
    "$PRIMARY/fork/discord/fm-pi-reply-mirror.ts"
  grep -q '"type":"agent_settled"' "$OUT/G.jsonl" || die "the resumed run never settled"
  delta=$(( $(n_events) - before ))
  [ "$delta" = 1 ] || die "a resumed session must record exactly one new event, got $delta"
  f=$(spool_files | tail -1); jq -c '{seq, continuation, text}' "$f"
  [ "$(jq -r .continuation "$f")" = false ] || die "the resumed generation's first reply must not be a continuation"
  bridge tick || die "delivery tick"
  echo "--- new Discord POSTs:"; posts | tail -n +"$((posts_before+1))"
  new=$(( $(n_posts) - posts_before ))
  [ "$new" = 1 ] || die "resume replayed or double-sent a reply: $new new posts"
  echo "OK G"
fi
