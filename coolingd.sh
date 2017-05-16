#!/usr/bin/dash
# Qubes OS Thermal Management for Lenovo ThinkPads
# Written by Adrian Günter <adrian|gntr/me>
#
# Notes:
# - Requires enabled fan_control thinkpad_acpi module parameter
# - Trip points are not sorted so indices must be sequential and ordered
#   by (ascending) trip temperatures
#
# Environment Variables:
# - VERBOSITY: 0 = error, 1 = warning, 2 = info, 3 = debug (default: 2)
#
# ### Trip Point Example ###
# readonly TRIPPT_1=65000      # Trip point in millidegree Celsius
# readonly TRIPPT_1_DEBOUNCE=3 # Cycles ($INTERVAL_SEC) to debounce for: 0(none)..?
# readonly TRIPPT_1_FAN=200    # Fan PWM control: ""(NC)|auto|0(off)..255|max(dangerous)
# readonly TRIPPT_1_PSTATE=5   # CPU P-state selection: ""(NC)|0..$PSTATE_MAX|max

### Trip Point 1 ###
readonly TRIPPT_1=50000
readonly TRIPPT_1_DEBOUNCE=2
readonly TRIPPT_1_FAN=255
readonly TRIPPT_1_PSTATE=

### Trip Point 2 ###
readonly TRIPPT_2=60000
readonly TRIPPT_2_DEBOUNCE=3
readonly TRIPPT_2_FAN=255
readonly TRIPPT_2_PSTATE=3

### Trip Point 3 ###
readonly TRIPPT_3=70000
readonly TRIPPT_3_DEBOUNCE=4
readonly TRIPPT_3_FAN=255
readonly TRIPPT_3_PSTATE=5

### Trip Point 4 ###
readonly TRIPPT_4=85000
readonly TRIPPT_4_DEBOUNCE=5
readonly TRIPPT_4_FAN=max
readonly TRIPPT_4_PSTATE=max

### Misc Configuration ###
readonly INTERVAL_SEC=1.5  # Main loop sleep duration (in fractional seconds)

##########################################
########## END OF CONFIGURATION ##########
##########################################

# System monitoring utility function (first argument is passed to "watch -n<$1>")
# Place this in your shell profile and call it with "qubestop [interval-seconds]"
qubestop() {
  n=${1:-1}; watch -td -n"${n}" -x bash -c '\
    printf "Updates every %0.1f seconds\n\n" '"${n}"';\
    printf "# CPU\n"; xenpm get-cpufreq-states|perl -ne \
      "BEGIN{my \$c = -1};/^current.+ (\d+ MHz)$/&&printf \"Core %d: %s\\n\",\$c++,\$1";\
    printf "\n# Fan\n"; cat /proc/acpi/ibm/fan|grep -v ^command;\
    printf "\n# Thermal Sensors\n"; sensors -A|grep -P "^Core \d+:.+|^temp1:.+[^)]$";\
    printf "\n# XenTop\n"; xentop -bi1|perl -lane \
      "printf \"%10s %-6s %8s %-6s %8s %-6s %s\\n\",\$F[0],\$F[1],\$F[2],\$F[3],\$F[4],\$F[5]";\
  '
}

### Dev Notes ###
#
# https://www.kernel.org/doc/Documentation/laptops/thinkpad-acpi.txt
#
# thinkfan
# ---
# /sys/devices/platform/thinkpad_hwmon/{fan1_input,pwm1{,_enable}}
# fan1_input: read for current fan speed in RPM
# pwm1: 0(disabled)-255(7/max-recommended)
# pwm1_enable: 0=disengaged(full-speed), 1=manual(pwm1), 2=auto(hardware-driven)
#
# TODO
# ---
# - Decide if debouncing is necessary for stepping down cooling
# - Missing assertions and validation for VERBOSITY and __set_{fan,pstate} function args
# - Warning if PWM value is rounded in __set_fan
# - Zone config spec: TRIPPT_X='ACPITZ:90&(CORE_0:90|CORE_2:90)'
#   * Perl { Validate and parse with regex; Compile and output shell condition string to eval; }
#   * Regex should support minimum syntax necessary to fulfill spec
#   * $sensor_target_re="[A-Z0-9]+(_*[A-Z0-9]+)*:[0-9]+"
#   * /$sensor_target_re(?:[&|](?:$sensor_target_re|\($sensor_target_re[&|]$sensor_target_re\)))*
#      # old # (\($sensor_target_re\|$sensor_target_re\)[&|])*/

# nounset, noglob, noclobber
set -ufC
# WYSIWYG shell command resolution
# shellcheck disable=SC2123
PATH=

[ ! "${VERBOSITY+X}" ] && VERBOSITY=2
readonly VERBOSITY

readonly THINKPAD_MODULE_SYSFS='/sys/module/thinkpad_acpi'
readonly THINKPAD_ACPI_SYSFS='/sys/devices/platform/thinkpad_acpi'
readonly THINKPAD_HWMON_SYSFS='/sys/devices/platform/thinkpad_hwmon'
readonly FAN_1_INPUT="${THINKPAD_HWMON_SYSFS}/fan1_input"
readonly FAN_1_PWM="${THINKPAD_HWMON_SYSFS}/pwm1"
readonly FAN_1_PWM_STATE="${THINKPAD_HWMON_SYSFS}/pwm1_enable"
readonly SENSOR_ACPITZ='/sys/class/hwmon/hwmon0/temp1'
readonly SENSOR_CORE_0='/sys/class/hwmon/hwmon2/temp2'
readonly SENSOR_CORE_2='/sys/class/hwmon/hwmon2/temp4'

readonly ID='/usr/bin/id'
readonly P='/usr/bin/printf'
readonly PERL='/usr/bin/perl'
readonly READ='read -r'
readonly SLEEP='/usr/bin/sleep'
readonly XENPM='/usr/sbin/xenpm'
readonly XENPM_SET_MAXFREQ="$XENPM set-scaling-maxfreq"

EUID="$($ID -u)"
readonly EUID

_printferr() { $P "$@" >&2; }

_E() { _printferr 'ERROR: %s\n' "$($P "$@")"; \
  [ ! "${EXIT+X}" ] && local EXIT=1; [ "${EXIT}" -ge 1 ] && exit ${EXIT}; }

if [ ${VERBOSITY} -ge 1 ]; then
  _W() { _printferr 'WARNING: %s\n' "$($P "$@")"; }
else _W() { :; }; fi

if [ ${VERBOSITY} -ge 2 ]; then
  _I() { _printferr 'INFO: %s\n' "$($P "$@")"; }
else _I() { :; }; fi

if [ ${VERBOSITY} -ge 3 ]; then
  _D() { _printferr 'DEBUG: %s\n' "$($P "$@")"; }
else _D() { :; }; fi

_assert_readable() {
  local file; for file in "${@}"; do
    [ -r "${file}" ] || _E '%s not readable' "${file}"
  done
}

_assert_writable() {
  local file; for file in "${@}"; do
    [ -w "${file}" ] || _E '%s not writable' "${file}"
  done
}

_is_integer() { [ "$1" -eq "$1" ] 2>/dev/null; }

_floatcmp() { # <left-operand> <operator> <right-operand> <precision>
  $PERL -- /dev/fd/0 "$@" 0<<'EOF'
my ($x, $op, $p) = (1, $ARGV[1], $ARGV[3]);
my ($a, $b) = (sprintf("%.${p}f", $ARGV[0]), sprintf("%.${p}f", $ARGV[2]));
if   ($op eq "eq"){$a eq $b and $x = 0}elsif($op eq "ne"){$a ne $b and $x = 0}
elsif($op eq "lt"){$a lt $b and $x = 0}elsif($op eq "gt"){$a gt $b and $x = 0}
elsif($op eq "le"){$a le $b and $x = 0}elsif($op eq "ge"){$a ge $b and $x = 0}
else {$x = 2} # Exit with 2 if operand is unknown
exit $x;
EOF
}

__check_config() {
  local i=0 t_var t_val last_t_val=0 d_var d_val f_var f_val p_var p_val
  if [ ! ${INTERVAL_SEC+X} ] || [ -z "${INTERVAL_SEC}" ] \
    || _floatcmp "${INTERVAL_SEC}" lt 0.1 3
  then
    EXIT=3 _E 'INTERVAL_SEC must be a value greater than 0.1'
  fi
  while :; do
    # Break when POSIX equivalent of ${!TRIPPT_$i+X} fails (no more trip points)
    eval "[ ! \${TRIPPT_$((i+1))+X} ]" && break
    i=$((i+1))
    t_var="TRIPPT_${i}"
    d_var="${t_var}_DEBOUNCE"
    f_var="${t_var}_FAN"
    p_var="${t_var}_PSTATE"
    # Temp
    eval "t_val=\${${t_var}}"
    if [ -z "${t_val}" ] || [ "${t_val}" -lt 20000 ] || [ "${t_val}" -gt 120000 ]
    then
      EXIT=3 _E '%s must be in range 20000-120000 m C, inclusive' ${t_var}
    elif [ "${t_val}" -lt ${last_t_val} ]; then
      EXIT=3 _E 'Trip point order error'
    fi
    last_t_val=${t_val}
     # Debounce
    eval "[ \${${d_var}+X} ]" || eval "${d_var}=0" # No debounce by default
    eval "d_val=\${${d_var}}"
    if [ -z "${d_val}" ] || [ "${d_val}" -lt 0 ]; then
      EXIT=3 _E '%s must be greater than or equal to 0' ${d_var}
    fi
    # Fan
    eval "[ \${${f_var}+X} ]" || eval "${f_var}=''" # No change by default
    eval "f_val=\${${f_var}}"
    if ! ( [ -z "${f_val}" ] || [ "${f_val}" = 'auto' ] || [ "${f_val}" = 'max' ] \
      || ( _is_integer "${f_val}" && [ "${f_val}" -ge 0 ] && [ "${f_val}" -le 255 ] ) \
    ); then
      EXIT=3 _E '%s must be an integer in range 0-255 or one of "", "auto", or "max"' ${f_var}
    fi
    # P-state
    eval "[ \${${p_var}+X} ]" || eval "${p_var}=''" # No change by default
    eval "p_val=\${${p_var}}"
    if ! ( [ -z "${p_val}" ] || [ "${p_val}" = 'max' ] \
      || ( _is_integer "${p_val}" && [ "${p_val}" -ge 0 ] \
      && [ "${p_val}" -le "${PSTATE_MAX}" ] ) ); then
      _E '%s must be an integer in range 0-%d, "", or "max"' ${p_var} "${PSTATE_MAX}"
    fi
    _D 'Trip point %2d: temp=%-6d debounce=%-2d fan=%-4s pstate=%-3s' \
      ${i} "${t_val}" "${d_val}" "${f_val:-''}" "${p_val:-''}"
  done
  readonly TRIPPT_COUNT=${i}
  _D '%d trip points found' ${TRIPPT_COUNT}
}

__check_thinkpad_acpi() {
  local fan_control
  [ -d "${THINKPAD_MODULE_SYSFS}" ] || _E 'thinkpad_acpi kernel module not loaded'
  exec 3< "${THINKPAD_MODULE_SYSFS}/parameters/fan_control" && $READ fan_control <&3
  [ "${fan_control}" = 'Y' ] || _E \
    'fan_control thinkpad_acpi module parameter not enabled'
  _assert_readable "${FAN_1_INPUT}" "${FAN_1_PWM}" "${FAN_1_PWM_STATE}" \
    "${SENSOR_ACPITZ}_input" "${SENSOR_CORE_0}_input" "${SENSOR_CORE_2}_input"
  _assert_writable "${FAN_1_PWM}" "${FAN_1_PWM_STATE}"
}

__get_fan() {
  local pwm_state pwm_val
  exec 3< "${FAN_1_PWM_STATE}" && $READ pwm_state <&3
  [ "${pwm_state}" -eq 0 ] && { $P 'max'; return; }
  [ "${pwm_state}" -eq 2 ] && { $P 'auto'; return; }
  # pwm_enable must be 1 (user-defined). TODO: assert?
  exec 3< "${FAN_1_PWM}" && $READ pwm_val <&3
  $P '%d' "${pwm_val}"
}

__set_fan() {
  # auto, max, 0-255
  local fan="${1}" pwm_state pwm_val
  _I 'New fan speed: %s' "${fan}"
  # PWM value is rounded to nearest multiple of 256/7(?) (max 218) so we should probably
  # return that (or error if value post-write doesn't match argument?)
  if [ "${fan}" = 'max' ]; then
    $P '0' >|"${FAN_1_PWM_STATE}"
  elif [ "${fan}" = 'auto' ]; then
    $P '2' >|"${FAN_1_PWM_STATE}"
  else
    # pwm value must be modified AFTER writing 1 to state or no change will be made
    $P '1' >|"${FAN_1_PWM_STATE}"
    $P '%d' "${fan}" >|"${FAN_1_PWM}"
  fi
}

__get_pstate(){
  local freq
  # shellcheck disable=SC2016
  freq="$($XENPM get-cpufreq-para 0 | $PERL -ne \
    '/^scaling frequency\s*:.*max\s*\[(\d+)/ and print $1')"
  pstate=-1; while [ $((pstate+=1)) -le "${PSTATE_MAX}" ]; do
    eval "[ ${freq} -ge \${PSTATE_${pstate}_FREQ} ]" && break
  done
  $P '%d' "${pstate}"
}

__set_pstate() {
  local freq pstate="${1}"
  [ "${pstate}" = 'max' ] && pstate=${PSTATE_MAX}
  eval "freq=\${PSTATE_${pstate}_FREQ}"
  _I 'New minumum CPU P-state: %d (%d Hz)\n' "${pstate}" "${freq}"
  $XENPM_SET_MAXFREQ "${freq}"
}

__xenpm_read_pstate_info() {
  local p=-1 freq pstate_freqs
  # shellcheck disable=SC2016
  pstate_freqs="$($XENPM get-cpufreq-para 0 | $PERL -ne \
    '/^scaling_avail_freq\s*:((?:\s+\*?\d+)+)/ and print $1=~s/^\s+|[*]+//gr')"
  for freq in ${pstate_freqs}; do
    p=$((p+1))
    eval 'readonly PSTATE_${p}_FREQ="${freq}"'
    _D 'P-state %2d: %7d Hz' ${p} "$(eval "$P \"\${PSTATE_${p}_FREQ}\"")"
  done
  [ ${p} -lt 0 ] || [ ! "${PSTATE_0_FREQ+X}" ] \
    && _E 'Failed to parse CPU P-states from xenpm'
  _D '%d CPU P-states found' $((p+1))
  readonly PSTATE_MAX=${p}
}

__exit_trap() {
  exit_code=$?
  trap -- '' HUP INT QUIT PIPE TERM # No interrupting the exit handler
  # If ACTIVE_TP_INDEX exists we reached the main loop
  if [ "${ACTIVE_TP_INDEX+X}" ]; then
    _printferr '\n'
    _I 'Shutting down...'
    # If ACTIVE_TP_INDEX > 0 we need to reset the fan and CPU P-state before exiting
    if [ "${ACTIVE_TP_INDEX}" -gt 0 ]; then
      __set_fan "${ORIGINAL_FAN}"
      __set_pstate "${ORIGINAL_PSTATE}"
    fi
  fi
  exit ${exit_code}
}

__main() {
  local tp_index tp_temp tp_debounce tp_fan tp_pstate \
        debounce_tp_index=0 debounce_remaining=0 \
        first=1

  trap -- '__exit_trap' EXIT
  trap -- 'exit $?' HUP INT QUIT PIPE TERM

  [ "${EUID}" -eq 0 ] || EXIT=4 _E 'This script must run as root'

  __check_thinkpad_acpi
  __xenpm_read_pstate_info
  __check_config

  readonly ORIGINAL_FAN="$(__get_fan)"
  _D 'Original fan state: %s' "${ORIGINAL_FAN}"
  readonly ORIGINAL_PSTATE="$(__get_pstate)"
  _D 'Original min P-state: %d' "${ORIGINAL_PSTATE}"

  ACTIVE_TP_INDEX=0

  # Main loop
  while :; do
    # Sleep at top, skipping first iteration, so that debouncing can ?continue? the main loop
    # shellcheck disable=SC2015
    [ ${first} -eq 1 ] && first=0 || $SLEEP ${INTERVAL_SEC}

    exec 3< "${SENSOR_ACPITZ}_input" && $READ acpitz_temp <&3
    exec 3< "${SENSOR_CORE_0}_input" && $READ core_0_temp <&3
    exec 3< "${SENSOR_CORE_2}_input" && $READ core_2_temp <&3
    _D 'Sensor sample: acpitz=%-6d core0=%-6d core2=%-6d' \
      "${acpitz_temp:--1}" "${core_0_temp:--1}" "${core_2_temp:--1}"

    # Iterate descendingly to match the highest possible trip point
    tp_index=$((TRIPPT_COUNT+1)); while [ $((tp_index-=1)) -ge 1 ]; do
      eval "tp_temp=\${TRIPPT_${tp_index}}"
      if [ "${acpitz_temp}" -lt "${tp_temp}" ]; then
        if [ ${tp_index} -eq 1 ]; then
          # We've checked the last trip point; none matched
          if [ ${ACTIVE_TP_INDEX} -ne 0 ]; then
            # Reset cooling devices and ACTIVE_TP_INDEX to their original values
            __set_fan "${ORIGINAL_FAN}"
            __set_pstate "${ORIGINAL_PSTATE}"
            ACTIVE_TP_INDEX=0
          fi
          if [ ${debounce_remaining} -gt 0 ]; then
            _D 'Trip point %d no longer active, debounce cancelled' ${debounce_tp_index}
            debounce_tp_index=0
            debounce_remaining=0
          fi
          continue 2
        else continue 1; fi
      fi
      [ ${ACTIVE_TP_INDEX} -eq ${tp_index} ] && continue 2
      _I 'Trip point %d reached' ${tp_index}
      eval "tp_debounce=\${TRIPPT_${tp_index}_DEBOUNCE}"
      if [ "${tp_debounce}" -gt 0 ]; then
        if [ ${debounce_tp_index} -ne ${tp_index} ]; then
          debounce_tp_index=${tp_index}
          debounce_remaining=${tp_debounce}
        else
          debounce_remaining=$((debounce_remaining-1))
        fi
        if [ ${debounce_remaining} -gt 0 ]; then
          _I 'Debouncing for %d iterations' ${debounce_remaining}
          # Restart main loop
          continue 2
        fi
      fi
      # Always reset the debounce vars at this point in case another debounce-less
      # trip point was reached before debounce completed
      debounce_tp_index=0
      debounce_remaining=0
      ACTIVE_TP_INDEX=${tp_index}
      eval "tp_fan=\${TRIPPT_${tp_index}_FAN}"
      eval "tp_pstate=\${TRIPPT_${tp_index}_PSTATE}"
      break
    done

    # Active cooling
    [ -n "${tp_fan}" ] && __set_fan "${tp_fan}"

    # Passive cooling
    [ -n "${tp_pstate}" ] && __set_pstate "${tp_pstate}"
  done
}

__main
