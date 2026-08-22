"""Exhaustively compare runehelper/puphelper's nested slot conditionals
against jobhelper's util.RotationNeeds rule, over every slot arrangement
and buff-count state."""
from collections import Counter
from itertools import product

NONE = -1
ELEMS = [0, 1, 2]


def original(slots, counts):
    """Faithful port of runehelper.lua:63-93 / puphelper.lua:94-125."""
    s1, s2, s3 = slots
    out = []

    if s1 != NONE:
        if counts[s1] == 0:
            out.append(s1)

    if s2 != NONE:
        if counts[s2] == 0:
            out.append(s2)
        elif counts[s2] < 2:
            if s1 != NONE and s1 == s2:
                out.append(s2)
            elif s3 != NONE and s3 == s2:
                out.append(s2)

    if s3 != NONE:
        if counts[s3] == 0:
            out.append(s3)
        elif counts[s3] < 3:
            if s1 != NONE and s2 != NONE and s1 == s3 and s2 == s3:
                out.append(s3)
            elif s1 != NONE and s3 == s1 and counts[s3] < 2:
                out.append(s3)
            elif s2 != NONE and s3 == s2 and counts[s3] < 2:
                out.append(s3)
    return out


def rule(slots, counts):
    """jobhelper util.RotationNeeds."""
    active = [s for s in slots if s != NONE]
    wanted, queued, out = Counter(active), Counter(), []
    for name in active:
        if counts[name] + queued[name] < wanted[name]:
            queued[name] += 1
            out.append(name)
    return out


def stacks_after(emitted, counts, slots):
    """Resulting stack per element, capped at what the slots actually asked
    for -- the game will not hold more than 3 anyway."""
    wanted = Counter(s for s in slots if s != NONE)
    got = Counter(counts)
    for e in emitted:
        got[e] += 1
    return {e: min(got[e], wanted.get(e, 0)) for e in ELEMS}


def main():
    diffs, overshoot, undershoot = [], [], []

    for slots in product([NONE] + ELEMS, repeat=3):
        for cvals in product(range(4), repeat=3):
            counts = dict(zip(ELEMS, cvals))
            o, r = original(slots, counts), rule(slots, counts)
            if Counter(o) != Counter(r):
                diffs.append((slots, cvals, o, r))

            wanted = Counter(s for s in slots if s != NONE)
            for e, want in wanted.items():
                # Does either overshoot what was asked for?
                if counts[e] + Counter(o)[e] > max(want, counts[e]):
                    overshoot.append(("original", slots, cvals, e))
                if counts[e] + Counter(r)[e] > max(want, counts[e]):
                    overshoot.append(("rule", slots, cvals, e))
                # Does either fail to reach the requested stack?
                if counts[e] < want and counts[e] + Counter(o)[e] < want:
                    undershoot.append(("original", slots, cvals, e, want, counts[e] + Counter(o)[e]))
                if counts[e] < want and counts[e] + Counter(r)[e] < want:
                    undershoot.append(("rule", slots, cvals, e, want, counts[e] + Counter(r)[e]))

    total = (len(ELEMS) + 1) ** 3 * 4 ** 3
    print(f"cases compared:        {total}")
    print(f"differing outputs:     {len(diffs)}")
    print(f"overshoot (orig/rule): {sum(1 for x in overshoot if x[0]=='original')}"
          f" / {sum(1 for x in overshoot if x[0]=='rule')}")
    print(f"undershoot (orig):     {sum(1 for x in undershoot if x[0]=='original')}")
    print(f"undershoot (rule):     {sum(1 for x in undershoot if x[0]=='rule')}")

    if diffs:
        print("\nEvery differing case, classified:")
        buckets = {}
        for slots, cvals, o, r in diffs:
            active = [s for s in slots if s != NONE]
            dup = len(active) != len(set(active))
            key = ("duplicate element in slots" if dup else "distinct elements",
                   f"orig emitted {len(o)}, rule emitted {len(r)}")
            buckets.setdefault(key, []).append((slots, cvals, o, r))
        for key, rows in sorted(buckets.items()):
            print(f"\n  {key[0]}; {key[1]}  ({len(rows)} cases)")
            for row in rows[:3]:
                print(f"    slots={row[0]} counts={row[1]} orig={row[2]} rule={row[3]}")


if __name__ == "__main__":
    main()
