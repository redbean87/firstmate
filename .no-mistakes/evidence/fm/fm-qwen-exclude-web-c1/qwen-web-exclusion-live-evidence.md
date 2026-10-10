# Live validation: qwen-local pi-web-access tool exclusion

Run: gate worktree target commit 976aff6c (branch fm/fm-qwen-exclude-web-c1)

Every scenario below was driven in a disposable live lab built by bin/fm-live-lab.sh up
(real private tmux server, real bin/fm-spawn.sh, real pi binary, real treehouse worktree).
Lab home: /private/tmp/fmlab.lrmUFz (removed after this evidence turn).
The operator's registered local Qwen server (192.168.68.52:8087) is intentionally down,
so launched pi workers cannot complete a model turn; the launch command and process argv
are the product output under test.

## 1. pi ship worker, explicit qwen-local model, no config list
```
$ bin/fm-spawn.sh live-qwen-pi-z1 <lab>/projects/notes --mode local-only --yolo on \
    --harness pi --model qwen-local/qwen3.8-27b-unsloth-ud-iq3xxs
spawned live-qwen-pi-z1 harness=pi kind=ship mode=local-only yolo=on ...

staged launch file (/tmp/fm-live-qwen-pi-z1+<homehash>/launch.<gen>.sh):
--exclude-tools 'web_search,source_check,fetch_content,get_search_content'
live pi argv (ps), ship worker re-run live-qwen-pi-final-z7:
72675 /Users/cortezashley/.volta/bin/pi --tui-mode regular --exclude-tools web_search,source_check,fetch_content,get_search_content --model qwen-local/qwen3.8-27b-unsloth-ud-iq3xxs
```

## 2. config/crew-exclude-tools merge (config entries first, dedup web_search)
```
$ cat <lab>/config/crew-exclude-tools
mcp__tracker__editIssue
web_search
$ bin/fm-spawn.sh live-qwen-merge-z2 ... --harness pi --model qwen-local/qwen3.8-27b-unsloth-ud-iq3xxs
--exclude-tools 'mcp__tracker__editIssue,web_search,source_check,fetch_content,get_search_content'
```

## 3. Scoping: other model and other harness keep the tools
```
$ bin/fm-spawn.sh live-othermodel-z3 ... --harness pi --model opencode-go/deepseek-v4.1-flash
launch carries no --exclude-tools (expected)
--model 'opencode-go/deepseek-v4.1-flash'

$ bin/fm-spawn.sh live-oc-qwen-z4 ... --harness opencode --model qwen-local/qwen3.8-27b-unsloth-ud-iq3xxs
launch carries no --exclude-tools (expected)
"model":"qwen-local/qwen3.8-27b-unsloth-ud-iq3xxs"
```

## 4. Config-resolved secondmate model (review-fix scenario), target commit
```
$ cat <lab>/config/secondmate-harness
pi qwen-local/qwen3.8-27b-unsloth-ud-iq3xxs
$ bin/fm-spawn.sh live-mate-qwen-z5 --secondmate   # no explicit --harness/--model
--exclude-tools 'web_search,source_check,fetch_content,get_search_content'
--model 'qwen-local/qwen3.8-27b-unsloth-ud-iq3xxs'
/Users/cortezashley/.volta/bin/pi --tui-mode regular --approve --exclude-tools web_search,source_check,fetch_content,get_search_content --model qwen-local/qwen3.8-27b-uns

same spawn on pre-fix commit d530245b (feature commit before the reorder):
launch carries NO --exclude-tools (reproduces the reported bug)
--model 'qwen-local/qwen3.8-27b-unsloth-ud-iq3xxs'
```

## 5. Primary session unaffected
```
$ ps -o command= -p <lab primary pid>
pi --approve --session-dir /private/tmp/fmlab.lrmUFz/pi-sessions --model opencode-go/deepseek-v4.1-flash --thinking low
primary carries no --exclude-tools (expected)
```

## 6. pi actually stops sending the four tool schemas

Mechanism proof with the real `pi` binary and the real installed `npm:pi-web-access@0.38.0`
package, against a disposable `PI_CODING_AGENT_DIR` (copied models.json/settings.json/npm)
pointed at a local mock OpenAI-compatible endpoint that logs each request body:

```
baseline request body tools:  8 -> read, bash, edit, write, web_search, source_check, fetch_content, get_search_content  (14211 bytes)
with --exclude-tools web_search,source_check,fetch_content,get_search_content:
                              4 -> read, bash, edit, write  (2956 bytes)
bytes removed from the tools schema: 11255
```

Raw captured request bodies:
- `pi-request-baseline-full.json` (baseline: four web tools present)
- `pi-request-excluded-full.json` (fm-spawn's exact flag: four web tools absent)
