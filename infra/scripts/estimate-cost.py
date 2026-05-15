#!/usr/bin/env python3
"""
estimate-cost.py — rough cost estimate for the benchmark sweep based on
the MACHINE_TYPES list in .env.

Numbers are approximate on-demand list prices (us-central1) and will drift.
Always sanity-check against https://cloud.google.com/compute/all-pricing
before quoting them to anyone.
"""

import os
import sys

# Approximate on-demand $/hour for G4 machine types in us-central1.
# Update as needed; pricing changes.
G4_PRICES_PER_HOUR = {
    "g4-standard-48":  5.50,
    "g4-standard-96":  11.00,
    "g4-standard-192": 22.00,
    "g4-standard-384": 44.00,
}

# Provisioning-mode price multipliers (approximate).
MODE_MULTIPLIER = {
    "on-demand":  1.00,
    "spot":       0.30,   # Spot is typically 60-80% off; 0.30 is a conservative midpoint.
    "flex-start": 1.00,   # DWS is on-demand pricing; the win is no standing quota, not cost.
}

# Assumed hours-per-machine for one full sweep (very rough).
HOURS_PER_MACHINE_AT_PEAK = 1.0


def main() -> int:
    machine_types = os.environ.get("MACHINE_TYPES", "").strip()
    mode = os.environ.get("PROVISIONING_MODE", "on-demand").strip()

    if not machine_types:
        print("ERROR: MACHINE_TYPES not set in environment. Source .env first.", file=sys.stderr)
        return 1

    if mode not in MODE_MULTIPLIER:
        print(f"ERROR: unknown PROVISIONING_MODE: {mode}", file=sys.stderr)
        return 1

    selected = [m.strip() for m in machine_types.split(",") if m.strip()]
    unknown = [m for m in selected if m not in G4_PRICES_PER_HOUR]
    if unknown:
        print(f"ERROR: unknown machine types: {unknown}", file=sys.stderr)
        print(f"       supported: {sorted(G4_PRICES_PER_HOUR)}", file=sys.stderr)
        return 1

    mult = MODE_MULTIPLIER[mode]

    print(f"Rough cost estimate (provisioning: {mode}, multiplier: {mult}):")
    print(f"  Assumes ~{HOURS_PER_MACHINE_AT_PEAK:.1f} hr per machine type at peak utilization")
    print(f"  during the sweep, times 2 stacks (plain-vllm + llm-d).")
    print()

    total = 0.0
    print(f"  {'Machine':22} {'$/hr (on-demand)':>18} {'Est. cost':>12}")
    print(f"  {'-'*22} {'-'*18} {'-'*12}")
    for m in selected:
        per_hr = G4_PRICES_PER_HOUR[m]
        # Cost = price * hours * mode_multiplier * 2 (plain-vllm and llm-d each).
        cost = per_hr * HOURS_PER_MACHINE_AT_PEAK * mult * 2
        total += cost
        print(f"  {m:22} {per_hr:>14.2f} USD {cost:>10.2f} USD")
    print(f"  {'':22} {'':>18} {'-'*12}")
    print(f"  {'TOTAL':22} {'':>18} {total:>10.2f} USD")
    print()
    print("Real spend depends heavily on cold-start time, queue waits, and")
    print("how much you iterate. Verify current pricing at:")
    print("  https://cloud.google.com/compute/all-pricing")
    return 0


if __name__ == "__main__":
    sys.exit(main())
