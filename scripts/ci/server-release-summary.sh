#!/usr/bin/env bash
# Summarizes a server release per origin, including partial completion.
# Env: ORIGINS (both|fly|nuremberg), RESULTS (toJSON(needs)), GITHUB_SHA,
# optional PUBLISH_ONLY, BOOTSTRAP, ROLLBACK and SKIP_GATE booleans.
set -euo pipefail

result() { jq -r --arg job "$1" '.[$job].result // "skipped"' <<< "$RESULTS"; }
output() { jq -r --arg job "$1" '.[$job].outputs.outcome // ""' <<< "$RESULTS"; }
resume="Re-run failed jobs to resume from the retained image digests and original release plan."

validate=$(result validate) qualify=$(result qualify) preflight=$(result preflight) migrate=$(result migrate)
nbg=$(result nuremberg) fly=$(result deploy)
nbg_outcome=$(output nuremberg) fly_outcome=$(output deploy)
gate=$(result require_green)
outcome=failed reason="" detail=""

if [[ "$validate" == success && "${ROLLBACK:-false}" == true ]]; then
  plan=$(result rollback_plan) rfly=$(result rollback_fly) rnbg=$(result rollback_nuremberg)
  rfly_outcome=$(output rollback_fly) rnbg_outcome=$(output rollback_nuremberg)
  detail="Fly: $rfly${rfly_outcome:+ ($rfly_outcome)}. Nuremberg: $rnbg${rnbg_outcome:+ ($rnbg_outcome)}."
  if [[ "$plan" != success ]]; then
    reason="rollback plan $plan; no origin was changed"
    detail=""
  elif [[ "$rfly" != success && "$rfly" != skipped ]] || [[ "$rnbg" != success && "$rnbg" != skipped ]]; then
    reason="rollback incomplete; its job log names what to reconcile. Re-run failed jobs to resume."
  elif [[ "$rfly" == skipped && "$rnbg" == skipped ]]; then
    reason="the plan selected no origin to roll back"
  else
    outcome=published reason="rolled back to the recorded pre-release images (qualification and migrations skipped)"
    if [[ "$rfly_outcome$rnbg_outcome" =~ ^(already-current)+$ ]]; then
      outcome=already-current reason="origins already served the recorded pre-release images"
    fi
  fi
  bash "$(dirname "$0")/release-summary.sh" "Server rollback" "$outcome" "$reason" "${GITHUB_SHA:-}" "$detail"
  exit 0
fi

if [[ "$validate" != success ]]; then
  reason="input validation $validate; this attempt did not reach deployment"
elif [[ "$qualify" != success ]]; then
  reason="image qualification $qualify; this attempt did not reach deployment"
elif [[ "${PUBLISH_ONLY:-false}" == true ]]; then
  if [[ "$(result prepared)" == success ]]; then
    outcome=published reason="qualified images published; production jobs were not requested"
  else
    reason="image publication report $(result prepared); production jobs were not requested"
  fi
elif [[ "${SKIP_GATE:-false}" != true && "$gate" != success && "$gate" != skipped ]]; then
  reason="deploy gate $gate: a server-relevant CI job is not green for this commit; nothing in production changed. Re-run failed jobs once it passes, or dispatch with skip_gate and skip_reason"
elif [[ "$preflight" != success ]]; then
  reason="origin/configuration preflight $preflight; this attempt did not reach migrations or deployment"
elif [[ "$migrate" != success ]]; then
  reason="migration did not pass; this attempt did not reach deployment. $resume"
elif [[ "${BOOTSTRAP:-false}" == true ]]; then
  if [[ "$fly" == success && "$(result activate)" == success ]]; then
    outcome=published reason="Fly bootstrap and worker activation verified"
  else
    reason="Fly bootstrap $fly; worker activation $(result activate). Inspect the cutover state before retrying."
  fi
elif [[ "$ORIGINS" == both ]]; then
  if [[ "$nbg" != success ]]; then
    reason="Nuremberg $nbg (its log says whether the previous image was restored); Fly was not touched in this attempt. $resume"
  elif [[ "$fly" != success ]]; then
    reason="Nuremberg serves this release but Fly $fly. $resume"
  else
    outcome=published reason="both origins verified and smoke-tested"
    if [[ "$nbg_outcome" == already-current && "$fly_outcome" == already-current ]]; then
      outcome=already-current reason="both origins already served this release"
    fi
    detail="Nuremberg: $nbg_outcome. Fly: $fly_outcome."
  fi
elif [[ "$ORIGINS" == fly ]]; then
  if [[ "$fly" == success ]]; then
    outcome="$fly_outcome" reason="Fly verified and smoke-tested"
    detail="Nuremberg was not updated in this run; release it before relying on the fallback."
  else
    reason="Fly $fly. $resume"
  fi
else
  if [[ "$nbg" == success ]]; then
    outcome="$nbg_outcome" reason="Nuremberg verified and smoke-tested"
    detail="Fly was not updated in this run."
  else
    reason="Nuremberg $nbg (its log says whether the previous image was restored). $resume"
  fi
fi

[[ -n "$outcome" ]] || outcome=failed
if [[ "${SKIP_GATE:-false}" == true ]]; then
  detail="Deploy gate skipped; the run summary records the reason.${detail:+ $detail}"
fi
title="Server release"
if [[ "${PUBLISH_ONLY:-false}" == true ]]; then title="Server images"; fi
bash "$(dirname "$0")/release-summary.sh" "$title" "$outcome" "$reason" "${GITHUB_SHA:-}" "$detail"
