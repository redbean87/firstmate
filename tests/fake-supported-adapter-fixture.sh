#!/usr/bin/env bash
# Shared fixture for backend end-to-end suites that used to launch a hand-typed
# command. Hand-typed launches are refused outright now (docs/configuration.md
# "Single-slot launch guard"), so those suites launch a fake `pi` through the
# supported launch path instead, keeping their original assertions.
#
# The fake answers the version probe and, when actually executed, prints the
# caller's marker (when one was given) and then sleeps, so a suite can keep
# asserting on pane capture and on a still-running worker.
fm_test_install_fake_pi_adapter() { # <bindir> [marker]
  local bindir=$1 marker=${2:-} marker_file
  marker_file="$bindir/fake-adapter-marker"
  mkdir -p "$bindir"
  if [ -n "$marker" ]; then
    printf '%s\n' "$marker" >"$marker_file"
  fi
  # The generated script is written literally; these are not quoting slips.
  # shellcheck disable=SC2016
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -u'
    printf '%s\n' 'case "${1:-}" in'
    printf '%s\n' '--help|--version) printf "%s\n" "Pi 0.84.0" "Options: --help --tui-mode <mode> --approve"; exit 0 ;;'
    printf '%s\n' 'esac'
    if [ -n "$marker" ]; then
      printf 'cat %q 2>/dev/null || true\n' "$marker_file"
    fi
    printf '%s\n' 'exec sleep 3600'
  } >"$bindir/pi"
  chmod +x "$bindir/pi"
  printf '%s\n' "$bindir"
}
