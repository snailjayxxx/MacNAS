#!/usr/bin/env python3
"""Finite abstract model only: no filesystem, processes, database, or rename calls.

Object tokens represent already bounded identity/stamp/hash observations, not real
inode identities. One crash, one external object change, and one approval cycle
bound exploration. Read-only observation and readWrite settlement are separate.
"""
from collections import Counter, deque
from dataclasses import dataclass, replace
from itertools import product
import json

MODEL_VERSION = 1
TERMINAL = ("completed", "cancelled")
OPERATIONS = ("prepared", "armed", "observed", "uncertain", "completed", "cancelled")
TOKENS = ("absent", "matching", "replacement", "tampered")


@dataclass(frozen=True)
class State:
    direction: str
    phase: str = "idle"
    source: int = 1
    target: int = 0
    parents_valid: bool = True
    metadata_safe: bool = True
    read_approved: bool = True
    settle_approved: bool = True
    capability: bool = False
    final_checked: bool = False
    crash_used: bool = False
    old_operation: bool = False
    change_used: bool = False
    revoke_used: bool = False
    read_grant_used: bool = False
    settle_grant_used: bool = False
    attempts: int = 0
    post: bool = False
    synced: bool = False
    completed_sync: bool = False
    charge: int = 0
    observation: str = "unknown"
    cancel_from: str = ""
    overwritten: bool = False
    restarted_rename: bool = False


def initial(direction):
    return State(direction=direction, charge=1 if direction == "restore" else 0)


def matched(s):
    return s.source == 0 and s.target == 1 and s.parents_valid and s.metadata_safe


def source_only(s):
    return s.source == 1 and s.target == 0 and s.parents_valid and s.metadata_safe


def classification(phase, source, target, post, read_approved,
                   parents_valid=True, metadata_safe=True):
    if not read_approved:
        return "notAuthorized"
    if not parents_valid or not metadata_safe:
        return "ambiguous"
    if phase == "completed":
        return "historicalMatchedPost" if post and source == 0 and target == 1 else "historicalChanged"
    if source == 1 and target == 0:
        return "sourceOnlyPrepared" if phase == "prepared" else "uncertainSourceOnly"
    if source == 0 and target == 1:
        return "matchedPost" if post else "candidateMoved"
    return "ambiguous"


def observe(s):
    return classification(s.phase, s.source, s.target, s.post,
                          s.read_approved, s.parents_valid, s.metadata_safe)


def transitions(s, policy="correct"):
    """Fixed action order makes breadth-first counterexamples reproducible."""
    out = []
    add = lambda action, **changes: out.append((action, replace(s, **changes)))
    if s.phase == "idle" and s.read_approved and s.settle_approved and source_only(s):
        add("preview", phase="preview", capability=True)
    if s.phase == "preview" and s.capability and s.read_approved and s.settle_approved and source_only(s):
        add("confirm_and_readback_prepared", phase="prepared", charge=1)
    if s.phase == "preview":
        add("discard_preview", phase="cancelled", capability=False, cancel_from="preview")
    if s.phase == "prepared" and s.capability and s.read_approved and s.settle_approved and source_only(s):
        add("commit_and_readback_armed", phase="armed")
    # This admission and rename are separate: revocation/change can intervene.
    if (s.phase == "armed" and s.attempts == 0 and not s.final_checked
            and s.capability and s.read_approved and s.settle_approved and source_only(s)):
        add("final_check_admission", final_checked=True)
    if s.phase == "armed" and s.final_checked and s.attempts == 0:
        collision = s.target != 0
        success = s.source != 0 and (not collision or policy == "overwrite")
        permitted_context = s.capability and s.read_approved and s.settle_approved
        add("rename_attempt", attempts=1, final_checked=False,
            source=0 if success else s.source,
            target=s.source if success else s.target,
            phase="armed" if success and permitted_context else "uncertain",
            overwritten=success and collision,
            restarted_rename=s.old_operation,
            observation="unknown")
    if (s.phase == "armed" and s.attempts == 1 and matched(s)
            and s.capability and s.read_approved and s.settle_approved):
        add("persist_post_and_readback_observed", phase="observed", post=True,
            synced=False, observation="matchedPost")
    if s.phase in ("armed", "observed") and s.read_approved and not (source_only(s) or matched(s)):
        add("detect_inconsistent_evidence", phase="uncertain", synced=False)
    if s.phase == "observed" and not s.synced and s.read_approved and s.settle_approved:
        add("directory_sync_failure", phase="uncertain", synced=False)
    # This action only changes an ephemeral observation, never phase/quota.
    if s.phase in OPERATIONS:
        add("read_only_reconcile_observation", observation=observe(s))
    # Settlement is a separate current readWrite authorization, not observation.
    settle_context = (s.read_approved and s.settle_approved and s.post and matched(s)
                      and s.phase in ("observed", "uncertain")
                      and (s.capability or s.observation == "matchedPost"))
    if settle_context and not s.synced:
        add("settle_sync_both_parents_and_recheck", synced=True)
    if settle_context and s.synced:
        add("settle_commit_completed", phase="completed", capability=False,
            charge=1 if s.direction == "recycle" else 0, completed_sync=True)
    cancellable = s.phase == "prepared" or (policy == "armed_cancel" and s.phase in ("armed", "uncertain"))
    if cancellable and s.read_approved and s.settle_approved and source_only(s):
        add("cancel_persistent_operation", phase="cancelled", capability=False,
            final_checked=False, charge=0 if s.direction == "recycle" else 1,
            cancel_from=s.phase)
    if (policy == "pre_adoption" and s.phase in ("armed", "uncertain")
            and s.read_approved and s.settle_approved and matched(s) and not s.post):
        add("MUTANT_complete_candidate_from_pre", phase="completed", completed_sync=True,
            charge=1 if s.direction == "recycle" else 0)
    if (policy == "restart_retry" and s.old_operation and s.phase in ("armed", "uncertain")
            and s.read_approved and s.settle_approved and source_only(s)):
        add("MUTANT_retry_old_id_after_restart", source=0, target=1,
            attempts=s.attempts + 1, restarted_rename=True,
            phase="uncertain", final_checked=False)
    if not s.revoke_used:
        add("revoke_approvals", read_approved=False, settle_approved=False,
            capability=False, revoke_used=True, synced=False if s.phase != "completed" else s.synced,
            observation="unknown")
    if not s.crash_used:
        add("crash_restart", crash_used=True, old_operation=s.phase in OPERATIONS, capability=False, final_checked=False,
            read_approved=False, settle_approved=False,
            synced=False if s.phase != "completed" else s.synced, observation="unknown")
    if not s.read_approved and not s.read_grant_used:
        add("new_read_observation_approval", read_approved=True, capability=False,
            read_grant_used=True, observation="unknown")
    if s.read_approved and not s.settle_approved and not s.settle_grant_used:
        add("new_readwrite_settlement_approval", settle_approved=True,
            settle_grant_used=True, capability=False)
    if not s.change_used:
        common = dict(change_used=True, observation="unknown",
                      synced=False if s.phase != "completed" else s.synced)
        if s.source != 2:
            add("external_source_replacement", source=2, **common)
        if s.source != 0:
            add("external_source_removal", source=0, **common)
        if s.source == 1:
            add("external_source_tamper", source=3, **common)
        if s.target == 0:
            add("external_target_collision", target=2, **common)
        if s.target != 0:
            add("external_target_removal", target=0, **common)
        if s.target == 1:
            add("external_target_tamper", target=3, **common)
        add("external_parent_replacement", parents_valid=False, **common)
        add("external_unsafe_metadata", metadata_safe=False, **common)
    return out


def violations(s, before=None, action=None):
    errors = []
    if s.overwritten:
        errors.append("no_target_overwrite")
    if s.attempts > 1:
        errors.append("at_most_one_rename_attempt_per_operation_id")
    if s.restarted_rename:
        errors.append("restart_never_reexecutes_old_operation_id")
    if s.phase == "cancelled" and s.cancel_from not in ("prepared", "preview"):
        errors.append("only_prepared_persistent_operations_can_cancel")
    if s.phase == "completed" and not (s.post and s.completed_sync):
        errors.append("completion_requires_durable_post_and_sync_evidence")
    expected_charge = 1 if s.direction == "restore" else 0
    if s.phase in ("prepared", "armed", "observed", "uncertain"):
        expected_charge = 1
    if s.phase == "completed":
        expected_charge = 1 if s.direction == "recycle" else 0
    if s.charge != expected_charge:
        errors.append("full_charge_until_prepared_cancel_or_restore_completion")
    if before is not None and action == "read_only_reconcile_observation":
        if any(getattr(before, field) != getattr(s, field) for field in State.__dataclass_fields__ if field != "observation"):
            errors.append("read_only_observation_cannot_change_journal_or_quota")
    if before is not None and before.phase in ("armed", "observed", "uncertain") and s.charge < before.charge and s.phase != "completed":
        errors.append("unresolved_operations_retain_full_charge")
    if before is not None and action == "rename_attempt" and not before.final_checked:
        errors.append("rename_requires_separate_final_admission")
    if before is not None and action == "crash_restart" and (s.capability or s.final_checked or s.read_approved or s.settle_approved):
        errors.append("crash_invalidates_all_old_host_capabilities")
    return errors


def compact(s):
    return dict(direction=s.direction, phase=s.phase, source=TOKENS[s.source],
                target=TOKENS[s.target], readApproved=s.read_approved,
                settleApproved=s.settle_approved, oldCapability=s.capability,
                admitted=s.final_checked, crashed=s.crash_used, operationPredatesRestart=s.old_operation,
                renameAttempts=s.attempts, durablePost=s.post,
                synchronized=s.synced, charge=s.charge, observation=s.observation)


def shortest_path(parent, state, action, next_state):
    path = [(action, next_state)]
    while parent[state] is not None:
        previous, prior_action = parent[state]
        path.append((prior_action, state))
        state = previous
    path.append(("initial", state))
    path.reverse()
    return [dict(action=name, state=compact(value)) for name, value in path]


def explore(direction, policy="correct"):
    start = initial(direction)
    queue, seen = deque([start]), {start}
    parents = {start: None} if policy != "correct" else None
    edges, phases, witnesses = 0, Counter(), Counter()
    while queue:
        state = queue.popleft()
        phases[state.phase] += 1
        for action, successor in transitions(state, policy):
            edges += 1
            failures = violations(successor, state, action)
            if failures:
                if policy == "correct":
                    raise RuntimeError("correct model violated %s after %s: %r" % (failures, action, successor))
                return dict(policy=policy, direction=direction, visitedStates=len(seen),
                            exploredTransitions=edges, violations=failures,
                            shortestCounterexample=shortest_path(parents, state, action, successor))
            if action == "rename_attempt" and not state.read_approved:
                witnesses["effect_after_admission_then_revocation_is_uncertain"] += 1
                if successor.phase != "uncertain":
                    raise RuntimeError("revocation after admission was reported as a safe completion")
            if action == "settle_commit_completed" and state.old_operation and not state.capability:
                witnesses["post_evidence_settled_after_restart_without_rename"] += 1
            if action == "read_only_reconcile_observation" and successor.observation == "candidateMoved":
                witnesses["pre_only_candidate_remains_uncompleted"] += 1
            if successor not in seen:
                seen.add(successor)
                queue.append(successor)
                if parents is not None:
                    parents[successor] = (state, action)
    if policy != "correct":
        raise RuntimeError("mutant survived: " + policy)
    return dict(direction=direction, visitedStates=len(seen), exploredTransitions=edges,
                phases=dict(sorted(phases.items())), witnesses=dict(sorted(witnesses.items())))


def boundary_matrix():
    rows = []
    authorities = ("none", "readObservationOnly", "readObservationAndSettlement")
    for source, target, post, authority in product(range(4), range(4), (False, True), authorities):
        readable, writable = authority != "none", authority == "readObservationAndSettlement"
        result = classification("observed" if post else "armed", source, target, post, readable)
        can_settle = readable and writable and post and result == "matchedPost"
        if not readable and result != "notAuthorized":
            raise RuntimeError("matrix allowed unapproved filesystem observation")
        if readable and (source != 0 or target != 1) and result == "matchedPost":
            raise RuntimeError("matrix adopted ambiguous endpoints")
        if not post and can_settle:
            raise RuntimeError("matrix completed from pre-only evidence")
        rows.append(dict(source=TOKENS[source], target=TOKENS[target],
                         evidence="durablePost" if post else "preOnly", authority=authority,
                         classification=result, settlementPermitted=can_settle))
    extras = []
    for label, phase, source, target, post, parents, metadata, expected in (
            ("prepared_source_only", "prepared", 1, 0, False, True, True, "sourceOnlyPrepared"),
            ("armed_source_only", "armed", 1, 0, False, True, True, "uncertainSourceOnly"),
            ("replaced_parent", "observed", 0, 1, True, False, True, "ambiguous"),
            ("unsafe_links_or_type", "observed", 0, 1, True, True, False, "ambiguous"),
            ("historical_completed_later_tampered", "completed", 0, 3, True, True, True, "historicalChanged")):
        result = classification(phase, source, target, post, True, parents, metadata)
        if result != expected:
            raise RuntimeError("boundary expectation failed: " + label)
        extras.append(dict(case=label, classification=result))
    return dict(rows=len(rows), matrix=rows, additionalBoundaries=extras)


CHARGED = {"recyclePrepared", "recycleArmed", "uncertainRecycle", "retained",
           "restorePrepared", "restoreArmed", "uncertainRestore", "observedRestore"}
ACTIVE = CHARGED - {"retained"}


def quota_model():
    """Two fixed entry slots, one active operation, capacity 3 units, sizes 0..capacity+1.

    Evidence-qualified completion is abstracted here; the effect model checks its
    proof conditions. Every admission is one indivisible quota transaction.
    """
    capacity, active_limit, state_count, edge_count = 3, 1, 0, 0
    rejected, boundary_counts = Counter(), Counter()
    for sizes in product(range(capacity + 2), repeat=2):
        start = ("empty", "empty")
        queue, seen = deque([start]), {start}
        while queue:
            phases = queue.popleft()
            charged = sum(size for size, phase in zip(sizes, phases) if phase in CHARGED)
            created = sum(phase != "empty" for phase in phases)
            active = sum(phase in ACTIVE for phase in phases)
            if active > active_limit:
                raise RuntimeError("active operation quota exceeded")
            if charged > capacity:
                raise RuntimeError("quota exceeded")
            for index, phase in enumerate(phases):
                choices = []
                if phase == "empty":
                    if charged + sizes[index] > capacity:
                        rejected["byteLimit"] += 1
                    elif active >= active_limit:
                        rejected["activeLimit"] += 1
                    else:
                        choices.append(("confirm", "recyclePrepared"))
                        if charged + sizes[index] == capacity:
                            boundary_counts["exact_capacity_admission"] += 1
                        if sizes[index] == 0:
                            boundary_counts["zero_byte_still_creates_history"] += 1
                choices.extend({
                    "recyclePrepared": (("cancel_prepared", "cancelled"), ("arm", "recycleArmed")),
                    "recycleArmed": (("finish_recycle_with_proof", "retained"), ("lose_proof", "uncertainRecycle")),
                    "uncertainRecycle": (("settle_recycle_with_post", "retained"),),
                    "restorePrepared": (("cancel_prepared_restore", "retained"), ("arm_restore", "restoreArmed")),
                    "restoreArmed": (("persist_post", "observedRestore"), ("lose_proof", "uncertainRestore")),
                    "uncertainRestore": (("settle_restore_post", "observedRestore"),),
                    "observedRestore": (("finish_restore_with_proof", "released"),)
                }.get(phase, ()))
                if phase == "retained":
                    if active >= active_limit:
                        rejected["activeLimit"] += 1
                    else:
                        choices.append(("confirm_restore", "restorePrepared"))
                for action, next_phase in choices:
                    next_phases = tuple(next_phase if i == index else p for i, p in enumerate(phases))
                    next_charge = sum(size for size, p in zip(sizes, next_phases) if p in CHARGED)
                    if next_charge > capacity:
                        raise RuntimeError("atomic quota admission exceeded capacity")
                    if next_charge < charged and action not in ("cancel_prepared", "finish_restore_with_proof"):
                        raise RuntimeError("quota released before permitted terminal boundary")
                    if phase == "restorePrepared" and next_phase == "retained" and next_charge != charged:
                        raise RuntimeError("cancelled restore released retained entry charge")
                    if phase in ("recycleArmed", "uncertainRecycle", "restoreArmed", "uncertainRestore") and next_charge != charged:
                        raise RuntimeError("unresolved entry lost full charge")
                    edge_count += 1
                    if next_phases not in seen:
                        seen.add(next_phases)
                        queue.append(next_phases)
            if created == 2:
                boundary_counts["history_saturated_states"] += 1
        state_count += len(seen)
    if not boundary_counts["exact_capacity_admission"] or not rejected["byteLimit"]:
        raise RuntimeError("quota boundaries not reached")
    return dict(capacityUnits=capacity, entrySlots=2, activeLimit=active_limit,
                sizePairs=25, visitedStates=state_count, exploredTransitions=edge_count,
                rejections=dict(sorted(rejected.items())), boundaries=dict(sorted(boundary_counts.items())),
                note="Two fixed slots enforce the history bound by construction; no third confirmation rejection is simulated. Atomic abstract accounting only; no PostgreSQL isolation or real byte allocation is tested.")


def main():
    correct = [explore(direction) for direction in ("recycle", "restore")]
    for result in correct:
        required = ("effect_after_admission_then_revocation_is_uncertain",
                    "post_evidence_settled_after_restart_without_rename",
                    "pre_only_candidate_remains_uncompleted")
        if any(not result["witnesses"].get(name) for name in required):
            raise RuntimeError("required interaction was not reachable: " + result["direction"])
    mutants = [explore("recycle", policy) for policy in
               ("armed_cancel", "pre_adoption", "restart_retry", "overwrite")]
    report = dict(modelVersion=MODEL_VERSION, result="PASS", correctStrategies=correct,
                  mutants=mutants, boundaryClassification=boundary_matrix(), quota=quota_model(),
                  limits=[
                      "Finite abstraction: one crash, one external change, one revocation and approval cycle per run.",
                      "One immutable operation ID and one entry per effect run; quota uses two slots and 0..4 units.",
                      "Commit/readback and quota transactions are assumed atomic, not validated against PostgreSQL.",
                      "Effect and quota models are checked separately, not as a product; quota with_proof transitions assume the effect proof prerequisite.",
                      "The 96 classification rows enumerate the classification function, not an independent oracle.",
                      "Object tokens abstract identity/stamp/hash evidence; no inode reuse, ABA, real locks, or strong fencing proof.",
                      "No filesystem, subprocess, SIGKILL, APFS, fsync, SQL, database, network, or browser operations are performed.",
                      "Exhaustive reachability under these transitions is not a production, durability, crash-recovery, or liveness claim."
                  ])
    print(json.dumps(report, sort_keys=True, indent=2))


if __name__ == "__main__":
    main()
