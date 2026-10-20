#!/bin/bash
#
# The fingerprint setup installs libfprint-git in place of stock libfprint. The
# two conflict, so the swap has to happen inside one --ask 4 transaction, and a
# rerun with everything installed must not touch pacman at all. A Broadcom
# ControlVault 3 reader instead installs libfprint-tod and Broadcom's plugin,
# which conflict with both of those libraries. The first ControlVault open can
# flash firmware inside fprintd's startup, so setup raises that start timeout
# before it restarts the daemon. A restart that still times out must not skip
# enrollment. The real omarchy-pkg-missing runs; pacman, yay, and the
# privileged calls are stubbed.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin"
export CALL_LOG="$scratch/calls"
export PATH="$scratch/bin:$ROOT/bin:$PATH"

cat > "$scratch/bin/omarchy-hw-fingerprint" <<'STUB'
#!/bin/bash
exit "${HARDWARE_STATUS:-0}"
STUB
cat > "$scratch/bin/omarchy-hw-fingerprint-controlvault3" <<'STUB'
#!/bin/bash
exit "${CONTROLVAULT_STATUS:-1}"
STUB
cat > "$scratch/bin/omarchy-hw-x86" <<'STUB'
#!/bin/bash
exit "${X86_STATUS:-0}"
STUB
cat > "$scratch/bin/omarchy-pkg-aur-accessible" <<'STUB'
#!/bin/bash
printf 'aur-access\n' >> "$CALL_LOG"
exit "${AUR_ACCESS_STATUS:-0}"
STUB
cat > "$scratch/bin/yay" <<'STUB'
#!/bin/bash
printf 'yay %s\n' "$*" >> "$CALL_LOG"
exit "${YAY_STATUS:-0}"
STUB
cat > "$scratch/bin/fprintd-list" <<'STUB'
#!/bin/bash
printf 'list\n' >> "$CALL_LOG"
exit "${LIST_STATUS:-1}"
STUB
cat > "$scratch/bin/sudo" <<'STUB'
#!/bin/bash
case "$1" in
  pacman | fprintd-enroll) exec "$@" ;;
  systemctl)
    printf 'systemctl %s\n' "${*:2}" >> "$CALL_LOG"
    if [[ ${SYSTEMCTL_STATUS:-0} != 0 && $2 == restart ]]; then
      exit "$SYSTEMCTL_STATUS"
    fi
    ;;
  sed) printf 'pam %s\n' "$*" >> "$CALL_LOG" ;;
  mkdir) printf 'mkdir %s\n' "${*:2}" >> "$CALL_LOG" ;;
  tee)
    if [[ $* == *controlvault* ]]; then
      printf 'dropin\n' >> "$CALL_LOG"
      cat > "$CALL_LOG.dropin"
    else
      printf 'pam %s\n' "$*" >> "$CALL_LOG"
      cat >/dev/null
    fi
    ;;
  *) echo "Unexpected privileged call: $*" >> "$CALL_LOG"; exit 99 ;;
esac
STUB
# INSTALLED lists the installed package names, one per line.
cat > "$scratch/bin/pacman" <<'STUB'
#!/bin/bash
case "$1" in
  -Q)
    if [[ $2 == "--" ]]; then
      shift 2
    else
      shift
    fi
    grep -qx -- "$1" <<< "${INSTALLED:-}"
    ;;
  -S)
    printf 'pacman %s\n' "$*" >> "$CALL_LOG"
    exit "${INSTALL_STATUS:-0}"
    ;;
  *) printf 'pacman %s\n' "$*" >> "$CALL_LOG"; exit 99 ;;
esac
STUB
cat > "$scratch/bin/fprintd-enroll" <<'STUB'
#!/bin/bash
# Stop before verification/PAM; no host authentication files may be changed.
echo enroll >> "$CALL_LOG"
exit "${ENROLL_STATUS:-1}"
STUB
cat > "$scratch/bin/fprintd-verify" <<'STUB'
#!/bin/bash
echo verify >> "$CALL_LOG"
exit "${VERIFY_STATUS:-1}"
STUB
chmod +x "$scratch/bin/"*

cat > "$scratch/bin/omarchy-apply-lock" <<'STUB'
#!/bin/bash
echo apply-lock >> "$CALL_LOG"
if [[ ${LOCK_SETUP_UNKNOWN:-0} != "1" ]]; then
  touch "$TEST_LOCK_PAM"
fi
STUB
chmod +x "$scratch/bin/omarchy-apply-lock"

export TEST_LOCK_PAM="$scratch/omarchy-lock-fingerprint"
dropin="$scratch/fprintd.service.d/20-controlvault-start-timeout.conf"
setup_script="$scratch/omarchy-setup-security-fingerprint"
sed -e "s|/etc/pam.d/omarchy-lock-fingerprint|$TEST_LOCK_PAM|g" \
  -e "s|/etc/systemd/system/fprintd.service.d/20-controlvault-start-timeout.conf|$dropin|g" \
  "$ROOT/bin/omarchy-setup-security-fingerprint" > "$setup_script"
chmod +x "$setup_script"

run_setup() {
  : > "$CALL_LOG"
  rm -f "$CALL_LOG.dropin"
  if OMARCHY_PATH="$scratch" "$setup_script" > "$scratch/output" 2>&1; then
    fail "setup stops on the simulated enrollment or installation failure"
  fi
  if grep -Eq '^(pam |apply-lock$|Unexpected privileged call)' "$CALL_LOG"; then
    fail "setup does not change PAM or lock recovery after failed enrollment"
  fi
}

assert_installs() {
  grep -qx 'pacman -S --needed --noconfirm --ask 4 -- libfprint-git fprintd usbutils' "$CALL_LOG" || fail "$1"
  (( $(grep -c '^pacman ' "$CALL_LOG") == 1 )) || fail "$1: one pacman transaction"
  if grep -q '^yay ' "$CALL_LOG"; then
    fail "$1: stock readers stay on libfprint-git"
  fi
}

controlvault_yay='yay -S --needed --noconfirm --useask --pgpfetch --sudoloop -- fprintd usbutils libfprint-tod libfprint-2-tod1-broadcom'

assert_controlvault_installs() {
  grep -qx "$controlvault_yay" "$CALL_LOG" || fail "$1"
  (( $(grep -c '^yay ' "$CALL_LOG") == 1 )) || fail "$1: one driver transaction"
  if grep -q '^pacman ' "$CALL_LOG"; then
    fail "$1: ControlVault setup does not install libfprint-git"
  fi
  (( $(grep -cx 'systemctl restart fprintd' "$CALL_LOG") == 2 )) || fail "$1: restarts fprintd around the firmware check"
  grep -qx list "$CALL_LOG" || fail "$1: opens the reader before enrollment"
  grep -qx 'mkdir -p /etc/systemd/system/fprintd.service.d' "$CALL_LOG" || fail "$1: creates the fprintd drop-in directory"
  grep -qx dropin "$CALL_LOG" || fail "$1: raises the fprintd start timeout"
  grep -qx 'systemctl daemon-reload' "$CALL_LOG" || fail "$1: reloads systemd after the start timeout"
  grep -qx 'TimeoutStartSec=240' "$CALL_LOG.dropin" || fail "$1: start timeout is 240 seconds"
  if grep -q 'TimeoutStopSec' "$CALL_LOG.dropin"; then
    fail "$1: does not lengthen the stop timeout"
  fi
}

run_setup
assert_installs "a fresh machine installs libfprint-git, fprintd and usbutils"
grep -qx enroll "$CALL_LOG" || fail "installation is followed by enrollment"
pass "a fresh machine installs libfprint-git and reaches enrollment"

INSTALLED=$'libfprint\nfprintd\nusbutils' run_setup
assert_installs "installed stock libfprint is replaced in the same transaction"
pass "installed stock libfprint is replaced without a removal step"

INSTALLED=$'libfprint-git\nfprintd\nusbutils' run_setup
if grep -q '^pacman' "$CALL_LOG"; then
  fail "a rerun with everything installed does not touch pacman"
fi
grep -qx enroll "$CALL_LOG" || fail "a rerun with everything installed reaches enrollment"
pass "a rerun with everything installed goes straight to enrollment"

INSTALL_STATUS=1 run_setup
if grep -qx enroll "$CALL_LOG"; then
  fail "a failed package transaction prevents enrollment"
fi
pass "a failed installation stops before enrollment"

HARDWARE_STATUS=1 run_setup
[[ ! -s $CALL_LOG ]] || fail "missing hardware stops before package operations"
pass "missing hardware performs no package operations"

# Successful setup must reuse the same lock/recovery installer as updates.
: > "$CALL_LOG"
OMARCHY_PATH="$scratch" ENROLL_STATUS=0 VERIFY_STATUS=0 \
  "$setup_script" > "$scratch/output" 2>&1 || fail "successful enrollment configures authentication"
[[ $(grep -E '^(enroll|verify|apply-lock)$' "$CALL_LOG") == $'enroll\nverify\napply-lock' ]] ||
  fail "setup configures lock recovery once, after enrollment and verification"
pass "setup reuses apply-lock after enrollment and verification"

rm -f "$TEST_LOCK_PAM"
if OMARCHY_PATH="$scratch" ENROLL_STATUS=0 VERIFY_STATUS=0 LOCK_SETUP_UNKNOWN=1 \
  "$setup_script" > "$scratch/output" 2>&1; then
  fail "an inconclusive lock installer cannot report successful lock setup"
fi
grep -q 'lock-screen configuration could not be confirmed' "$scratch/output" || fail "inconclusive setup explains how to retry"
if grep -q 'Perfect!\|You can use your fingerprint' "$scratch/output"; then
  fail "inconclusive setup does not promise fingerprint unlock"
fi
pass "an inconclusive lock installer cannot report successful lock setup"

CONTROLVAULT_STATUS=0 run_setup
assert_controlvault_installs "a ControlVault 3 machine installs the Broadcom driver"
grep -qx enroll "$CALL_LOG" || fail "ControlVault installation is followed by enrollment"
grep -q 'firmware' "$scratch/output" || fail "ControlVault setup warns that the first open updates firmware"
pass "a ControlVault 3 machine installs the Broadcom driver and reaches enrollment"

CONTROLVAULT_STATUS=0 INSTALLED=$'libfprint-git\nfprintd\nusbutils' run_setup
assert_controlvault_installs "an installed libfprint-git is replaced by the ControlVault driver"
pass "an installed libfprint-git is replaced by the ControlVault driver"

CONTROLVAULT_STATUS=0 INSTALLED=$'fprintd\nusbutils\nlibfprint-tod\nlibfprint-2-tod1-broadcom' run_setup
if grep -q '^yay ' "$CALL_LOG"; then
  fail "a rerun with the ControlVault driver installed does not rebuild it"
fi
grep -qx enroll "$CALL_LOG" || fail "a rerun with the ControlVault driver installed reaches enrollment"
grep -qx list "$CALL_LOG" || fail "a rerun still opens the reader before enrollment"
grep -qx dropin "$CALL_LOG" || fail "a rerun still raises the fprintd start timeout"
pass "a rerun with the ControlVault driver installed goes straight to the reader"

CONTROLVAULT_STATUS=0 YAY_STATUS=1 run_setup
if grep -Eq '^(list|enroll)$' "$CALL_LOG"; then
  fail "a failed ControlVault install does not open or enroll the reader"
fi
pass "a failed ControlVault install stops before the reader is opened"

CONTROLVAULT_STATUS=0 X86_STATUS=1 run_setup
if grep -Eq '^(yay |list$|enroll$)' "$CALL_LOG"; then
  fail "ControlVault setup on non-x86 stops before installing"
fi
grep -q 'only available on x86_64' "$scratch/output" || fail "ControlVault setup on non-x86 explains why"
pass "ControlVault setup on non-x86 stops before installing"

CONTROLVAULT_STATUS=0 AUR_ACCESS_STATUS=1 run_setup
if grep -Eq '^(yay |list$|enroll$)' "$CALL_LOG"; then
  fail "ControlVault setup does not install when the AUR is unreachable"
fi
grep -q 'AUR, which is unreachable' "$scratch/output" || fail "ControlVault setup explains an unreachable AUR"
pass "ControlVault setup stops when the AUR is unreachable"

CONTROLVAULT_STATUS=0 AUR_ACCESS_STATUS=1 INSTALLED=$'fprintd\nusbutils\nlibfprint-tod\nlibfprint-2-tod1-broadcom' run_setup
if grep -qx aur-access "$CALL_LOG"; then
  fail "an installed ControlVault driver does not consult the AUR"
fi
if grep -q '^yay ' "$CALL_LOG"; then
  fail "an installed ControlVault driver does not download when the AUR is unreachable"
fi
grep -qx enroll "$CALL_LOG" || fail "an installed ControlVault driver still enrolls when the AUR is unreachable"
pass "an installed ControlVault driver enrolls while the AUR is unreachable"

: > "$CALL_LOG"
OMARCHY_PATH="$scratch" CONTROLVAULT_STATUS=0 ENROLL_STATUS=0 VERIFY_STATUS=0 \
  "$setup_script" > "$scratch/output" 2>&1 || fail "ControlVault enrollment configures authentication"
[[ $(grep -E '^(enroll|verify|apply-lock)$' "$CALL_LOG") == $'enroll\nverify\napply-lock' ]] ||
  fail "ControlVault setup configures lock recovery once, after enrollment and verification"
grep -qx "$controlvault_yay" "$CALL_LOG" || fail "successful ControlVault setup installed the Broadcom driver"
grep -qx dropin "$CALL_LOG" || fail "successful ControlVault setup raises the fprintd start timeout"
pass "ControlVault setup reuses apply-lock after enrollment and verification"

mkdir -p "$(dirname "$dropin")"
printf '[Service]\nTimeoutStartSec=240\n' > "$dropin"
CONTROLVAULT_STATUS=0 INSTALLED=$'fprintd\nusbutils\nlibfprint-tod\nlibfprint-2-tod1-broadcom' run_setup
if grep -qx dropin "$CALL_LOG"; then
  fail "an existing 240s start timeout is left in place"
fi
if grep -qx 'systemctl daemon-reload' "$CALL_LOG"; then
  fail "an existing 240s start timeout does not reload systemd"
fi
grep -qx enroll "$CALL_LOG" || fail "an existing start timeout still reaches enrollment"
pass "an existing 240s start timeout is left in place"

printf '[Service]\nTimeoutStartSec=90\n' > "$dropin"
CONTROLVAULT_STATUS=0 INSTALLED=$'fprintd\nusbutils\nlibfprint-tod\nlibfprint-2-tod1-broadcom' run_setup
grep -qx dropin "$CALL_LOG" || fail "a short start timeout is replaced"
grep -qx 'TimeoutStartSec=240' "$CALL_LOG.dropin" || fail "a short start timeout is raised to 240 seconds"
pass "a short start timeout is raised to 240 seconds"
rm -f "$dropin"

CONTROLVAULT_STATUS=0 SYSTEMCTL_STATUS=1 INSTALLED=$'fprintd\nusbutils\nlibfprint-tod\nlibfprint-2-tod1-broadcom' run_setup
grep -qx enroll "$CALL_LOG" || fail "a slow reader start still reaches enrollment"
grep -q 'still starting' "$scratch/output" || fail "a slow reader start says enrollment will wait"
pass "a slow reader start still reaches enrollment"
