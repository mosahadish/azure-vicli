#!/usr/bin/env bash
#
# resolve-pat.sh - shared PAT lookup for the helper scripts. Sourced, not run:
#
#   . "<dir>/resolve-pat.sh"
#   resolve_pat_into VAR ORG_URL PROJECT
#
# Sets VAR to the PAT of the azure-cli.yml account matching ORG_URL
# (case-insensitive, trailing slash ignored) and PROJECT (case-insensitive;
# an empty PROJECT matches any project in that org). Returns non-zero, with
# VAR empty, when nothing matches.
#
# Where the PAT comes from, in order:
#   1. PRDASH_PATS - exported by azure-cli.exe when it launches nvim, one
#      "org<TAB>project<TAB>pat" per line, read straight out of azure-cli.yml.
#      Matching against it is a pure-bash string scan (no process spawn at
#      all) instead of a full .NET start-up of `azure-cli.exe --print-pat` on
#      every single script invocation, which is what made each action pay a
#      few hundred milliseconds before doing any network work.
#   2. `azure-cli.exe --print-pat` (via PRDASH_EXE) when PRDASH_PATS is absent,
#      e.g. nvim was started by hand rather than through the exe.
#
# Either way the value originates from the config file only - an ambient
# AZURE_DEVOPS_EXT_PAT / ADO_PAT in the caller's shell is never consulted.
resolve_pat_into() {
  local __var="$1" want_org="${2%/}" want_proj="$3" line org proj pat
  want_org="${want_org,,}"
  want_proj="${want_proj,,}"
  printf -v "$__var" '%s' ""

  if [[ -n "${PRDASH_PATS:-}" ]]; then
    while IFS=$'\t' read -r org proj pat; do
      pat="${pat%$'\r'}"
      org="${org%/}"
      [[ "${org,,}" == "$want_org" ]] || continue
      [[ -z "$want_proj" || "${proj,,}" == "$want_proj" ]] || continue
      [[ -n "$pat" ]] || continue
      printf -v "$__var" '%s' "$pat"
      return 0
    done <<< "$PRDASH_PATS"
  fi

  if [[ -n "${PRDASH_EXE:-}" ]]; then
    local out
    out="$("$PRDASH_EXE" --print-pat --org "$2" --project "$3" 2>/dev/null)" || out=""
    printf -v "$__var" '%s' "$out"
  fi

  [[ -n "${!__var}" ]]
}
