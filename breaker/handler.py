"""Cost circuit breaker — the "stop charging Trevor money" kill switch.

Trips on SNS notification from the flood alarms (lingo-core-invocation-flood,
lingo-core-throttle-flood, lingo-app-cdn-request-flood) or the budget's 200%
notification. Tripping is deliberately blunt — Spencer's call 2026-08-26:
breaking the app is acceptable, an unbounded bill is not.

Trip:    reserved concurrency -> 0 on every function in FUNCTIONS (throttles
         all invocations: 429s, zero compute billed), disable the app's
         CloudFront distribution (stops egress billing), snapshot prior state
         to SSM so restore is one call, page the alert topic.
Restore: invoke manually with {"action": "restore"} — puts concurrency and
         the distribution back exactly as the snapshot recorded.

Idempotent in both directions; a re-delivered SNS message on an
already-tripped breaker just re-pages.
"""

import json
import logging
import os

import boto3

log = logging.getLogger()
log.setLevel(logging.INFO)

REGION = os.environ.get("BREAKER_REGION", "us-west-1")
FUNCTIONS = [f for f in os.environ.get("FUNCTIONS", "").split(",") if f]
DISTRIBUTION_ID = os.environ.get("DISTRIBUTION_ID", "")
ALERT_TOPIC_ARN = os.environ.get("ALERT_TOPIC_ARN", "")
STATE_PARAM = os.environ.get("STATE_PARAM", "/lingo/breaker/prior-state")

lam = boto3.client("lambda", region_name=REGION)
cf = boto3.client("cloudfront")
ssm = boto3.client("ssm", region_name=REGION)
sns = boto3.client("sns", region_name=REGION)


def _current_state() -> dict:
    state = {"functions": {}, "distribution_enabled": None}
    for fn in FUNCTIONS:
        try:
            resp = lam.get_function_concurrency(FunctionName=fn)
            state["functions"][fn] = resp.get("ReservedConcurrentExecutions")
        except lam.exceptions.ResourceNotFoundException:
            log.warning("function %s not found; skipping", fn)
    if DISTRIBUTION_ID:
        cfg = cf.get_distribution_config(Id=DISTRIBUTION_ID)
        state["distribution_enabled"] = cfg["DistributionConfig"]["Enabled"]
    return state


def _set_distribution_enabled(enabled: bool) -> None:
    cfg = cf.get_distribution_config(Id=DISTRIBUTION_ID)
    if cfg["DistributionConfig"]["Enabled"] == enabled:
        return
    cfg["DistributionConfig"]["Enabled"] = enabled
    cf.update_distribution(
        Id=DISTRIBUTION_ID,
        IfMatch=cfg["ETag"],
        DistributionConfig=cfg["DistributionConfig"],
    )


def _page(subject: str, message: str) -> None:
    if ALERT_TOPIC_ARN:
        sns.publish(TopicArn=ALERT_TOPIC_ARN, Subject=subject, Message=message)


def _trip(trigger: str) -> dict:
    state = _current_state()
    already = all(v == 0 for v in state["functions"].values()) and (
        state["distribution_enabled"] is False
    )
    if not already:
        # Snapshot BEFORE changing anything, but never overwrite an existing
        # snapshot with a half-tripped state (double SNS delivery race).
        try:
            ssm.get_parameter(Name=STATE_PARAM)
            log.info("snapshot already exists; not overwriting")
        except ssm.exceptions.ParameterNotFound:
            ssm.put_parameter(
                Name=STATE_PARAM, Value=json.dumps(state), Type="String"
            )
        for fn in state["functions"]:
            lam.put_function_concurrency(
                FunctionName=fn, ReservedConcurrentExecutions=0
            )
        if DISTRIBUTION_ID:
            _set_distribution_enabled(False)
    _page(
        "LINGO COST BREAKER TRIPPED",
        f"Trigger: {trigger}\n\n"
        f"All API traffic is now throttled (reserved concurrency 0 on "
        f"{', '.join(state['functions'])}) and CloudFront distribution "
        f"{DISTRIBUTION_ID} is disabling. Nothing is billing beyond "
        f"pennies.\n\n"
        f"When someone has looked at what happened, restore with:\n"
        f"  aws lambda invoke --function-name lingo-cost-breaker "
        f"--payload '{{\"action\": \"restore\"}}' "
        f"--cli-binary-format raw-in-base64-out /tmp/out.json\n\n"
        f"Prior state snapshot: SSM {STATE_PARAM}",
    )
    return {"tripped": True, "was_already_tripped": already, "trigger": trigger}


def _restore() -> dict:
    try:
        prior = json.loads(ssm.get_parameter(Name=STATE_PARAM)["Parameter"]["Value"])
    except ssm.exceptions.ParameterNotFound:
        return {"restored": False, "reason": "no snapshot — breaker never tripped?"}
    for fn, reserved in prior["functions"].items():
        if reserved is None:
            lam.delete_function_concurrency(FunctionName=fn)
        else:
            lam.put_function_concurrency(
                FunctionName=fn, ReservedConcurrentExecutions=reserved
            )
    if DISTRIBUTION_ID and prior.get("distribution_enabled"):
        _set_distribution_enabled(True)
    ssm.delete_parameter(Name=STATE_PARAM)
    _page("lingo cost breaker RESTORED", f"Restored to snapshot: {prior}")
    return {"restored": True, "prior": prior}


def handler(event, _context):
    log.info("event: %s", json.dumps(event)[:2000])
    if isinstance(event, dict) and event.get("action") == "restore":
        return _restore()
    trigger = "manual/unknown"
    records = event.get("Records", []) if isinstance(event, dict) else []
    if records:
        sns_msg = records[0].get("Sns", {})
        trigger = sns_msg.get("Subject") or sns_msg.get("Message", "")[:200]
    return _trip(trigger)
