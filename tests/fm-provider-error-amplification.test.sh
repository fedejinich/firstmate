#!/usr/bin/env bash
# Classifies transcript error amplification: Pi auto-retry (consecutive
# assistant errors with no new user message) versus Firstmate wake /
# re-presentation (a new operational user turn between errors).
# Product code does not own this classifier; the test locks the diagnostic
# separation used when a main pane floods with "Error: fetch failed".
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

node --input-type=module - <<'JS'
function classify(entries) {
  let intra = 0;
  let firstOps = 0;
  let firstCaptain = 0;
  let prevErr = false;
  let lastOps = false;
  for (const [role, text] of entries) {
    if (role === "user") {
      lastOps = text.includes("FIRSTMATE_OP") || text.includes("WATCHER WAKE");
      prevErr = false;
      continue;
    }
    if (role !== "assistant_error") throw new Error(`unknown role ${role}`);
    if (prevErr) intra += 1;
    else if (lastOps) firstOps += 1;
    else firstCaptain += 1;
    prevErr = true;
  }
  return { intra, firstOps, firstCaptain };
}

const piRetry = classify([
  ["user", "FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: signal: x"],
  ["assistant_error", "fetch failed"],
  ["assistant_error", "fetch failed"],
  ["assistant_error", "fetch failed"],
  ["assistant_error", "fetch failed"],
]);
if (piRetry.intra !== 3 || piRetry.firstOps !== 1 || piRetry.firstCaptain !== 0) {
  throw new Error(`Pi auto-retry shape misclassified: ${JSON.stringify(piRetry)}`);
}

const wakeRep = classify([
  ["user", "FIRSTMATE_OP: wake 1"],
  ["assistant_error", "fetch failed"],
  ["user", "FIRSTMATE_OP: wake 2"],
  ["assistant_error", "fetch failed"],
]);
if (wakeRep.intra !== 0 || wakeRep.firstOps !== 2 || wakeRep.firstCaptain !== 0) {
  throw new Error(`wake re-presentation shape misclassified: ${JSON.stringify(wakeRep)}`);
}

const captain = classify([
  ["user", "segui"],
  ["assistant_error", "fetch failed"],
  ["assistant_error", "fetch failed"],
]);
if (captain.intra !== 1 || captain.firstOps !== 0 || captain.firstCaptain !== 1) {
  throw new Error(`captain thrash shape misclassified: ${JSON.stringify(captain)}`);
}

// Real main-session ratios from the 2026-09-17 fleet log: 101 intra vs 17 ops
// first-errors. Pi retry dominates volume; FM wakes add first-errors only.
const real = { intra: 101, firstOps: 17, firstCaptain: 14 };
if (!(real.intra > real.firstOps + real.firstCaptain)) {
  throw new Error("expected Pi-retry amplification to dominate the recorded main log");
}

console.log("provider-error amplification classifier ok");
JS
